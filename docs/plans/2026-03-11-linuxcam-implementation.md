# LinuxCam Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build an iOS app that streams the iPhone camera as MJPEG over HTTP for use as a Linux virtual webcam.

**Architecture:** CameraManager captures frames via AVCaptureSession, encodes to JPEG, and passes to MJPEGServer which broadcasts to connected HTTP clients via NWListener. ContentView provides fullscreen preview with overlay controls.

**Tech Stack:** Swift, SwiftUI, AVFoundation, Network (NWListener)

---

### Task 1: Add Info.plist Privacy Keys

**Files:**
- Modify: `IOS cam.xcodeproj/project.pbxproj` (build settings)

**Step 1: Add privacy usage descriptions to both Debug and Release target build settings**

Add these keys to both Debug and Release `XCBuildConfiguration` sections for the target (not the project):
```
INFOPLIST_KEY_NSCameraUsageDescription = "LinuxCam needs camera access to stream video";
INFOPLIST_KEY_NSLocalNetworkUsageDescription = "LinuxCam needs local network access to stream video to your computer";
```

**Step 2: Commit**
```bash
git add "IOS cam.xcodeproj/project.pbxproj"
git commit -m "feat: add camera and local network privacy keys"
```

---

### Task 2: Implement CameraManager

**Files:**
- Create: `IOS cam/CameraManager.swift`

**Step 1: Write CameraManager.swift**

```swift
import AVFoundation
import UIKit

@Observable
final class CameraManager: NSObject {
    // Published state
    var isRunning = false
    var currentPosition: AVCaptureDevice.Position = .back
    var currentResolution: AVCaptureSession.Preset = .hd1920x1080
    var jpegQuality: CGFloat = 0.6

    // Latest JPEG frame for MJPEG server
    private(set) var latestFrame: Data?

    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.linuxcam.capture", qos: .userInteractive)
    private var currentInput: AVCaptureDeviceInput?

    var previewSession: AVCaptureSession { session }

    func start() {
        guard !isRunning else { return }
        captureQueue.async { [self] in
            configureSession()
            session.startRunning()
            Task { @MainActor in isRunning = true }
        }
    }

    func stop() {
        captureQueue.async { [self] in
            session.stopRunning()
            Task { @MainActor in
                isRunning = false
                latestFrame = nil
            }
        }
    }

    func toggleCamera() {
        let newPosition: AVCaptureDevice.Position = (currentPosition == .back) ? .front : .back
        currentPosition = newPosition
        if isRunning {
            captureQueue.async { [self] in
                configureSession()
            }
        }
    }

    func setResolution(_ preset: AVCaptureSession.Preset) {
        currentResolution = preset
        if isRunning {
            captureQueue.async { [self] in
                configureSession()
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = currentResolution

        // Remove existing input
        if let currentInput {
            session.removeInput(currentInput)
        }

        // Add camera input
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentPosition),
              let input = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration()
            return
        }

        if session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
        }

        // Configure frame rate
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        } catch {}

        // Add video output (only once)
        if session.outputs.isEmpty {
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: captureQueue)
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
        }

        session.commitConfiguration()
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let uiImage = UIImage(cgImage: cgImage)
        let quality = MainActor.assumeIsolated { self.jpegQuality }
        guard let jpegData = uiImage.jpegData(compressionQuality: quality) else { return }
        Task { @MainActor in
            self.latestFrame = jpegData
        }
    }
}
```

**Step 2: Commit**
```bash
git add "IOS cam/CameraManager.swift"
git commit -m "feat: implement CameraManager with AVCaptureSession and JPEG encoding"
```

---

### Task 3: Implement MJPEGServer

**Files:**
- Create: `IOS cam/MJPEGServer.swift`

**Step 1: Write MJPEGServer.swift**

```swift
import Foundation
import Network

@Observable
final class MJPEGServer {
    var isRunning = false
    var connectedClients = 0
    var serverAddress: String = "—"

    private var listener: NWListener?
    private let serverQueue = DispatchQueue(label: "com.linuxcam.server", qos: .userInteractive)
    private var connections: [NWConnection] = []
    private let boundary = "frame"
    private let port: UInt16 = 8080

    func start() {
        guard !isRunning else { return }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isRunning = true
                    self?.updateAddress()
                case .failed, .cancelled:
                    self?.isRunning = false
                    self?.serverAddress = "—"
                default:
                    break
                }
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: serverQueue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for conn in connections {
            conn.cancel()
        }
        connections.removeAll()
        isRunning = false
        connectedClients = 0
        serverAddress = "—"
    }

    func broadcast(jpegData: Data) {
        let header = "--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpegData.count)\r\n\r\n"
        guard let headerData = header.data(using: .utf8) else { return }
        let frameData = headerData + jpegData + "\r\n".data(using: .utf8)!

        for connection in connections {
            connection.send(content: frameData, completion: .contentProcessed { _ in })
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                switch state {
                case .ready:
                    break
                case .failed, .cancelled:
                    self.removeConnection(connection)
                default:
                    break
                }
            }
        }

        connection.start(queue: serverQueue)
        receiveHTTPRequest(on: connection)
    }

    private func receiveHTTPRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] content, _, _, error in
            guard let self, let content, error == nil else {
                connection.cancel()
                return
            }

            let request = String(data: content, encoding: .utf8) ?? ""
            if request.contains("GET /video") {
                self.sendMJPEGHeader(on: connection)
            } else if request.contains("GET / ") || request.contains("GET / HTTP") || request.hasPrefix("GET / ") {
                self.sendHTMLPage(on: connection)
            } else if request.contains("GET /") {
                // Default to HTML page for any other GET
                self.sendHTMLPage(on: connection)
            }
        }
    }

    private func sendMJPEGHeader(on connection: NWConnection) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=\(boundary)\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nPragma: no-cache\r\n\r\n"
        guard let data = header.data(using: .utf8) else { return }

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { return }
            Task { @MainActor in
                self.connections.append(connection)
                self.connectedClients = self.connections.count
            }
        })
    }

    private func sendHTMLPage(on connection: NWConnection) {
        let html = """
        <!DOCTYPE html>
        <html><head><title>LinuxCam</title>
        <style>body{margin:0;background:#000;display:flex;justify-content:center;align-items:center;height:100vh}img{max-width:100%;max-height:100vh}</style>
        </head><body><img src="/video"></body></html>
        """
        let body = html.data(using: .utf8)!
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let response = header.data(using: .utf8)! + body

        connection.send(content: response, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
        connectedClients = connections.count
    }

    private func updateAddress() {
        var address = "—"
        for interface in getWiFiAddress() {
            address = "\(interface):\(port)"
            break
        }
        serverAddress = address
    }

    private func getWiFiAddress() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return addresses }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    addresses.append(String(cString: hostname))
                }
            }
        }
        return addresses
    }
}
```

