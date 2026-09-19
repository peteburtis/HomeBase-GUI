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
    var onPresentationChanged: (Bool) -> Void = { _ in }
    @State private var selectedCamera: CameraVideoDevice?

    var body: some View {
        CameraAccessGate { access in
            ScrollView {
                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    ForEach(cameras) { camera in
                        cameraButton(camera, access: access)
                    }
                }
                .padding(gridSpacing)

                if access.showsUnlockRecovery {
                    CameraUnlockButton(access: access)
                        .padding()
                }
            }
        }
#if os(iOS)
        .fullScreenCover(item: $selectedCamera) { camera in
            fullScreenVideo(for: camera)
        }
#else
        .sheet(item: $selectedCamera) { camera in
            fullScreenVideo(for: camera)
        }
#endif
        .onChange(of: selectedCamera?.id) { _, identifier in
            onPresentationChanged(identifier != nil)
        }
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

    private func cameraButton(
        _ camera: CameraVideoDevice,
        access: CameraAccessPresentation
    ) -> some View {
        Button {
            guard access.isUnlocked, access.session?.isUnlocked != false else { return }
            // Retain the camera-section lease before presentation can obscure
            // its parent; don't depend on onChange/onDisappear callback order.
            onPresentationChanged(true)
            selectedCamera = camera
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                CameraProtectedPreview(access: access) {
                    CameraLiveVideoPlayer(
                        deviceIdentifier: camera.device.addressableName,
                        quality: camera.capability.previewQuality,
                        client: client,
                        allowsRetry: false,
                        isStreamEnabled: selectedCamera == nil
                    )
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                }

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
        // Disabled plain buttons dim even an opaque black preview to gray in
        // light mode. Keep it black and inert without fading the entire chip.
        // The action also guards authorization for accessibility activation.
        .allowsHitTesting(access.isUnlocked)
        .accessibilityRemoveTraits(access.isUnlocked ? [] : .isButton)
        .accessibilityAddTraits(access.isUnlocked ? .isButton : .isStaticText)
        .accessibilityLabel(camera.device.displayName)
        .accessibilityHint(access.isUnlocked
            ? "Opens camera controls and full-screen video"
            : (access.showsUnlockRecovery ? "Locked. Use Unlock to authenticate." : "Camera preview hidden during authentication."))
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
