//
//  MJPEGServer.swift
//  IOS cam
//
//  Created by Justin De Sio on 11/03/2026.
//

import Foundation
import Network

@Observable
final class MJPEGServer {

    // MARK: - Published State

    var isRunning = false
    var connectedClients = 0
    var serverAddress = "Not connected"

    // MARK: - Private

    private let serverQueue = DispatchQueue(label: "com.linuxcam.server", qos: .userInteractive)
    private var listener: NWListener?

    /// Client connections serving the MJPEG stream.
    /// Accessed from both serverQueue and MainActor — guarded by `connectionsLock`.
    nonisolated(unsafe) private var connections: [NWConnection] = []
    nonisolated(unsafe) private let connectionsLock = NSLock()

    private let boundary = "frame"

    private let htmlPage = Data("""
        <!DOCTYPE html>
        <html><head><title>LinuxCam</title>
        <style>body{margin:0;background:#000;display:flex;justify-content:center;align-items:center;height:100vh}img{max-width:100%;max-height:100vh}</style>
        </head><body><img src="/video"></body></html>
        """.utf8)

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            listener = try NWListener(using: params, on: 8080)
        } catch {
            print("[MJPEGServer] Failed to create listener: \(error)")
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
                print("[MJPEGServer] Listener failed: \(error)")
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

    /// Push a JPEG frame to all connected MJPEG clients.
    /// Called from MainActor (via onChange in ContentView); dispatches to serverQueue.
    func broadcast(jpegData: Data) {
        let framePayload = buildFramePayload(jpegData: jpegData)

        serverQueue.async { [weak self] in
            guard let self else { return }
            self.connectionsLock.lock()
            let clients = self.connections
            self.connectionsLock.unlock()

            for connection in clients {
                connection.send(content: framePayload, completion: .contentProcessed { error in
                    if let error {
                        print("[MJPEGServer] Send error: \(error)")
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

        // Read the HTTP request
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
                             contentType: "text/plain", body: Data("Method Not Allowed".utf8),
                             keepAlive: false)
            return
        }

        switch path {
        case "/":
            sendHTTPResponse(connection: connection, status: "200 OK",
                             contentType: "text/html", body: htmlPage,
                             keepAlive: false)

        case "/video":
            startMJPEGStream(on: connection)

        default:
            sendHTTPResponse(connection: connection, status: "404 Not Found",
                             contentType: "text/plain", body: Data("Not Found".utf8),
                             keepAlive: false)
        }
    }

    private func sendHTTPResponse(connection: NWConnection, status: String,
                                  contentType: String, body: Data, keepAlive: Bool) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"

        var response = Data(header.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            if !keepAlive {
                connection.cancel()
            }
        })
    }

    private func startMJPEGStream(on connection: NWConnection) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=\(boundary)\r\nConnection: keep-alive\r\n\r\n"

        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                print("[MJPEGServer] Failed to send stream header: \(error)")
                connection.cancel()
                return
            }

            self.addConnection(connection)
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

    private func buildFramePayload(jpegData: Data) -> Data {
        var payload = Data("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpegData.count)\r\n\r\n".utf8)
        payload.append(jpegData)
        payload.append(Data("\r\n".utf8))
        return payload
    }

    /// Get the device's WiFi IP address by scanning network interfaces for en0 (AF_INET).
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
