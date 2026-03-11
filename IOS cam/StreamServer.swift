//
//  StreamServer.swift
//  IOS cam
//
//  Created by Justin De Sio on 11/03/2026.
//

import Foundation
import Network

@Observable
final class StreamServer {

    // MARK: - Published State

    var isRunning = false
    var connectedClients = 0
    var serverAddress = "Not connected"

    // MARK: - Private

    private let serverQueue = DispatchQueue(label: "com.linuxcam.server", qos: .userInteractive)
    private var listener: NWListener?

    @ObservationIgnored nonisolated(unsafe) private var connections: [NWConnection] = []
    private let connectionsLock = NSLock()

    /// Called when a new client connects — use to force a keyframe.
    @ObservationIgnored nonisolated(unsafe) var onClientConnected: (() -> Void)?
    /// Provides initial data (SPS/PPS) to send to a new client.
    @ObservationIgnored nonisolated(unsafe) var initialDataForClient: (() -> Data?)?

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

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            listener = try NWListener(using: params, on: 8080)
        } catch {
            print("[StreamServer] Failed to create listener: \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isRunning = true
                    self.serverAddress = "\(self.getWiFiAddress() ?? "unknown"):8080"
                }
            case .failed(let error):
                print("[StreamServer] Listener failed: \(error)")
                Task { @MainActor [weak self] in
                    self?.isRunning = false
                }
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: serverQueue)
    }

    func stop() {
        guard isRunning else { return }

        listener?.cancel()
        listener = nil

        connectionsLock.lock()
        let currentConnections = connections
        connections.removeAll()
        connectionsLock.unlock()

        for conn in currentConnections {
            conn.cancel()
        }

        isRunning = false
        connectedClients = 0
        serverAddress = "Not connected"
    }

    // MARK: - Broadcasting

    /// Push raw H.264 data to all connected stream clients.
    nonisolated func broadcast(data: Data) {
        serverQueue.async { [weak self] in
            guard let self else { return }
            self.connectionsLock.lock()
            let clients = self.connections
            self.connectionsLock.unlock()

            for connection in clients {
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        print("[StreamServer] Send error: \(error)")
                        self.removeConnection(connection)
                    }
                })
            }
        }
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.removeConnection(connection)
            default:
                break
            }
        }

        connection.start(queue: serverQueue)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }

            let request = String(data: data, encoding: .utf8) ?? ""
            self.handleHTTPRequest(request, on: connection)
        }
    }

    private func handleHTTPRequest(_ request: String, on connection: NWConnection) {
        let firstLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        let method = parts.count > 0 ? parts[0] : ""
        let path = parts.count > 1 ? parts[1] : ""

        guard method == "GET" else {
            sendHTTPResponse(connection: connection, status: "405 Method Not Allowed",
                             contentType: "text/plain", body: Data("Method Not Allowed".utf8))
            return
        }

        switch path {
        case "/":
            sendHTTPResponse(connection: connection, status: "200 OK",
                             contentType: "text/html", body: htmlPage)

        case "/video":
            startH264Stream(on: connection)

        default:
            sendHTTPResponse(connection: connection, status: "404 Not Found",
                             contentType: "text/plain", body: Data("Not Found".utf8))
        }
    }

    private func sendHTTPResponse(connection: NWConnection, status: String,
                                  contentType: String, body: Data) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"

        var response = Data(header.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func startH264Stream(on connection: NWConnection) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: video/h264\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"

        // Build initial payload: HTTP header + cached SPS/PPS if available
        var initialPayload = Data(header.utf8)
        if let paramSets = initialDataForClient?() {
            initialPayload.append(paramSets)
        }

        connection.send(content: initialPayload, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                print("[StreamServer] Failed to send stream header: \(error)")
                connection.cancel()
                return
            }

            self.addConnection(connection)
            // Request a keyframe so the new client gets SPS/PPS + IDR immediately
            self.onClientConnected?()
        })
    }

    // MARK: - Connection Tracking

    private func addConnection(_ connection: NWConnection) {
        connectionsLock.lock()
        connections.append(connection)
        let count = connections.count
        connectionsLock.unlock()

        Task { @MainActor [weak self] in
            self?.connectedClients = count
        }
    }

    private func removeConnection(_ connection: NWConnection) {
        connectionsLock.lock()
        connections.removeAll { $0 === connection }
        let count = connections.count
        connectionsLock.unlock()

        connection.cancel()

        Task { @MainActor [weak self] in
            self?.connectedClients = count
        }
    }

    // MARK: - Helpers

    nonisolated private func getWiFiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            guard addrFamily == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            guard name == "en0" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count),
                        nil, socklen_t(0), NI_NUMERICHOST)
            address = String(cString: hostname)
            break
        }

        return address
    }
}
