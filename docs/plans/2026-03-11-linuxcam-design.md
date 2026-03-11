# LinuxCam Design

**Goal:** Stream iPhone camera as MJPEG over HTTP for consumption by ffmpeg on Linux as a virtual webcam.

**Architecture:** 3 Swift files — CameraManager (AVCaptureSession + JPEG encoding), MJPEGServer (NWListener HTTP server), ContentView (fullscreen preview + overlay controls). Camera frames are encoded to JPEG on a dedicated queue, then broadcast to all connected HTTP clients via MJPEG multipart streaming.

**Tech Stack:** Swift, SwiftUI, AVFoundation, Network framework (NWListener)

## Specs

- Resolution: 1080p / 4K toggle
- Framerate: 30 fps
- JPEG quality: slider 0.1–1.0, default 0.6
- Server port: 8080
- Routes: `/` (HTML test page), `/video` (MJPEG stream)
- UI: fullscreen camera preview + semi-transparent overlay at bottom
- Info.plist: NSCameraUsageDescription, NSLocalNetworkUsageDescription

## Key Technical Notes

- Project uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — camera delegate and server code need `nonisolated` or `@preconcurrency`
- `PBXFileSystemSynchronizedRootGroup` — new .swift files auto-detected by Xcode
- `GENERATE_INFOPLIST_FILE = YES` — privacy keys added via build settings, not a separate plist file
