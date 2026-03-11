//
//  CameraManager.swift
//  IOS cam
//
//  Created by Justin De Sio on 11/03/2026.
//

import AVFoundation
import CoreImage
import UIKit

@Observable
final class CameraManager: NSObject {

    // MARK: - Published State

    var isRunning = false
    var currentPosition: AVCaptureDevice.Position = .back
    var latestFrame: Data?

    /// JPEG compression quality (0.1 – 1.0). Default 0.6.
    var jpegQuality: CGFloat = 0.6 {
        didSet {
            let clamped = min(max(jpegQuality, 0.1), 1.0)
            if jpegQuality != clamped { jpegQuality = clamped }
            _captureQuality = clamped
        }
    }

    /// Expose the session so SwiftUI can show a camera preview.
    var previewSession: AVCaptureSession { session }

    // MARK: - Private

    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.linuxcam.capture", qos: .userInteractive)
    private let ciContext = CIContext()

    /// Mirror of `jpegQuality` that is safe to read from the capture queue.
    /// Updated on every `jpegQuality` didSet so we never touch MainActor state
    /// from the delegate callback.
    nonisolated(unsafe) private var _captureQuality: CGFloat = 0.6

    private var currentResolution: AVCaptureSession.Preset = .hd1920x1080

    // MARK: - Lifecycle

    override init() {
        super.init()
        _captureQuality = jpegQuality
    }

    /// Start the capture session on the dedicated queue.
    func start() {
        guard !isRunning else { return }
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.configureCaptureSession()
            self.session.startRunning()
            Task { @MainActor [weak self] in
                self?.isRunning = true
            }
        }
    }

    /// Stop the capture session.
    func stop() {
        guard isRunning else { return }
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            Task { @MainActor [weak self] in
                self?.isRunning = false
            }
        }
    }

    /// Toggle between front and back camera.
    func toggleCamera() {
        currentPosition = (currentPosition == .back) ? .front : .back
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.reconfigureCamera()
        }
    }

    /// Switch between 1080p and 4K resolution.
    func setResolution(_ preset: AVCaptureSession.Preset) {
        guard preset == .hd1920x1080 || preset == .hd4K3840x2160 else { return }
        currentResolution = preset
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.reconfigureCamera()
        }
    }

    // MARK: - Session Configuration

    /// Full initial configuration — called once from `start()`.
    private func configureCaptureSession() {
        session.beginConfiguration()
        session.sessionPreset = currentResolution

        // Add input
        if let device = cameraDevice(for: currentPosition),
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
    private func reconfigureCamera() {
        session.beginConfiguration()
        session.sessionPreset = currentResolution

        // Remove existing inputs
        for input in session.inputs {
            session.removeInput(input)
        }

        // Add new input
        if let device = cameraDevice(for: currentPosition),
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

extension CameraManager: @preconcurrency AVCaptureVideoDataOutputSampleBufferDelegate {

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        let quality = _captureQuality
        let uiImage = UIImage(cgImage: cgImage)
        guard let jpegData = uiImage.jpegData(compressionQuality: quality) else { return }

        Task { @MainActor [weak self] in
            self?.latestFrame = jpegData
        }
    }
}
