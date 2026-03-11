use anyhow::{bail, Context, Result};
use clap::{Parser, ValueEnum};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{IpAddr, Ipv4Addr, TcpStream};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Clone, ValueEnum)]
enum OutputMode {
    /// v4l2 loopback device (Linux)
    V4l2,
    /// ffplay preview window (macOS / Linux)
    Play,
    /// Raw H.264 file output
    File,
}

impl OutputMode {
    fn platform_default() -> Self {
        if cfg!(target_os = "linux") {
            OutputMode::V4l2
        } else {
            OutputMode::Play
        }
    }
}

#[derive(Parser)]
#[command(name = "vcam-client", about = "Stream H.264 from iOS cam to virtual camera or preview")]
struct Args {
    /// iPhone IP address (auto-detected if omitted)
    #[arg(short, long)]
    ip: Option<String>,

    /// Server port
    #[arg(short, long, default_value = "8080")]
    port: u16,

    /// Output mode: v4l2 (Linux), play (preview window), file
    #[arg(short, long, value_enum)]
    mode: Option<OutputMode>,

    /// v4l2loopback device path (v4l2 mode)
    #[arg(short, long, default_value = "/dev/video4")]
    device: String,

    /// Output file path (file mode)
    #[arg(short, long, default_value = "output.mp4")]
    output: String,

    /// Pixel format for decoded output
    #[arg(long, default_value = "yuv420p")]
    pix_fmt: String,

    /// Disable auto-reconnect on disconnect
    #[arg(long)]
    no_reconnect: bool,

    /// Reconnect delay in seconds
    #[arg(long, default_value = "2")]
    reconnect_delay: u64,

    /// Extra ffmpeg output args (overrides mode). Example: -f sdl2 "LinuxCam"
    #[arg(long, num_args = 1.., allow_hyphen_values = true)]
    ffmpeg_out: Option<Vec<String>>,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let mode = args.mode.clone().unwrap_or_else(OutputMode::platform_default);

    // Resolve IP: use provided or auto-detect
    let ip = match &args.ip {
        Some(ip) => ip.clone(),
        None => {
            eprintln!("[vcam] No --ip provided, scanning network...");
            discover_camera(args.port)?
        }
    };

    let mode_label = match &args.ffmpeg_out {
        Some(extra) => format!("custom: {}", extra.join(" ")),
        None => match mode {
            OutputMode::V4l2 => format!("v4l2 → {}", args.device),
            OutputMode::Play => "ffplay preview window".into(),
            OutputMode::File => format!("file → {}", args.output),
        },
    };

