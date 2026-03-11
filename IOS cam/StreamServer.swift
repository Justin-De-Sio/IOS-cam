import Foundation
import Network
import QuartzCore

@Observable
final class StreamServer {

    var isRunning = false
    var connectedClients = 0
    var serverAddress = "Not connected"

    @ObservationIgnored nonisolated(unsafe) var onClientConnected: (() -> Void)?
    @ObservationIgnored nonisolated(unsafe) var initialDataForClient: (() -> Data?)?

    private let queue = DispatchQueue(label: "com.linuxcam.server", qos: .userInteractive)
    private var listener: NWListener?
    @ObservationIgnored nonisolated(unsafe) private var connections: [NWConnection] = []
    @ObservationIgnored nonisolated(unsafe) private var droppedFrames: [ObjectIdentifier: Int] = [:]
    private let lock = NSLock()
    private let maxDroppedBeforeDisconnect = 30

    private let htmlPage = Data("""
        <!DOCTYPE html>
        <html><head><title>LinuxCam</title>
        <style>body{margin:0;background:#111;color:#fff;font-family:system-ui;display:flex;justify-content:center;align-items:center;height:100vh;flex-direction:column}
        code{background:#333;padding:4px 8px;border-radius:4px}</style>
        </head><body>
        <h2>LinuxCam H.264 Stream</h2>
        <p>Stream available at <code>/video</code></p>
        <p>Usage: <code>ffmpeg -f h264 -i http://&lt;ip&gt;:8080/video -f v4l2 /dev/video4</code></p>
        </body></html>
        """.utf8)

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true

        do { listener = try NWListener(using: params, on: 8080) }
        catch { print("[StreamServer] Listener failed: \(error)"); return }

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isRunning = true
                    self.serverAddress = "\(self.wifiAddress ?? "unknown"):8080"
                }
            }
        }

        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleNew(conn)
        }
        listener?.start(queue: queue)
    }

    func stop() {
        guard isRunning else { return }
        listener?.cancel()
        listener = nil

        lock.lock()
        let current = connections
        connections.removeAll()
        lock.unlock()
        current.forEach { $0.cancel() }

        isRunning = false
        connectedClients = 0
        serverAddress = "Not connected"
    }

    // MARK: - Broadcasting

    @ObservationIgnored nonisolated(unsafe) private var sendTimesMs: [Double] = []
    @ObservationIgnored nonisolated(unsafe) private var lastSendLog = CACurrentMediaTime()

    nonisolated func broadcast(data: Data) {
        let queueStart = CACurrentMediaTime()
        queue.async { [weak self] in
            guard let self else { return }
            let dispatchMs = (CACurrentMediaTime() - queueStart) * 1000.0
            if dispatchMs > 1.0 {
                print(String(format: "[Timing] queue dispatch: %.1fms", dispatchMs))
            }

            self.lock.lock()
            let clients = self.connections
            self.lock.unlock()

            for conn in clients {
                let id = ObjectIdentifier(conn)
                let sendStart = CACurrentMediaTime()
                conn.send(content: data, contentContext: .defaultMessage, isComplete: false,
                          completion: .contentProcessed { [weak self] error in
                    let sendMs = (CACurrentMediaTime() - sendStart) * 1000.0
                    guard let self else { return }
                    self.sendTimesMs.append(sendMs)
                    let now = CACurrentMediaTime()
                    if now - self.lastSendLog >= 2.0 {
                        let avg = self.sendTimesMs.reduce(0, +) / Double(self.sendTimesMs.count)
                        let max = self.sendTimesMs.max() ?? 0
                        print(String(format: "[Timing] TCP send: avg=%.1fms max=%.1fms frames=%d",
                                     avg, max, self.sendTimesMs.count))
                        self.sendTimesMs.removeAll()
                        self.lastSendLog = now
                    }
                    if let error {
                        self.lock.lock()
                        let count = (self.droppedFrames[id] ?? 0) + 1
                        self.droppedFrames[id] = count
                        self.lock.unlock()
                        print("[StreamServer] Send error (\(count)/\(self.maxDroppedBeforeDisconnect)): \(error)")
                        if count >= self.maxDroppedBeforeDisconnect {
                            self.remove(conn)
                            self.lock.lock()
                            self.droppedFrames.removeValue(forKey: id)
                            self.lock.unlock()
                        }
                    } else {
                        self.lock.lock()
                        self.droppedFrames.removeValue(forKey: id)
                        self.lock.unlock()
                    }
                })
            }
        }
    }

    // MARK: - Connection Handling

    private func handleNew(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.remove(conn) }
            if case .cancelled = state { self?.remove(conn) }
        }
        conn.start(queue: queue)

        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { conn.cancel(); return }
            let request = String(data: data, encoding: .utf8) ?? ""
            self.route(request, on: conn)
        }
    }

    private func route(_ request: String, on conn: NWConnection) {
        let parts = (request.components(separatedBy: "\r\n").first ?? "").components(separatedBy: " ")
        let method = parts.count > 0 ? parts[0] : ""
        let path = parts.count > 1 ? parts[1] : ""

        guard method == "GET" else {
            respond(conn, status: "405 Method Not Allowed", type: "text/plain", body: Data("Method Not Allowed".utf8))
            return
        }

        switch path {
        case "/":      respond(conn, status: "200 OK", type: "text/html", body: htmlPage)
        case "/video": startStream(on: conn)
        default:       respond(conn, status: "404 Not Found", type: "text/plain", body: Data("Not Found".utf8))
        }
    }

    private func respond(_ conn: NWConnection, status: String, type: String, body: Data) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func startStream(on conn: NWConnection) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: video/h264\r\nCache-Control: no-cache\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n"
        var payload = Data(header.utf8)
        if let params = initialDataForClient?() { payload.append(params) }

        conn.send(content: payload, contentContext: .defaultMessage, isComplete: false,
                  completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { conn.cancel(); return }
            self.add(conn)
            self.onClientConnected?()
        })
    }

    // MARK: - Tracking

    private func add(_ conn: NWConnection) {
        lock.lock()
        connections.append(conn)
        let count = connections.count
        lock.unlock()
        Task { @MainActor [weak self] in self?.connectedClients = count }
    }

    private func remove(_ conn: NWConnection) {
        lock.lock()
        connections.removeAll { $0 === conn }
        let count = connections.count
        lock.unlock()
        conn.cancel()
        Task { @MainActor [weak self] in self?.connectedClients = count }
    }

    // MARK: - Helpers

    nonisolated private var wifiAddress: String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            guard iface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: iface.ifa_name) == "en0" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            return String(cString: hostname)
        }
        return nil
    }
}
