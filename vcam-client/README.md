# vcam-client

Rust client that streams H.264 video from the iOS LinuxCam app to a virtual camera or preview window.

## Prerequisites

```bash
# Both platforms need ffmpeg
# macOS
brew install ffmpeg

# Linux (Ubuntu/Debian)
sudo apt install ffmpeg v4l2loopback-dkms

# Linux: load virtual camera device
sudo modprobe v4l2loopback devices=1 video_nr=4 card_label="LinuxCam" exclusive_caps=1
```

## Build

```bash
cargo build --release
```

## Usage

```bash
# macOS — opens a preview window (default on macOS)
./target/release/vcam-client --ip 192.168.1.42

# Linux — outputs to v4l2 virtual camera (default on Linux)
./target/release/vcam-client --ip 192.168.1.42

# Explicit mode selection
./target/release/vcam-client --ip 192.168.1.42 --mode play    # preview window
./target/release/vcam-client --ip 192.168.1.42 --mode v4l2    # virtual camera
./target/release/vcam-client --ip 192.168.1.42 --mode file -o capture.mp4  # save to file

# Custom v4l2 device
./target/release/vcam-client --ip 192.168.1.42 --device /dev/video2

# Custom ffmpeg output (full control)
./target/release/vcam-client --ip 192.168.1.42 --ffmpeg-out -c:v libx264 -f mpegts udp://localhost:1234

# Disable auto-reconnect
./target/release/vcam-client --ip 192.168.1.42 --reconnect false
```

## Output Modes

| Mode | Platform | Description |
|------|----------|-------------|
| `v4l2` | Linux (default) | Writes decoded frames to v4l2loopback — apps see it as a webcam |
| `play` | macOS (default) | Opens an ffplay window with low-latency preview |
| `file` | Any | Saves H.264 stream to an MP4 file |
| `--ffmpeg-out` | Any | Pass arbitrary ffmpeg output args |

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `-i, --ip` | required | iPhone IP address |
| `-p, --port` | 8080 | Server port |
| `-m, --mode` | auto (v4l2 on Linux, play on macOS) | Output mode |
| `-d, --device` | /dev/video4 | v4l2loopback device path |
| `-o, --output` | output.mp4 | Output file path (file mode) |
| `--pix-fmt` | yuv420p | Pixel format for v4l2 output |
| `-r, --reconnect` | true | Auto-reconnect on disconnect |
| `--reconnect-delay` | 2 | Seconds between reconnect attempts |
| `--ffmpeg-out` | — | Custom ffmpeg output args (overrides mode) |
