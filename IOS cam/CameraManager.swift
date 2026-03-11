import AVFoundation
import VideoToolbox
import UIKit
import os

// MARK: - Stream Profile

nonisolated enum StreamProfile: String, CaseIterable, Sendable {
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
        case .lowLatency:  return 1_500_000
        case .highQuality: return 5_000_000
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
        case .lowLatency:  return 30
        case .highQuality: return 90
        }
    }

    var subtitle: String {
        switch self {
        case .lowLatency:  return "720p \u{2022} 1.5Mbps"
        case .highQuality: return "1080p \u{2022} 5Mbps"
        }
    }
}

// MARK: - Camera Manager

@Observable
final class CameraManager: NSObject {

    var isRunning = false
    var currentPosition: AVCaptureDevice.Position = .back
    var currentProfile: StreamProfile = .lowLatency

    var previewSession: AVCaptureSession { session }

    /// Callback: delivers H.264 Annex-B data chunks on captureQueue.
    @ObservationIgnored nonisolated(unsafe) var onH264Data: ((Data) -> Void)?

    /// Latest SPS/PPS to send to newly connected clients.
    @ObservationIgnored nonisolated(unsafe) var latestParamSets: Data?

    // MARK: - Private

    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.linuxcam.capture", qos: .userInteractive)
    @ObservationIgnored nonisolated(unsafe) private var encoder: VTCompressionSession?
    @ObservationIgnored nonisolated(unsafe) private var encoderSize = (w: Int32(0), h: Int32(0))
    @ObservationIgnored nonisolated(unsafe) private var forceNextKeyframe = false

    /// Profile settings snapshot safe to read from captureQueue.
    @ObservationIgnored nonisolated(unsafe) private var activeProfile = StreamProfile.lowLatency

    /// Rotation angle safe to read from captureQueue.
    @ObservationIgnored nonisolated(unsafe) private var rotationAngle: CGFloat = 90

    // MARK: - Public

    func start() {
        guard !isRunning else { return }
        activeProfile = currentProfile
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(orientationChanged),
                                               name: UIDevice.orientationDidChangeNotification, object: nil)
        updateRotation(UIDevice.current.orientation)

        let pos = currentPosition
        let preset = currentProfile.resolution
        captureQueue.async { [self] in
            configureSession(position: pos, preset: preset)
            session.startRunning()
            Task { @MainActor [self] in self.isRunning = true }
        }
    }

    func stop() {
        guard isRunning else { return }
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        captureQueue.async { [self] in
            session.stopRunning()
            destroyEncoder()
            Task { @MainActor [self] in self.isRunning = false }
        }
    }

    func toggleCamera() {
        currentPosition = (currentPosition == .back) ? .front : .back
        let pos = currentPosition
        let preset = currentProfile.resolution
        captureQueue.async { [self] in
            destroyEncoder()
            reconfigure(position: pos, preset: preset)
        }
    }

    func applyProfile(_ profile: StreamProfile) {
        currentProfile = profile
        activeProfile = profile
        guard isRunning else { return }
        let pos = currentPosition
        let preset = profile.resolution
        captureQueue.async { [self] in
            destroyEncoder()
            reconfigure(position: pos, preset: preset)
        }
    }

    func requestKeyframe() {
        forceNextKeyframe = true
    }

    // MARK: - Orientation

    @objc private func orientationChanged() {
        updateRotation(UIDevice.current.orientation)
    }

    private func updateRotation(_ o: UIDeviceOrientation) {
        switch o {
        case .portrait:          rotationAngle = 90
        case .portraitUpsideDown: rotationAngle = 270
        case .landscapeLeft:     rotationAngle = 0
        case .landscapeRight:    rotationAngle = 180
        default: break
        }
    }

    // MARK: - AVCaptureSession

    private func configureSession(position: AVCaptureDevice.Position, preset: AVCaptureSession.Preset) {
        session.beginConfiguration()
        session.sessionPreset = preset

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            try? device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        if session.canAddOutput(output) { session.addOutput(output) }

        session.commitConfiguration()
    }

    private func reconfigure(position: AVCaptureDevice.Position, preset: AVCaptureSession.Preset) {
        session.beginConfiguration()
        session.sessionPreset = preset
        session.inputs.forEach { session.removeInput($0) }

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            try? device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        }

        session.commitConfiguration()
    }

    // MARK: - H.264 Encoder

    nonisolated private func createEncoder(w: Int32, h: Int32) {
        destroyEncoder()
        let p = activeProfile

        var s: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: w, height: h,
                                         codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: nil, imageBufferAttributes: nil,
                                         compressedDataAllocator: nil, outputCallback: nil,
                                         refcon: nil, compressionSessionOut: &s) == noErr,
              let s else { return }

        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: p.profileLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: p.bitrate as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: p.keyFrameInterval as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        let limit = [(p.bitrate / 8) as CFNumber, 1.0 as CFNumber] as CFArray
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limit)

        VTCompressionSessionPrepareToEncodeFrames(s)
        encoder = s
        encoderSize = (w, h)
    }

    nonisolated private func destroyEncoder() {
        if let e = encoder { VTCompressionSessionInvalidate(e) }
        encoder = nil
        encoderSize = (0, 0)
    }

    // MARK: - H.264 Annex-B Conversion

    nonisolated private func annexB(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var len = 0
        var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &len, dataPointerOut: &ptr) == noErr,
              let ptr else { return nil }

        let sc = Data([0x00, 0x00, 0x00, 0x01])
        var out = Data()

        // Keyframe? → prepend SPS/PPS
        let isKey: Bool
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = arr.first {
            isKey = !(first[kCMSampleAttachmentKey_DependsOnOthers] as? Bool ?? false)
        } else {
            isKey = true
        }

        if isKey, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)

            var paramSets = Data()
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?
                var s = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i,
                    parameterSetPointerOut: &p, parameterSetSizeOut: &s,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                      let p else { continue }
                paramSets.append(sc)
                paramSets.append(p, count: s)
            }
            if !paramSets.isEmpty {
                latestParamSets = paramSets
                out.append(paramSets)
            }
        }

        // AVCC → Annex-B
        var off = 0
        while off + 4 <= len {
            var naluLen: UInt32 = 0
            memcpy(&naluLen, ptr + off, 4)
            naluLen = naluLen.bigEndian
            off += 4
            guard naluLen > 0, off + Int(naluLen) <= len else { break }
            out.append(sc)
            out.append(Data(bytes: ptr + off, count: Int(naluLen)))
            off += Int(naluLen)
        }

        return out.isEmpty ? nil : out
    }
}

// MARK: - Capture Delegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from conn: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sb) else { return }

        let angle = rotationAngle
        if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }

        let w = Int32(CVPixelBufferGetWidth(px)), h = Int32(CVPixelBufferGetHeight(px))
        if encoder == nil || encoderSize.w != w || encoderSize.h != h { createEncoder(w: w, h: h) }
        guard let enc = encoder else { return }

        var props: CFDictionary?
        if forceNextKeyframe {
            forceNextKeyframe = false
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        var flags = VTEncodeInfoFlags()
        VTCompressionSessionEncodeFrame(enc, imageBuffer: px,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb),
            duration: .invalid, frameProperties: props, infoFlagsOut: &flags
        ) { [self] status, _, buf in
            guard status == noErr, let buf, let data = annexB(from: buf) else { return }
            onH264Data?(data)
        }
    }
}
