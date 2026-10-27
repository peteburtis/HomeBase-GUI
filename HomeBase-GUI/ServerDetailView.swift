//
//  ServerDetailView.swift
//  HomeBase-GUI
//

import Combine
import HomeBaseProtocol
import SwiftUI

struct ServerDetailView: View {
    private enum Tab: Hashable { case home, cameras, scenes, triggers }
    @Environment(\.scenePhase) private var scenePhase
#if os(iOS)
    @Environment(\.cameraViewerPresentation) private var cameraViewer
    @Environment(\.cameraViewerIsPresented) private var viewerIsPresented
    @Environment(\.cameraViewerIsMinimized) private var viewerIsMinimized
    @Environment(\.cameraExternalStreamingCount) private var externalStreamingCount
#endif

    let server: PairedServer
    let showServers: () -> Void
    @StateObject private var connection: ServerConnectionModel
    @StateObject private var connectionStatusController = ConnectionStatusController()
    @State private var selectedTab: Tab = .home
    @State private var isShowingCamera = false
    @State private var homeDetailSelection: TopologyDetailDestination?

    private var cameraTabNeedsAccess: Bool {
        selectedTab == .cameras && connection.route == .webSocket
    }

    init(
        server: PairedServer,
        showServers: @escaping () -> Void
    ) {
        self.server = server
        self.showServers = showServers
        _connection = StateObject(
            wrappedValue: ServerConnectionModel(server: server)
        )
    }

    init(
        server: PairedServer,
        connection: ServerConnectionModel,
        showServers: @escaping () -> Void
    ) {
        self.server = server
        self.showServers = showServers
        _connection = StateObject(wrappedValue: connection)
    }

    var body: some View {
        let cameras = CameraVideoCatalog.cameras(
            in: connection.topology.devices
        )

        TabView(selection: $selectedTab) {
            NavigationSplitView {
                NavigationStack {
                    homeView
                        .toolbar {
                            ToolbarItem(placement: .navigation) {
                                Button("Servers", systemImage: "list.bullet") {
                                    showServers()
                                }
                            }
                            ToolbarItem(placement: .primaryAction) {
                                HomeSettingsButton(
                                    destinations: S3CredentialSettingsModel.destinations(in: connection.topology.devices),
                                    serverName: server.endpoint.host,
                                    server: server, client: connection.client,
                                    isConnected: connection.state == .connected && connection.route == .webSocket
                                )
                            }
                        }
                }
            } detail: {
                TopologyDetailDestinationView(
                    selection: homeDetailSelection,
                    topology: connection.presentedTopology,
                    client: connection.client
                )
            }
                .connectionStatusScope(isActive: selectedTab == .home)
                .tabItem {
                    Label("Home", systemImage: "house")
                }
                .tag(Tab.home)

            if !cameras.isEmpty {
                Group {
                    if connection.route == .bluetooth {
                        ContentUnavailableView("Cameras need a network connection", systemImage: "wifi.slash",
                            description: Text("Home controls are connected over Bluetooth. Video and recordings become available when the network connection returns."))
                    } else {
                        VideoView(cameras: cameras, client: connection.client, server: server,
                            onPresentationChanged: { isShowingCamera = $0 })
                    }
                }
                .connectionStatusClearance()
                .connectionStatusScope(isActive: selectedTab == .cameras)
                .tabItem {
                    Label("Cameras", systemImage: "video")
                }
                .tag(Tab.cameras)
#if os(iOS)
                .badge(externalStreamingCount)
#endif
            }

            NavigationStack {
                ScenesView(
                    client: connection.client
                )
            }
                .connectionStatusScope(isActive: selectedTab == .scenes)
                .tabItem {
                    Label("Scenes", systemImage: "sparkles")
                }
                .tag(Tab.scenes)

            NavigationStack {
                TriggersView(
                    client: connection.client
                )
            }
                .connectionStatusScope(isActive: selectedTab == .triggers)
                .tabItem {
                    Label("Triggers", systemImage: "bolt")
                }
                .tag(Tab.triggers)
        }
        .cameraAccessScope(
            // Bluetooth and pending routes cannot show video. Request access
            // when the network returns if Cameras is still selected.
            isActive: cameraTabNeedsAccess,
            isPresentingCamera: isShowingCamera
        )
        .onChange(of: cameras.isEmpty) { _, isEmpty in
            if isEmpty && selectedTab == .cameras {
                selectedTab = .home
            }
        }
#if os(iOS)
        .onChange(of: viewerIsPresented) { _, presented in
            isShowingCamera = presented
        }
        .onChange(of: viewerIsMinimized) { _, minimized in
            if minimized && selectedTab == .cameras { selectedTab = .home }
        }
        .onChange(of: cameraTabNeedsAccess) { _, needsAccess in
            if needsAccess { cameraViewer?.restore() }
        }
#endif
        .connectionStatusHost(connectionStatusController)
        .onChange(of: connection.route, initial: true) { _, _ in
            updateConnectionStatus()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Publish recovery feedback before asynchronous route checks and
            // individual screens restart their subscriptions.
            connectionStatusController.setActive(phase == .active)
        }
        .task(id: scenePhase) {
            await connection.client.setForeground(scenePhase == .active)
            guard scenePhase == .active else { return }
            await connection.reactivate()
        }
        .onChange(of: connection.state, initial: true) { _, state in
            updateConnectionStatus()
            if state == .connected {
                Task { await BluetoothPresenceService.shared.connected(serverID: server.id, client: connection.client) }
            }
        }
        .onReceive(BluetoothPresenceService.shared.$registrations) { registrations in
            if connection.route == .webSocket,
               registrations.contains(where: { $0.serverID == server.id && $0.phase == .paired && $0.cncCredential == nil }) {
                Task { await connection.client.upgradeBluetoothIfPossible() }
            }
            if connection.state == .connected,
               registrations.contains(where: { $0.serverID == server.id && $0.phase == .removing }) {
                Task { await BluetoothPresenceService.shared.connected(serverID: server.id, client: connection.client) }
            }
        }
    }

