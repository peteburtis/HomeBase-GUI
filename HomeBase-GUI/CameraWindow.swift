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
/// A menu-created window has no scene value until its first camera is chosen.
/// Discovery alone does not acquire camera access; the selected player owns
/// that scope and uses the same authentication/recovery flow as the Cameras tab.
struct CameraWindowScene: View {
    @EnvironmentObject private var serverStore: PairedServerStore
    @Binding var request: CameraWindowRequest?

    var body: some View {
        Group {
            if let request {
                CameraWindowRoot(request: request)
            } else if let server = serverStore.selectedServer {
                CameraWindowSelectionView(server: server) { camera in
                    request = CameraWindowRequest(server: server, camera: camera)
                }
                .id(server.id)
            } else {
                ContentUnavailableView(
                    "Please select a camera",
                    systemImage: "video",
                    description: Text("Select a server in the main window to choose a camera.")
                )
                .modifier(CameraWindowPlaceholderStyle())
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

private struct CameraWindowSelectionView: View {
    @StateObject private var connection: ServerConnectionModel
    @StateObject private var picker: CameraPickerModel
    @State private var showsPicker = false
    let select: (CameraVideoDevice) -> Void

    init(server: PairedServer, select: @escaping (CameraVideoDevice) -> Void) {
        let connection = ServerConnectionModel(server: server)
        _connection = StateObject(wrappedValue: connection)
        _picker = StateObject(wrappedValue: CameraPickerModel { [client = connection.client] in
            try await client.reactivate()
            return try await client.listTopology().devices
        })
        self.select = select
    }

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Please select a camera", systemImage: "video")
            } actions: {
                Button("Choose Camera") { showsPicker = true }
            }
            .modifier(CameraWindowPlaceholderStyle())
            .navigationTitle("Camera")
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Choose camera", systemImage: "video") { showsPicker = true }
                        .popover(isPresented: $showsPicker) {
                            CameraPickerPopover(
                                model: picker, selectedIDs: [], multiple: false,
                                toggleMultiple: nil, canSelect: { _ in true },
                                select: { camera in
                                    showsPicker = false
                                    select(camera)
                                }
                            )
                        }
                }
            }
        }
    }
}

private struct CameraWindowPlaceholderStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white)
            .background(Color.black.ignoresSafeArea())
    }
}

struct CameraWindowRoot: View {
    @Environment(\.scenePhase) private var scenePhase
    let request: CameraWindowRequest
    @StateObject private var connection: ServerConnectionModel

    init(request: CameraWindowRequest) {
        self.request = request
        _connection = StateObject(
            wrappedValue: ServerConnectionModel(endpoint: request.endpoint, serverID: request.serverID)
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
