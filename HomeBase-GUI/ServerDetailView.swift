//
//  ServerDetailView.swift
//  HomeBase-GUI
//

import Combine
import HomeBaseProtocol
import SwiftUI

struct ServerDetailView: View {
    @Environment(\.scenePhase) private var scenePhase

    let server: PairedServer
    let showServers: () -> Void
    @StateObject private var connection: ServerConnectionModel

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
        TabView {
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

            NavigationStack {
                ScenesView(
                    client: connection.client
                )
            }
                .tabItem {
                    Label("Scenes", systemImage: "sparkles")
                }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await connection.reactivate()
        }
    }

    private var homeView: some View {
        let topology = connection.presentedTopology
        let topLevelGroups = TopologyGroupPlacement(
            topology: topology
        ).topLevelGroups

        return List {
            Section {
                if topology.rooms.isEmpty {
                    Text(emptyRoomsMessage)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(topology.rooms, id: \.identifier) { room in
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
                                    room.resolvedDeviceIdentifiers.count
                                )
                            )
                        }
                    }
                }
            } header: {
                Text("Rooms")
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

private extension HBTopologyListResult {
    func containsRoom(identifier: String) -> Bool {
        rooms.contains { $0.identifier == identifier }
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
        let assignedDeviceIdentifiers = Set(
            topology.rooms.flatMap(\.resolvedDeviceIdentifiers)
        )
        let unassignedDevices = topology.devices.filter {
            !assignedDeviceIdentifiers.contains($0.identifier)
        }
        guard !unassignedDevices.isEmpty else { return topology }

        var presentedTopology = topology
        presentedTopology.rooms.append(
            HBTopologyRoomDescriptor(
                identifier: Self.otherRoomIdentifier(
                    avoiding: topology.rooms.map(\.identifier)
                ),
                displayName: "Other",
                members: unassignedDevices.map {
                    HBTopologyMemberDescriptor(
                        kind: .device,
                        identifier: $0.identifier
                    )
                },
                resolvedDeviceIdentifiers: unassignedDevices.map(\.identifier)
            )
        )
        return presentedTopology
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

    private static func otherRoomIdentifier(
        avoiding roomIdentifiers: [String]
    ) -> String {
        let existingIdentifiers = Set(roomIdentifiers)
        let baseIdentifier = "homebase-gui.other-room"
        guard existingIdentifiers.contains(baseIdentifier) else {
            return baseIdentifier
        }

        var suffix = 2
        while existingIdentifiers.contains("\(baseIdentifier).\(suffix)") {
            suffix += 1
        }
        return "\(baseIdentifier).\(suffix)"
    }
}
