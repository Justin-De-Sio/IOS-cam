//
//  CameraManager.swift
//  IOS cam
//
//  Created by Justin De Sio on 11/03/2026.
//

import AVFoundation
import VideoToolbox
import UIKit
import os

// MARK: - Stream Profile

enum StreamProfile: String, CaseIterable {
    case lowLatency
    case highQuality

    var displayName: String {
        switch self {
        case .lowLatency:  return "Low Latency"
        case .highQuality: return "High Quality"
        }
    }

    var resolution: AVCaptureSession.Preset {
        switch self {
        case .lowLatency:  return .hd1280x720
        case .highQuality: return .hd1920x1080
        }
    }

    var bitrate: Int {
        switch self {
        case .lowLatency:  return 1_500_000   // 1.5 Mbps
        case .highQuality: return 5_000_000   // 5 Mbps
        }
    }

    var profileLevel: CFString {
        switch self {
        case .lowLatency:  return kVTProfileLevel_H264_Baseline_AutoLevel
        case .highQuality: return kVTProfileLevel_H264_High_AutoLevel
        }
    }

    var keyFrameInterval: Int {
        switch self {
        case .lowLatency:  return 30   // 1s at 30fps — frequent keyframes for low latency
        case .highQuality: return 90   // 3s at 30fps — better compression
        }
    }

    var frameRate: Int32 {
        switch self {
        case .lowLatency:  return 30
        case .highQuality: return 30
        }
    }

    var description: String {
        switch self {
        case .lowLatency:  return "720p \u{2022} 1.5Mbps \u{2022} Baseline"
        case .highQuality: return "1080p \u{2022} 5Mbps \u{2022} High"
        }
    }
}

@Observable
final class CameraManager: NSObject {

    // MARK: - Published State

    var isRunning = false
    var currentPosition: AVCaptureDevice.Position = .back
    var currentProfile: StreamProfile = .lowLatency

    /// Direct callback for H.264 data delivery — called on the capture queue.
    @ObservationIgnored nonisolated(unsafe) var onH264Data: (@Sendable (Data) -> Void)?

    /// Expose the session so SwiftUI can show a camera preview.
    var previewSession: AVCaptureSession { session }

    // MARK: - Private

    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.linuxcam.capture", qos: .userInteractive)

    private var currentResolution: AVCaptureSession.Preset = .hd1280x720

    /// Current video rotation angle based on device orientation.
    @ObservationIgnored private let _rotationAngle = OSAllocatedUnfairLock(initialState: CGFloat(90))