    private var homeView: some View {
        let topology = connection.presentedTopology
        let placement = TopologyGroupPlacement(topology: topology)
        let topLevelGroups = placement.topLevelGroups.filter {
            !$0.metadata.hasHiddenFlag
        }
        let hiddenTopLevelGroups = placement.topLevelGroups.filter {
            $0.metadata.hasHiddenFlag
        }
        let topLevelDeviceItems = placement.topLevelDeviceItems.filter {
            !$0.isHidden
        }
        let hiddenTopLevelDeviceItems = placement.topLevelDeviceItems.filter(
            \.isHidden
        )
        let visibleRooms = topology.rooms.filter {
            !$0.metadata.hasHiddenFlag
        }
        let hiddenRooms = topology.rooms.filter {
            $0.metadata.hasHiddenFlag
        }

        return List(selection: $homeDetailSelection) {
            Section {
                if visibleRooms.isEmpty {
                    Text(emptyRoomsMessage)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleRooms, id: \.identifier) { room in
                        NavigationLink {
                            RoomDetailView(
                                room: room,
                                topology: topology,
                                client: connection.client,
                                selection: $homeDetailSelection
                            )
                        } label: {
                            TopologyRowLabel(
                                title: room.displayName,
                                technicalName: roomTechnicalName(room),
                                detail: TopologyRowLabel.deviceCountDescription(
                                    placement.deviceItems(in: room).filter {
                                        !$0.isHidden
                                    }.count
                                )
                            )
                        }
#if os(iOS) || os(visionOS)
                        .isDetailLink(false)
#endif
                    }
                }
            } header: {
                Text("Rooms")
            }

            if !topLevelDeviceItems.isEmpty {
                Section("Devices") {
                    TopologyDeviceRows(
                        emptyMessage: "No devices are available.",
                        items: topLevelDeviceItems,
                        topology: topology,
                        client: connection.client,
                        selection: $homeDetailSelection
                    )
                }
            }

            if !topLevelGroups.isEmpty {
                Section {
                    ForEach(topLevelGroups, id: \.identifier) { group in
                        NavigationLink {
                            GroupDetailView(
                                group: group,
                                topology: topology,
                                client: connection.client,
                                selection: $homeDetailSelection
                            )
                        } label: {
                            TopologyGroupRow(group: group)
                        }
#if os(iOS) || os(visionOS)
                        .isDetailLink(false)
#endif
                    }
                } header: {
                    Text("Groups")
                }
            }

            if !hiddenRooms.isEmpty
                || !hiddenTopLevelDeviceItems.isEmpty
                || !hiddenTopLevelGroups.isEmpty {
                Section("Hidden") {
                    NavigationLink {
                        HiddenTopologyItemsView(
                            rooms: hiddenRooms,
                            deviceItems: hiddenTopLevelDeviceItems,
                            groups: hiddenTopLevelGroups,
                            topology: topology,
                            client: connection.client,
                            selection: $homeDetailSelection
                        )
                    } label: {
                        HiddenItemsRowLabel(
                            title: "Hidden Items",
                            count: hiddenRooms.count
                                + hiddenTopLevelDeviceItems.count
                                + hiddenTopLevelGroups.count
                        )
                    }
#if os(iOS) || os(visionOS)
                    .isDetailLink(false)
#endif
                }
            }
        }
        .navigationTitle("Home")
        .refreshable {
            await connection.refresh()
        }
        .connectionStatusClearance()
    }

    private func updateConnectionStatus() {
        // Retain only the model, not the view that owns the status controller.
        let model = connection
        connectionStatusController.updateConnection(presentation: connectionStatus,
            route: connection.route, retry: { Task { await model.load() } })
    }

    private var connectionStatus: ConnectionStatusPresentation {
        switch connection.state {
        case .disconnected:
            .disconnected("Disconnected", systemImage: "network.slash")
        case .connecting:
            .pending("Connecting…")
        case .connected:
            .connected
        case .failed(let message):
            .failed(title: "Connection Failed", message: message)
        }
    }

    private var emptyRoomsMessage: String {
        switch connection.state {
        case .connected:
            "No rooms are configured."
        case .failed:
            "Rooms could not be loaded."
        case .disconnected, .connecting:
            "Rooms will appear after connecting."
        }
    }

    private func roomTechnicalName(
        _ room: HBTopologyRoomDescriptor
    ) -> String? {
        connection.topology.containsRoom(identifier: room.identifier)
            ? room.identifier
            : nil
    }

}

