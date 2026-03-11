//
//  CameraManager.swift
//  IOS cam
//
//  Created by Justin De Sio on 11/03/2026.
//

import AVFoundation
import CoreImage
import UIKit
import os

@Observable
final class CameraManager: NSObject {

    // MARK: - Published State

    var isRunning = false
    var currentPosition: AVCaptureDevice.Position = .back
    var latestFrame: Data?

    /// Direct callback for frame delivery — called on the capture queue.
    @ObservationIgnored nonisolated(unsafe) var onFrameCaptured: (@Sendable (Data) -> Void)?

    /// JPEG compression quality (0.1 – 1.0). Default 0.6.
    var jpegQuality: CGFloat = 0.6 {
        didSet {
            let clamped = min(max(jpegQuality, 0.1), 1.0)
            if jpegQuality != clamped { jpegQuality = clamped }
            _captureQuality.withLock { $0 = clamped }
        }
    }

    /// Expose the session so SwiftUI can show a camera preview.
    var previewSession: AVCaptureSession { session }

    // MARK: - Private

    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.linuxcam.capture", qos: .userInteractive)
    private let ciContext = CIContext()

    /// Thread-safe mirror of `jpegQuality` for use on the capture queue.
    private let _captureQuality = OSAllocatedUnfairLock(initialState: CGFloat(0.6))

    private var currentResolution: AVCaptureSession.Preset = .hd1920x1080

    /// Current video rotation angle based on device orientation.
    @ObservationIgnored private let _rotationAngle = OSAllocatedUnfairLock(initialState: CGFloat(90))

    // MARK: - Lifecycle

    /// Start the capture session on the dedicated queue.
    func start() {
        guard !isRunning else { return }
        let position = currentPosition
        let resolution = currentResolution
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self, selector: #selector(orientationChanged),
            name: UIDevice.orientationDidChangeNotification, object: nil
        )
        updateRotationAngle(UIDevice.current.orientation)
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.configureCaptureSession(position: position, resolution: resolution)
            self.session.startRunning()
            Task { @MainActor [weak self] in
                self?.isRunning = true
            }
        }
    }

    /// Stop the capture session.
    func stop() {
        guard isRunning else { return }
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            Task { @MainActor [weak self] in
                self?.isRunning = false
            }
        }
    }

    @objc private func orientationChanged() {
        updateRotationAngle(UIDevice.current.orientation)
    }

    private func updateRotationAngle(_ orientation: UIDeviceOrientation) {
        let angle: CGFloat
        switch orientation {
        case .portrait:            angle = 90
        case .portraitUpsideDown:   angle = 270
        case .landscapeLeft:       angle = 0
        case .landscapeRight:      angle = 180
        default: return // .faceUp, .faceDown, .unknown — keep current
        }
        _rotationAngle.withLock { $0 = angle }
    }

    /// Toggle between front and back camera.
    func toggleCamera() {
        currentPosition = (currentPosition == .back) ? .front : .back
        let position = currentPosition
        let resolution = currentResolution
        captureQueue.async { [weak self] in
            self?.reconfigureCamera(position: position, resolution: resolution)
        }
    }

    /// Switch between 1080p and 4K resolution.
    func setResolution(_ preset: AVCaptureSession.Preset) {
        guard preset == .hd1920x1080 || preset == .hd4K3840x2160 else { return }
        currentResolution = preset
        let position = currentPosition
        let resolution = preset
        captureQueue.async { [weak self] in
            self?.reconfigureCamera(position: position, resolution: resolution)
        }
    }

    // MARK: - Session Configuration

    /// Full initial configuration — called once from `start()`.
    private func configureCaptureSession(position: AVCaptureDevice.Position, resolution: AVCaptureSession.Preset) {
        session.beginConfiguration()
        session.sessionPreset = resolution

        // Add input
        if let device = cameraDevice(for: position),
           let input = try? AVCaptureDeviceInput(device: device) {
            if session.canAddInput(input) {
                session.addInput(input)
            }
            configure(device: device)
        }

        // Add video data output
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        session.commitConfiguration()
    }

    /// Reconfigure input after camera toggle or resolution change.
    private func reconfigureCamera(position: AVCaptureDevice.Position, resolution: AVCaptureSession.Preset) {
        session.beginConfiguration()
        session.sessionPreset = resolution

        // Remove existing inputs
        for input in session.inputs {
            session.removeInput(input)
        }

        // Add new input
        if let device = cameraDevice(for: position),
           let input = try? AVCaptureDeviceInput(device: device) {
            if session.canAddInput(input) {
                session.addInput(input)
            }
            configure(device: device)
        }

        session.commitConfiguration()
    }

    /// Find the appropriate AVCaptureDevice for the given position.
    private func cameraDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        return discoverySession.devices.first
    }

    /// Lock the device and set 30 fps.
    private func configure(device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let frameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
        } catch {
            print("[CameraManager] Failed to configure device: \(error)")
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let rotationAngle = _rotationAngle.withLock { $0 }

        // Apply rotation to match device orientation.
        // The raw camera buffer is always in landscape-left (sensor native).
        // We rotate using videoRotationAngle on the connection if supported.
        if connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let quality = _captureQuality.withLock { $0 }
        guard let jpegData = ciContext.jpegRepresentation(
            of: ciImage,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
        ) else { return }

        onFrameCaptured?(jpegData)

        Task { @MainActor [weak self] in
            self?.latestFrame = jpegData
        }
    }
}
