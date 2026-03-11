//
//  ContentView.swift
//  IOS cam
//
//  Created by Justin De Sio on 11/03/2026.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @State private var camera = CameraManager()
    @State private var server = StreamServer()

    var body: some View {
        ZStack {
            CameraPreview(session: camera.previewSession)
                .ignoresSafeArea()

            VStack {
                Spacer()

                VStack(spacing: 12) {
                    // Server address
                    if server.isRunning {
                        Text(server.serverAddress)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.white)
                    }

                    // Client count
                    HStack(spacing: 6) {
                        Circle()
                            .fill(server.connectedClients > 0 ? .green : .gray)
                            .frame(width: 8, height: 8)
                        Text("\(server.connectedClients) client(s)")
                            .font(.caption)
                            .foregroundStyle(.white)
                    }

                    // Profile picker
                    HStack(spacing: 8) {
                        ForEach(StreamProfile.allCases, id: \.self) { profile in
                            Button {
                                camera.applyProfile(profile)
                            } label: {
                                VStack(spacing: 2) {
                                    Text(profile.displayName)
                                        .font(.caption.bold())
                                    Text(profile.description)
                                        .font(.system(size: 9))
                                }
                                .foregroundStyle(camera.currentProfile == profile ? .black : .white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                                .background(
                                    camera.currentProfile == profile
                                        ? AnyShapeStyle(.white)
                                        : AnyShapeStyle(.ultraThinMaterial),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                            }
                        }
                    }

                    // Controls row
                    HStack(spacing: 20) {
                        // Camera flip
                        Button {
                            camera.toggleCamera()
                        } label: {
                            Image(systemName: "camera.rotate")
                                .font(.title3)
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }

                        // Start / Stop
                        Button {
                            if server.isRunning {
                                server.stop()
                                camera.stop()
                                camera.onH264Data = nil
                                UIApplication.shared.isIdleTimerDisabled = false
                            } else {
                                camera.onH264Data = { [server] h264Data in
                                    server.broadcast(data: h264Data)
                                }
                                camera.start()
                                server.start()
                                UIApplication.shared.isIdleTimerDisabled = true
                            }
                        } label: {
                            Image(systemName: server.isRunning ? "stop.circle.fill" : "play.circle.fill")
                                .font(.system(size: 50))
                                .foregroundStyle(server.isRunning ? .red : .green)
                        }
                    }
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding()
            }
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
    }
}

#Preview {
    ContentView()
}
