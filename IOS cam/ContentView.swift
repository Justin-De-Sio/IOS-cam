//
//  ContentView.swift
//  IOS cam
//
//  Created by Justin De Sio on 11/03/2026.
//

import SwiftUI

struct ContentView: View {
    @State private var camera = CameraManager()
    @State private var server = MJPEGServer()
    @State private var is4K = false

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

                    // JPEG quality slider
                    HStack {
                        Text("Quality")
                            .font(.caption)
                            .foregroundStyle(.white)
                        Slider(value: $camera.jpegQuality, in: 0.1...1.0, step: 0.1)
                        Text("\(Int(camera.jpegQuality * 100))%")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .frame(width: 40, alignment: .trailing)
                    }

                    // Controls row
                    HStack(spacing: 20) {
                        // Resolution toggle
                        Button {
                            is4K.toggle()
                            camera.setResolution(is4K ? .hd4K3840x2160 : .hd1920x1080)
                        } label: {
                            Text(is4K ? "4K" : "1080p")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }

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
                            } else {
                                camera.start()
                                server.start()
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
        .onChange(of: camera.latestFrame) { _, newFrame in
            if server.isRunning, let data = newFrame {
                server.broadcast(jpegData: data)
            }
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
    }
}

#Preview {
    ContentView()
}
