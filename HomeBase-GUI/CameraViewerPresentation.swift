import Combine
import HomeBaseProtocol
import SwiftUI

#if os(iOS)
/// The phone presentation has a different lifetime from its camera viewer.
/// Minimizing changes visibility, never the identity of the mounted view.
@MainActor
final class CameraViewerPresentation: ObservableObject {
    struct Request: Identifiable {
        let id: UUID
        let device: HBTopologyDeviceDescriptor
        let quality: CameraLiveQualitySelection
        let client: HomeBaseWebSocketClient
    }

    @Published private(set) var request: Request?
    @Published private(set) var isMinimized = false
    @Published private(set) var externalCameraCount = 0
    var isPresented: Bool { request != nil && !isMinimized }
    var camerasBadgeCount: Int { isMinimized ? externalCameraCount : 0 }

    nonisolated deinit {}

    func open(device: HBTopologyDeviceDescriptor, quality: CameraLiveQualitySelection,
              client: HomeBaseWebSocketClient, viewerID: UUID = UUID()) {
        request = Request(id: viewerID, device: device, quality: quality, client: client)
        externalCameraCount = 0
        isMinimized = false
    }

    func updateExternalOutput(viewerID: UUID, cameraCount: Int) {
        guard request?.id == viewerID else { return }
        let count = max(0, cameraCount)
        if externalCameraCount != count { externalCameraCount = count }
    }

    @discardableResult
    func minimize(viewerID: UUID, externalOutputActive: Bool) -> Bool {
        guard request?.id == viewerID, externalOutputActive, !isMinimized else { return false }
        isMinimized = true
        return true
    }

    func restore() {
        guard request != nil else { return }
        isMinimized = false
    }

    func close() {
        request = nil
        isMinimized = false
        externalCameraCount = 0
    }
}

private struct CameraViewerPresentationKey: EnvironmentKey {
    static let defaultValue: CameraViewerPresentation? = nil
}
private struct CameraViewerPresentedKey: EnvironmentKey {
    static let defaultValue = false
}
private struct CameraViewerMinimizedKey: EnvironmentKey {
    static let defaultValue = false
}
private struct CameraExternalStreamingCountKey: EnvironmentKey {
    static let defaultValue = 0
}
extension EnvironmentValues {
    var cameraViewerPresentation: CameraViewerPresentation? {
        get { self[CameraViewerPresentationKey.self] }
        set { self[CameraViewerPresentationKey.self] = newValue }
    }
    var cameraViewerIsPresented: Bool {
        get { self[CameraViewerPresentedKey.self] }
        set { self[CameraViewerPresentedKey.self] = newValue }
    }
    var cameraViewerIsMinimized: Bool {
        get { self[CameraViewerMinimizedKey.self] }
        set { self[CameraViewerMinimizedKey.self] = newValue }
    }
    var cameraExternalStreamingCount: Int {
        get { self[CameraExternalStreamingCountKey.self] }
        set { self[CameraExternalStreamingCountKey.self] = newValue }
    }
}

/// A persistent full-screen layer, not a dismissed/recreated cover. In
/// particular, the external-scene accessory stays attached to the phone scene.
struct CameraViewerHost: ViewModifier {
    @ObservedObject var presentation: CameraViewerPresentation

    func body(content: Content) -> some View {
        CameraRetainedViewerLayer(presentation: presentation) {
            content
        } viewer: { request in
            CameraFullScreenLiveVideoView(device: request.device,
                quality: request.quality, client: request.client, viewerID: request.id)
                .cameraAccessScope(isActive: !presentation.isMinimized)
        }
        .environment(\.cameraViewerPresentation, presentation)
        .environment(\.cameraViewerIsPresented, presentation.isPresented)
        .environment(\.cameraViewerIsMinimized, presentation.isMinimized)
        .environment(\.cameraExternalStreamingCount, presentation.camerasBadgeCount)
    }
}

struct CameraRetainedViewerLayer<Content: View, Viewer: View>: View {
    @ObservedObject var presentation: CameraViewerPresentation
    @ViewBuilder let content: () -> Content
    @ViewBuilder let viewer: (CameraViewerPresentation.Request) -> Viewer

    var body: some View {
        ZStack {
            content()
                .allowsHitTesting(!presentation.isPresented)
                .accessibilityHidden(presentation.isPresented)
            if let request = presentation.request {
                viewer(request)
                    .id(request.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.ignoresSafeArea())
                    .opacity(presentation.isMinimized ? 0 : 1)
                    .allowsHitTesting(!presentation.isMinimized)
                    .accessibilityHidden(presentation.isMinimized)
                    .accessibilityAddTraits(.isModal)
                    .zIndex(1)
            }
        }
    }
}
#endif
