//
//  VideoView.swift
//  HomeBase-GUI
//

import HomeBaseProtocol
import SwiftUI

struct VideoView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
#if os(iOS)
    @Environment(\.cameraViewerPresentation) private var viewer
    @Environment(\.cameraViewerIsPresented) private var viewerIsPresented
#elseif os(macOS)
    @Environment(\.openWindow) private var openWindow
#endif

    let cameras: [CameraVideoDevice]
    let client: HomeBaseWebSocketClient
    let server: PairedServer?
    var onPresentationChanged: (Bool) -> Void = { _ in }
    @StateObject private var previews: CameraGridPreviewModel
    @State private var selectedCamera: CameraVideoDevice?

    init(
        cameras: [CameraVideoDevice],
        client: HomeBaseWebSocketClient,
        server: PairedServer? = nil,
        onPresentationChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.cameras = cameras
        self.client = client
        self.server = server
        self.onPresentationChanged = onPresentationChanged
        _previews = StateObject(wrappedValue: CameraGridPreviewModel(client: client))
    }

    var body: some View {
        CameraAccessGate { access in
            let previewsActive = access.canStream
                && scenePhase == .active
                && selectedCamera == nil
                && !hasRetainedViewer
            ScrollView {
                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    ForEach(cameras) { camera in
                        cameraButton(
                            camera,
                            access: access,
                            previewsActive: previewsActive
                        )
                    }
                }
                .padding(gridSpacing)

                if access.showsUnlockRecovery {
                    CameraUnlockButton(access: access)
                        .padding()
                }
            }
            .task(id: previewTaskIdentity(isActive: previewsActive)) {
                guard previewsActive else { return }
                await previews.run(cameras: cameras)
            }
        }
#if os(iOS)
        .fullScreenCover(item: $selectedCamera) { camera in
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
        access: CameraAccessPresentation,
        previewsActive: Bool
    ) -> some View {
        Button {
            guard access.isUnlocked, access.session?.isUnlocked != false else { return }
#if os(macOS)
            guard let server else { return }
            openWindow(value: CameraWindowRequest(server: server, camera: camera))
#else
            // Retain the camera-section lease before presentation can obscure
            // its parent; don't depend on onChange/onDisappear callback order.
            onPresentationChanged(true)
            if let viewer {
                viewer.open(device: camera.device, quality: camera.capability.fullScreenQuality, client: client)
                return
            }
            selectedCamera = camera
#endif
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                CameraProtectedPreview(access: access) {
                    CameraGridPreview(
                        camera: camera,
                        preview: previews.preview(for: camera.id),
                        client: client,
                        isActive: previewsActive
                    )
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
            ? cameraAccessibilityHint
            : (access.showsUnlockRecovery ? "Locked. Use Unlock to authenticate." : "Camera preview hidden during authentication."))
    }

    private func previewTaskIdentity(
        isActive: Bool
    ) -> CameraGridPreviewTaskIdentity {
        CameraGridPreviewTaskIdentity(
            cameras: cameras.map { camera in
                let playbackCameraID = CameraPlaybackHistoryAvailability
                    .metadata(in: camera.device.metadata)?.cameraID ?? ""
                return "\(camera.id):\(playbackCameraID)"
            },
            isActive: isActive
        )
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

    private var hasRetainedViewer: Bool {
#if os(iOS)
        viewerIsPresented || viewer?.request != nil
#else
        false
#endif
    }

    private var cameraAccessibilityHint: String {
#if os(macOS)
        "Opens camera controls and video in a dedicated window"
#else
        "Opens camera controls and full-screen video"
#endif
    }
}

private struct CameraGridPreviewTaskIdentity: Hashable {
    let cameras: [String]
    let isActive: Bool
}