    loop {
        eprintln!("[vcam] Connecting to {ip}:{}...", args.port);
        eprintln!("[vcam] Output: {mode_label}");

        match run_stream(&ip, &args, &mode) {
            Ok(()) => eprintln!("[vcam] Stream ended cleanly."),
            Err(e) => eprintln!("[vcam] Error: {e:#}"),
        }

        if args.no_reconnect {
            break;
        }

        eprintln!("[vcam] Reconnecting in {}s...", args.reconnect_delay);
        std::thread::sleep(Duration::from_secs(args.reconnect_delay));
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Auto-discovery: scan local subnet for LinuxCam server
// ---------------------------------------------------------------------------

fn discover_camera(port: u16) -> Result<String> {
    let local_ip = get_local_ip().context("could not determine local IP")?;
    let octets = match local_ip {
        IpAddr::V4(v4) => v4.octets(),
        _ => bail!("IPv6 not supported for auto-discovery"),
    };

    eprintln!(
        "[vcam] Local IP: {local_ip}, scanning {}.{}.{}.1-254 on port {port}...",
        octets[0], octets[1], octets[2]
    );

    let found: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let mut handles = Vec::new();

    // Scan in batches to avoid too many threads
    for batch_start in (1u16..255).step_by(32) {
        let batch_end = (batch_start + 32).min(255);
        let found = Arc::clone(&found);
        let base = [octets[0], octets[1], octets[2]];

        let handle = std::thread::spawn(move || {
            for i in batch_start..batch_end {
                // Early exit if another thread already found it
                if found.lock().unwrap().is_some() {
                    return;
                }

                let ip = Ipv4Addr::new(base[0], base[1], base[2], i as u8);
                if let Ok(true) = probe_linuxcam(ip, port) {
                    let mut f = found.lock().unwrap();
                    if f.is_none() {
                        *f = Some(ip.to_string());
                    }
                    return;
                }
            }
        });
        handles.push(handle);
    }

    for h in handles {
        let _ = h.join();
    }

    match Arc::try_unwrap(found).unwrap().into_inner().unwrap() {
        Some(ip) => {
            eprintln!("[vcam] Found LinuxCam at {ip}");
            Ok(ip)
        }
        None => bail!("no LinuxCam server found on local network"),
    }
}

/// Try connecting to an IP and check if it responds like LinuxCam
fn probe_linuxcam(ip: Ipv4Addr, port: u16) -> Result<bool> {
    let addr = std::net::SocketAddr::new(IpAddr::V4(ip), port);
    let stream = TcpStream::connect_timeout(&addr, Duration::from_millis(200))?;
    stream.set_read_timeout(Some(Duration::from_millis(500)))?;
    stream.set_write_timeout(Some(Duration::from_millis(500)))?;

    let mut stream = BufReader::new(stream);
    let request = format!("GET / HTTP/1.1\r\nHost: {ip}:{port}\r\nConnection: close\r\n\r\n");
    stream.get_mut().write_all(request.as_bytes())?;

    let mut response = String::new();
    // Read up to 2KB of response
    let mut buf = [0u8; 2048];
    if let Ok(n) = stream.read(&mut buf) {
        response = String::from_utf8_lossy(&buf[..n]).to_string();
    }

    Ok(response.contains("LinuxCam"))
}

/// Get the local machine's IP on the LAN
fn get_local_ip() -> Result<IpAddr> {
    // Connect to a public IP (doesn't actually send data) to determine local interface
    let socket = std::net::UdpSocket::bind("0.0.0.0:0")?;
    socket.connect("8.8.8.8:80")?;
    Ok(socket.local_addr()?.ip())
}

// ---------------------------------------------------------------------------
// Streaming
// ---------------------------------------------------------------------------

fn run_stream(ip: &str, args: &Args, mode: &OutputMode) -> Result<()> {
    let addr = format!("{ip}:{}", args.port);
    let stream = TcpStream::connect_timeout(
        &addr.parse().context("invalid address")?,
        Duration::from_secs(5),
    )
    .context("TCP connect failed")?;

    stream.set_nodelay(true)?;
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;

    let mut stream = BufReader::with_capacity(4 * 1024, stream);

    // Send HTTP GET /video
    let request = format!(
        "GET /video HTTP/1.1\r\nHost: {}\r\nConnection: keep-alive\r\n\r\n",
        addr
    );
    stream.get_mut().write_all(request.as_bytes())?;

    // Read HTTP response status
    let mut status_line = String::new();
    stream.read_line(&mut status_line)?;
    if !status_line.contains("200") {
        bail!("Server returned: {}", status_line.trim());
    }

    // Skip remaining headers
    loop {
        let mut line = String::new();
        stream.read_line(&mut line)?;
        if line.trim().is_empty() {
            break;
        }
    }

    // Spawn decoder/output process
    let mut child = spawn_output(args, mode)?;
    let child_stdin = child
        .stdin
        .as_mut()
        .context("failed to open process stdin")?;

    eprintln!("[vcam] Connected! Streaming...");

    let mut bytes_total: u64 = 0;
    let start = Instant::now();
    let mut last_report = Instant::now();

    // Always use raw streaming — the iOS server sends raw H.264 bytes
    // (despite the Transfer-Encoding: chunked header, broadcast() is not chunked)
    let result = stream_raw(&mut stream, child_stdin, &mut bytes_total, &start, &mut last_report);

    // Close stdin gracefully so ffmpeg can flush and finalize output
    drop(child.stdin.take());

    // Wait for ffmpeg to finish with a timeout
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                if !status.success() {
                    eprintln!("[vcam] ffmpeg exited with: {status}");
                }
                break;
            }
            Ok(None) => {
                if Instant::now() >= deadline {
                    eprintln!("[vcam] ffmpeg didn't exit in time, killing...");
                    let _ = child.kill();
                    let _ = child.wait();
                    break;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(e) => {
                eprintln!("[vcam] Error waiting for ffmpeg: {e}");
                let _ = child.kill();
                break;
            }
        }
    }

    result
}

fn stream_raw(
    reader: &mut BufReader<TcpStream>,
    writer: &mut dyn Write,
    bytes_total: &mut u64,
    start: &Instant,
    last_report: &mut Instant,
) -> Result<()> {
    let mut buf = vec![0u8; 8 * 1024];
    let mut frame_count: u64 = 0;
    let mut inter_frame_times: Vec<f64> = Vec::new();
    let mut recv_sizes: Vec<usize> = Vec::new();
    let mut last_recv = Instant::now();
    let mut last_timing_log = Instant::now();

    // NAL start code to detect frame boundaries
    let nal_start: [u8; 4] = [0x00, 0x00, 0x00, 0x01];
    // 8-byte timestamp header from iOS
    let mut pending_timestamp: Option<u64> = None;
    let mut network_delays: Vec<f64> = Vec::new();

    loop {
        let n = reader.read(&mut buf)?;
        if n == 0 {
            return Ok(());
        }

        let now_us = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_micros() as u64;

        // Check for 8-byte timestamp header before NAL start code
        // Format: [8 bytes big-endian microseconds][0x00 0x00 0x00 0x01 ...]
        if n >= 12 && buf[8..12] == nal_start {
            let ts = u64::from_be_bytes(buf[0..8].try_into().unwrap());
            if ts > 1_000_000_000_000_000 && ts < now_us + 60_000_000 {
                // Valid timestamp — measure clock-relative delay
                // Note: clocks aren't synced, so we track drift/jitter, not absolute
                pending_timestamp = Some(ts);
                let delay_ms = if now_us > ts {
                    (now_us - ts) as f64 / 1000.0
                } else {
                    0.0
                };
                network_delays.push(delay_ms);

                // Strip the 8-byte header, pass only H.264 to ffmpeg
                writer.write_all(&buf[8..n])?;
                *bytes_total += (n - 8) as u64;
            } else {
                writer.write_all(&buf[..n])?;
                *bytes_total += n as u64;
            }
        } else {
            writer.write_all(&buf[..n])?;
            *bytes_total += n as u64;
        }

        // Track inter-receive timing
        let inter = last_recv.elapsed().as_secs_f64() * 1000.0;
        inter_frame_times.push(inter);
        recv_sizes.push(n);
        last_recv = Instant::now();
        frame_count += 1;

        // Log timing stats every 2s
        if last_timing_log.elapsed() >= Duration::from_secs(2) {
            let avg_inter = inter_frame_times.iter().sum::<f64>() / inter_frame_times.len() as f64;
            let max_inter = inter_frame_times.iter().cloned().fold(0.0f64, f64::max);
            let avg_size = recv_sizes.iter().sum::<usize>() / recv_sizes.len();

            eprint!("[Timing] recv: avg={avg_inter:.1}ms max={max_inter:.1}ms avg_size={avg_size}B reads={}", recv_sizes.len());

            if !network_delays.is_empty() {
                let avg_net = network_delays.iter().sum::<f64>() / network_delays.len() as f64;
                let min_net = network_delays.iter().cloned().fold(f64::MAX, f64::min);
                eprint!(" | clock_delta: avg={avg_net:.0}ms min={min_net:.0}ms");
            }
            eprintln!();

            inter_frame_times.clear();
            recv_sizes.clear();
            network_delays.clear();
            last_timing_log = Instant::now();
        }

        report_stats(*bytes_total, start, last_report);
    }
}

fn report_stats(bytes_total: u64, start: &Instant, last_report: &mut Instant) {
    if last_report.elapsed() >= Duration::from_secs(5) {
        let elapsed = start.elapsed().as_secs_f64();
        let mbps = (bytes_total as f64 * 8.0) / (elapsed * 1_000_000.0);
        let mb = bytes_total as f64 / (1024.0 * 1024.0);
        eprintln!("[vcam] {mb:.1} MB received | {mbps:.2} Mbps avg");
        *last_report = Instant::now();
    }
}

fn spawn_output(args: &Args, mode: &OutputMode) -> Result<Child> {
    // Common low-latency input args
    let input_args = vec![
        "-fflags", "+nobuffer+genpts",
        "-flags", "low_delay",
        "-use_wallclock_as_timestamps", "1",
        "-probesize", "32",
        "-analyzeduration", "0",
        "-f", "h264",
        "-framerate", "30",
        "-i", "pipe:0",
    ];

    // Custom ffmpeg output override
    if let Some(extra) = &args.ffmpeg_out {
        let mut cmd = Command::new("ffmpeg");
        cmd.args(&input_args);
        cmd.args(extra);
        return cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .context("failed to spawn ffmpeg");
    }

    match mode {
        OutputMode::V4l2 => {
            Command::new("ffmpeg")
                .args(&input_args)
                .args(["-pix_fmt", &args.pix_fmt, "-f", "v4l2", &args.device])
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(Stdio::inherit())
                .spawn()
                .context("failed to spawn ffmpeg — is it installed?")
        }
        OutputMode::Play => {
            Command::new("ffplay")
                .args([
                    "-fflags", "+nobuffer+genpts",
                    "-flags", "low_delay",
                    "-probesize", "32",
                    "-analyzeduration", "0",
                    "-sync", "ext",
                    "-framedrop",
                    "-infbuf",
                    "-fast",
                    "-vf", "setpts=0",
                    "-f", "h264",
                    "-framerate", "30",
                    "-i", "pipe:0",
                ])
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(Stdio::inherit())
                .spawn()
                .context("failed to spawn ffplay — install ffmpeg (includes ffplay)")
        }
        OutputMode::File => {
            Command::new("ffmpeg")
                .args(&input_args)
                .args(["-c:v", "copy", "-y", &args.output])
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(Stdio::inherit())
                .spawn()
                .context("failed to spawn ffmpeg")
        }
    }
}
