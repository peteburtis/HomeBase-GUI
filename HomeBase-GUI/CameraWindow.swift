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
        CameraWindowContent(camera: camera, state: connection.state, cameraName: request.cameraName,
                            retry: { Task { await connection.reactivate() } }) { camera in
            CameraFullScreenLiveVideoView(
                device: camera.device,
                quality: camera.capability.fullScreenQuality,
                client: connection.client
            )
        }
            .frame(minWidth: 640, minHeight: 420)
            .background(Color.black)
            .cameraAccessScope(isActive: true)
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await connection.reactivate()
            }
    }

    private var camera: CameraVideoDevice? {
        CameraVideoCatalog.cameras(in: connection.topology.devices)
            .first { $0.id == request.cameraID }
    }
}

struct CameraWindowContent<Player: View>: View {
    let camera: CameraVideoDevice?
    let state: ServerConnectionModel.State
    let cameraName: String
    let retry: () -> Void
    @ViewBuilder let player: (CameraVideoDevice) -> Player

    var body: some View {
        // A control reconnect does not end the camera viewing session. Keep
        // its StateObjects, history cursor, and buffers until discovery removes
        // this camera or the window itself closes.
        if let camera {
            player(camera)
                .overlay(alignment: .bottom) {
                    if let connectionStatus {
                        ConnectionStatusOverlay(presentation: connectionStatus, retry: retry)
                            .padding(12)
                    }
                }
        } else {
            unavailableContent
        }
    }

    private var connectionStatus: ConnectionStatusPresentation? {
        switch state {
        case .connected: nil
        case .connecting: .pending("Reconnecting…")
        case .disconnected: .disconnected("Disconnected", systemImage: "network.slash")
        case .failed(let message): .failed(title: "Connection Failed", message: message)
        }
    }

    @ViewBuilder
    private var unavailableContent: some View {
        switch state {
        case .connected:
            unavailableCamera

        case .failed(let message):
            ContentUnavailableView {
                Label("Camera Unavailable", systemImage: "video.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again", action: retry)
            }

        case .disconnected, .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(cameraName)…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var unavailableCamera: some View {
        ContentUnavailableView {
            Label("Camera Unavailable", systemImage: "video.slash")
        } description: {
            Text("\(cameraName) is no longer advertised by this HomeBase server.")
        } actions: {
            Button("Refresh", action: retry)
        }
    }
}
#endif
