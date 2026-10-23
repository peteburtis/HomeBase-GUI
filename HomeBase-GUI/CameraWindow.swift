import HomeBaseProtocol
import SwiftUI

/// Persistent scene state for a camera window. Equality intentionally follows
/// the server/camera pair rather than its presentation snapshot so opening a card
/// again focuses its existing window after a topology refresh or rename.
struct CameraWindowRequest: Codable, Hashable {
    let serverID: UUID
    let endpoint: HomeBaseEndpoint
    let cameraID: String
    let cameraName: String

    init(server: PairedServer, camera: CameraVideoDevice) {
        serverID = server.id
        endpoint = server.endpoint
        cameraID = camera.id
        cameraName = camera.device.displayName
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.serverID == rhs.serverID && lhs.cameraID == rhs.cameraID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(serverID)
        hasher.combine(cameraID)
    }
}

#if os(macOS)
struct CameraWindowRoot: View {
    @Environment(\.scenePhase) private var scenePhase
    let request: CameraWindowRequest
    @StateObject private var connection: ServerConnectionModel

    init(request: CameraWindowRequest) {
        self.request = request
        _connection = StateObject(
            wrappedValue: ServerConnectionModel(endpoint: request.endpoint)
        )
    }

    var body: some View {
        content
            .frame(minWidth: 640, minHeight: 420)
            .background(Color.black)
            .cameraAccessScope(isActive: true)
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await connection.reactivate()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch connection.state {
        case .connected:
            if let camera {
                CameraFullScreenLiveVideoView(
                    device: camera.device,
                    quality: camera.capability.fullScreenQuality,
                    client: connection.client
                )
            } else {
                unavailableCamera
            }

        case .failed(let message):
            ContentUnavailableView {
                Label("Camera Unavailable", systemImage: "video.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    Task { await connection.reactivate() }
                }
            }

        case .disconnected, .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(request.cameraName)…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var camera: CameraVideoDevice? {
        CameraVideoCatalog.cameras(in: connection.topology.devices)
            .first { $0.id == request.cameraID }
    }

    private var unavailableCamera: some View {
        ContentUnavailableView {
            Label("Camera Unavailable", systemImage: "video.slash")
        } description: {
            Text("\(request.cameraName) is no longer advertised by this HomeBase server.")
        } actions: {
            Button("Refresh") {
                Task { await connection.refresh() }
            }
        }
    }
}
#endif