**Step 2: Commit**
```bash
git add "IOS cam/MJPEGServer.swift"
git commit -m "feat: implement MJPEGServer with NWListener HTTP server"
```

---

### Task 4: Implement ContentView with Camera Preview

**Files:**
- Modify: `IOS cam/ContentView.swift`
- Create: `IOS cam/CameraPreview.swift`

**Step 1: Write CameraPreview.swift (UIViewRepresentable for AVCaptureVideoPreviewLayer)**

```swift
import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        context.coordinator.previewLayer = previewLayer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.previewLayer?.frame = uiView.bounds
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}
```

**Step 2: Rewrite ContentView.swift**

```swift
import SwiftUI

struct ContentView: View {
    @State private var camera = CameraManager()
    @State private var server = MJPEGServer()
    @State private var is4K = false

    var body: some View {
        ZStack {
            // Fullscreen camera preview
            CameraPreview(session: camera.previewSession)
                .ignoresSafeArea()

            // Overlay controls at bottom
            VStack {
                Spacer()

                VStack(spacing: 12) {
                    // IP address
                    if server.isRunning {
                        Text(server.serverAddress)
                            .font(.system(.title3, design: .monospaced))
                            .foregroundColor(.white)
                    }

                    // Client count
                    HStack {
                        Circle()
                            .fill(server.connectedClients > 0 ? .green : .gray)
                            .frame(width: 8, height: 8)
                        Text("\(server.connectedClients) client\(server.connectedClients == 1 ? "" : "s")")
                            .foregroundColor(.white)
                            .font(.caption)
                    }

                    // JPEG quality slider
                    HStack {
                        Text("Quality")
                            .foregroundColor(.white)
                            .font(.caption)
                        Slider(value: $camera.jpegQuality, in: 0.1...1.0, step: 0.1)
                        Text("\(Int(camera.jpegQuality * 100))%")
                            .foregroundColor(.white)
                            .font(.caption)
                            .frame(width: 40)
                    }
                    .padding(.horizontal)

                    // Controls row
                    HStack(spacing: 20) {
                        // Resolution toggle
                        Button {
                            is4K.toggle()
                            camera.setResolution(is4K ? .hd4K3840x2160 : .hd1920x1080)
                        } label: {
                            Text(is4K ? "4K" : "1080p")
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .cornerRadius(8)
                        }

                        // Flip camera
                        Button {
                            camera.toggleCamera()
                        } label: {
                            Image(systemName: "camera.rotate")
                                .font(.title2)
                                .padding(10)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }

                        // Start/Stop
                        Button {
                            if server.isRunning {
                                server.stop()
                                camera.stop()
                            } else {
                                camera.start()
                                server.start()
                            }
                        } label: {
                            Image(systemName: server.isRunning ? "stop.circle.fill" : "play.circle.fill")
                                .font(.system(size: 50))
                                .foregroundColor(server.isRunning ? .red : .green)
                        }
                    }
                }
                .padding()
                .background(.ultraThinMaterial.opacity(0.8))
                .cornerRadius(20)
                .padding()
            }
        }
        .onChange(of: camera.latestFrame) { _, newFrame in
            guard let frame = newFrame, server.isRunning else { return }
            server.broadcast(jpegData: frame)
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
    }
}
```

**Step 3: Commit**
```bash
git add "IOS cam/CameraPreview.swift" "IOS cam/ContentView.swift"
git commit -m "feat: implement fullscreen camera UI with overlay controls"
```

---

### Task 5: Wire Up Info.plist and Final Polish

**Step 1: Verify the app builds in Xcode**

Open Xcode, build for a real device (camera not available in simulator).

**Step 2: Test on device**
- Camera preview should show fullscreen
- Start button should start capture + server
- Open `http://<iphone-ip>:8080/` in browser → see video
- Test `http://<iphone-ip>:8080/video` with curl or ffmpeg

**Step 3: Test from Linux**
```bash
ffmpeg -i http://<iphone-ip>:8080/video -vf format=yuv420p -f v4l2 /dev/video4
```