@MainActor
final class ServerConnectionModel: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var route: HomeBaseControlRoute?
    private var routeObservation: Task<Void, Never>?
    private var hasLoadedTopology = false
    @Published private(set) var topology = HBTopologyListResult(
        devices: [],
        rooms: [],
        groups: []
    )

    var presentedTopology: HBTopologyListResult {
        topology.includingOtherRoom
    }

    let client: HomeBaseWebSocketClient

    convenience init(server: PairedServer) {
        self.init(client: HomeBaseWebSocketClient(endpoint: server.endpoint, clientID: server.id, bluetoothServerID: server.id))
    }

    convenience init(endpoint: HomeBaseEndpoint, serverID: UUID) {
        self.init(client: HomeBaseWebSocketClient(endpoint: endpoint, clientID: serverID, bluetoothServerID: serverID))
    }

    init(client: HomeBaseWebSocketClient) {
        self.client = client
        routeObservation = Task { [weak self, client] in
            for await update in await client.controlConnectionStates() {
                guard let self else { return }
                self.route = update.route
                if update.recovering, self.hasLoadedTopology {
                    // A visible child can reconnect the shared client after a
                    // failed handover. Its recovery also restores the root badge.
                    switch self.state {
                    case .connected, .failed: self.state = .connecting
                    case .connecting, .disconnected: break
                    }
                }
                else if update.route != nil, self.state == .connecting, self.hasLoadedTopology { self.state = .connected }
                else if let error = update.error, self.state == .connected || self.state == .connecting { self.state = .failed(error) }
            }
        }
    }

    deinit {
        routeObservation?.cancel()
        let client = client
        Task {
            await client.disconnect()
        }
    }

    func load() async {
        await load(reactivating: false)
    }

    func reactivate() async {
        await load(reactivating: true)
    }

    private func load(reactivating: Bool) async {
        guard state != .connecting else { return }
        let previousState = state
        state = .connecting

        do {
            try await HomeBaseObservationRecovery.run(onSessionReset: {}) {
                if reactivating {
                    try await client.reactivate()
                } else {
                    try await client.connect()
                }
                let topology = try await client.listTopology()
                try Task.checkCancellation()
                self.topology = topology
                hasLoadedTopology = true
                state = .connected
            }
        } catch is CancellationError {
            state = previousState
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func refresh() async {
        guard state == .connected else {
            await load()
            return
        }

        do {
            try await HomeBaseObservationRecovery.run(onSessionReset: {}) {
                try await client.reactivate()
                topology = try await client.listTopology()
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        Task {
            await client.disconnect()
        }
        state = .disconnected
    }

}

struct HiddenItemsRowLabel: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: "eye.slash")
            Spacer(minLength: 8)
            Text(count, format: .number)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