    /// H.264 hardware encoder session.
    @ObservationIgnored nonisolated(unsafe) private var compressionSession: VTCompressionSession?
    @ObservationIgnored private let _encoderDimensions = OSAllocatedUnfairLock(initialState: (width: Int32(0), height: Int32(0)))
    /// Thread-safe copy of profile settings for the encoder.
    @ObservationIgnored private let _profileSettings = OSAllocatedUnfairLock(initialState: (
        bitrate: 1_500_000,
        profileLevel: kVTProfileLevel_H264_Baseline_AutoLevel,
        keyFrameInterval: 30
    ))

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        let position = currentPosition
        let resolution = currentResolution
        let frameRate = currentProfile.frameRate
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self, selector: #selector(orientationChanged),
            name: UIDevice.orientationDidChangeNotification, object: nil
        )
        updateRotationAngle(UIDevice.current.orientation)
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.configureCaptureSession(position: position, resolution: resolution, frameRate: frameRate)
            self.session.startRunning()
            Task { @MainActor [weak self] in
                self?.isRunning = true
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            self.destroyEncoder()
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
        default: return
        }
        _rotationAngle.withLock { $0 = angle }
    }

    func toggleCamera() {
        currentPosition = (currentPosition == .back) ? .front : .back
        let position = currentPosition
        let resolution = currentResolution
        let frameRate = currentProfile.frameRate
        captureQueue.async { [weak self] in
            self?.destroyEncoder()
            self?.reconfigureCamera(position: position, resolution: resolution, frameRate: frameRate)
        }
    }

    func applyProfile(_ profile: StreamProfile) {
        currentProfile = profile
        currentResolution = profile.resolution
        let bitrate = profile.bitrate
        let profileLevel = profile.profileLevel
        let keyFrameInterval = profile.keyFrameInterval
        _profileSettings.withLock {
            $0 = (bitrate: bitrate, profileLevel: profileLevel, keyFrameInterval: keyFrameInterval)
        }
        let position = currentPosition
        let resolution = profile.resolution
        let frameRate = profile.frameRate
        if isRunning {
            captureQueue.async { [weak self] in
                self?.destroyEncoder()
                self?.reconfigureCamera(position: position, resolution: resolution, frameRate: frameRate)
            }
        }
    }

    // MARK: - Session Configuration

    private func configureCaptureSession(position: AVCaptureDevice.Position, resolution: AVCaptureSession.Preset, frameRate: Int32) {
        session.beginConfiguration()
        session.sessionPreset = resolution

        if let device = cameraDevice(for: position),
           let input = try? AVCaptureDeviceInput(device: device) {
            if session.canAddInput(input) {
                session.addInput(input)
            }
            configureFrameRate(device: device, frameRate: frameRate)
        }

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

    private func reconfigureCamera(position: AVCaptureDevice.Position, resolution: AVCaptureSession.Preset, frameRate: Int32) {
        session.beginConfiguration()
        session.sessionPreset = resolution

        for input in session.inputs {
            session.removeInput(input)
        }

        if let device = cameraDevice(for: position),
           let input = try? AVCaptureDeviceInput(device: device) {
            if session.canAddInput(input) {
                session.addInput(input)
            }
            configureFrameRate(device: device, frameRate: frameRate)
        }

        session.commitConfiguration()
    }

    private func cameraDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        ).devices.first
    }

    private func configureFrameRate(device: AVCaptureDevice, frameRate: Int32) {
        do {
            try device.lockForConfiguration()
            let frameDuration = CMTime(value: 1, timescale: frameRate)
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
        } catch {
            print("[CameraManager] Failed to configure device: \(error)")
        }
    }

    // MARK: - H.264 Encoder

    nonisolated private func createEncoder(width: Int32, height: Int32) {
        destroyEncoder()

        let settings = _profileSettings.withLock { $0 }

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            print("[CameraManager] Failed to create encoder: \(status)")
            return
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: settings.profileLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: settings.bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: settings.keyFrameInterval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        // Limit data rate
        let byteLimit = (settings.bitrate / 8) as CFNumber
        let oneSecond = 1.0 as CFNumber
        let dataRateLimits = [byteLimit, oneSecond] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits)

        VTCompressionSessionPrepareToEncodeFrames(session)
        compressionSession = session
        _encoderDimensions.withLock {
            $0 = (width, height)
        }
    }

    nonisolated private func destroyEncoder() {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
        _encoderDimensions.withLock { $0 = (0, 0) }
    }

    /// Convert AVCC format (length-prefixed NALUs) to Annex-B (start code prefixed).
    /// Prepends SPS and PPS before keyframes.
    nonisolated private func extractH264AnnexB(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let dataPointer else { return nil }

        var result = Data()

        let startCode = Data([0x00, 0x00, 0x00, 0x01])

        // If keyframe, prepend SPS and PPS
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        let isKeyframe: Bool
        if let attachments, CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            let notSync = CFDictionaryGetValue(dict, unsafeBitCast(kCMSampleAttachmentKey_NotSync, to: UnsafeRawPointer.self))
            isKeyframe = (notSync == nil)
        } else {
            isKeyframe = true
        }

        if isKeyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            // SPS
            var spsSize = 0
            var spsCount = 0
            var spsPointer: UnsafePointer<UInt8>?
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil) == noErr, let spsPointer {
                result.append(startCode)
                result.append(UnsafeBufferPointer(start: spsPointer, count: spsSize))
            }

            // PPS
            var ppsSize = 0
            var ppsPointer: UnsafePointer<UInt8>?
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ppsPointer {
                result.append(startCode)
                result.append(UnsafeBufferPointer(start: ppsPointer, count: ppsSize))
            }
        }

        // Convert AVCC NALUs to Annex-B
        var offset = 0
        let lengthHeaderSize = 4
        while offset < totalLength - lengthHeaderSize {
            var naluLength: UInt32 = 0
            memcpy(&naluLength, dataPointer + offset, lengthHeaderSize)
            naluLength = naluLength.bigEndian
            offset += lengthHeaderSize

            guard naluLength > 0, offset + Int(naluLength) <= totalLength else { break }

            result.append(startCode)
            result.append(Data(bytes: dataPointer + offset, count: Int(naluLength)))
            offset += Int(naluLength)
        }

        return result.isEmpty ? nil : result
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

        // Apply rotation
        let rotationAngle = _rotationAngle.withLock { $0 }
        if connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }

        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))

        // Recreate encoder if dimensions changed (rotation, resolution change)
        let currentDims = _encoderDimensions.withLock { $0 }
        if compressionSession == nil || currentDims.width != width || currentDims.height != height {
            createEncoder(width: width, height: height)
        }

        guard let session = compressionSession else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        var flags = VTEncodeInfoFlags()
        let encodeStatus = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: &flags
        ) { [weak self] status, _, encodedBuffer in
            guard status == noErr, let encodedBuffer, let self else { return }
            if let h264Data = self.extractH264AnnexB(from: encodedBuffer) {
                self.onH264Data?(h264Data)
            }
        }

        if encodeStatus != noErr {
            print("[CameraManager] Encode failed: \(encodeStatus)")
        }
    }
}
