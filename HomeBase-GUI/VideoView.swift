//
//  VideoView.swift
//  HomeBase-GUI
//

import HomeBaseProtocol
import SwiftUI

struct VideoView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let cameras: [CameraVideoDevice]
    let client: HomeBaseWebSocketClient
    @State private var selectedCamera: CameraVideoDevice?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(cameras) { camera in
                    cameraButton(camera)
                }
            }
            .padding(gridSpacing)
        }
#if os(iOS)
        .fullScreenCover(
            item: $selectedCamera,
            onDismiss: CameraLandscapeOrientation.restore
        ) { camera in
            fullScreenVideo(for: camera)
        }
#else
        .sheet(item: $selectedCamera) { camera in
            fullScreenVideo(for: camera)
        }
#endif
    }

    private var gridSpacing: CGFloat { 12 }

    private var columns: [GridItem] {
#if os(iOS)
        if horizontalSizeClass == .compact {
            return [
                GridItem(.flexible(), spacing: gridSpacing),
                GridItem(.flexible(), spacing: gridSpacing),
            ]
        }
#endif
        return [
            GridItem(
                .adaptive(minimum: 260, maximum: 420),
                spacing: gridSpacing
            ),
        ]
    }

    private func cameraButton(_ camera: CameraVideoDevice) -> some View {
        Button {
#if os(iOS)
            CameraLandscapeOrientation.prepareForPresentation()
#endif
            selectedCamera = camera
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                CameraLiveVideoPlayer(
                    deviceIdentifier: camera.device.addressableName,
                    quality: camera.capability.previewQuality,
                    client: client,
                    allowsRetry: false
                )
                .frame(maxWidth: .infinity)
                .background(Color.black)

                Text(camera.device.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.secondary.opacity(0.25), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(camera.device.displayName)
        .accessibilityHint("Opens camera controls and full-screen video")
    }

    private func fullScreenVideo(
        for camera: CameraVideoDevice
    ) -> some View {
        CameraFullScreenLiveVideoView(
            device: camera.device,
            quality: camera.capability.fullScreenQuality,
            client: client
        )
    }
}
