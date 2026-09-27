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
    @State private var selectedTab: Tab = .home
    @State private var isShowingCamera = false

    init(
        server: PairedServer,
        showServers: @escaping () -> Void
    ) {
        self.server = server
        self.showServers = showServers
        _connection = StateObject(
            wrappedValue: ServerConnectionModel(endpoint: server.endpoint)
        )
    }

    var body: some View {
        let cameras = CameraVideoCatalog.cameras(
            in: connection.topology.devices
        )

        TabView(selection: $selectedTab) {
            NavigationStack {
                homeView
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button("Servers", systemImage: "list.bullet") {
                                showServers()
                            }
                        }
                    }
            }
                .tabItem {
                    Label("Home", systemImage: "house")
                }
                .tag(Tab.home)

            if !cameras.isEmpty {
                VideoView(
                    cameras: cameras,
                    client: connection.client,
                    onPresentationChanged: { isShowingCamera = $0 }
                )
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
                .tabItem {
                    Label("Scenes", systemImage: "sparkles")
                }
                .tag(Tab.scenes)

            NavigationStack {
                TriggersView(
                    client: connection.client
                )
            }
                .tabItem {
                    Label("Triggers", systemImage: "bolt")
                }
                .tag(Tab.triggers)
        }
        .cameraAccessScope(
            isActive: selectedTab == .cameras,
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
        .onChange(of: selectedTab) { _, tab in
            if tab == .cameras { cameraViewer?.restore() }
        }
#endif
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await connection.reactivate()
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

        return List {
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
                                client: connection.client
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
                        client: connection.client
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
                                client: connection.client
                            )
                        } label: {
                            TopologyGroupRow(group: group)
                        }
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
                            client: connection.client
                        )
                    } label: {
                        HiddenItemsRowLabel(
                            title: "Hidden Items",
                            count: hiddenRooms.count
                                + hiddenTopLevelDeviceItems.count
                                + hiddenTopLevelGroups.count
                        )
                    }
                }
            }
        }
        .navigationTitle("Home")
        .refreshable {
            await connection.refresh()
        }
        .connectionStatusOverlay(connectionStatus) {
            Task {
                await connection.load()
            }
        }
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
    @Published private(set) var topology = HBTopologyListResult(
        devices: [],
        rooms: [],
        groups: []
    )

    var presentedTopology: HBTopologyListResult {
        topology.includingOtherRoom
    }

    let client: HomeBaseWebSocketClient

    init(endpoint: HomeBaseEndpoint) {
        client = HomeBaseWebSocketClient(endpoint: endpoint)
    }

    deinit {
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
            if reactivating {
                try await client.reactivate()
            } else {
                try await client.connect()
            }
            let topology = try await client.listTopology()
            try Task.checkCancellation()
            self.topology = topology
            state = .connected
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
            try await client.reactivate()
            topology = try await client.listTopology()
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
