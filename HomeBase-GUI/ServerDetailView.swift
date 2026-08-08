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
    @StateObject private var connection: ServerConnectionModel

    init(server: PairedServer) {
        self.server = server
        _connection = StateObject(
            wrappedValue: ServerConnectionModel(endpoint: server.endpoint)
        )
    }

    var body: some View {
        TabView {
            homeView
                .tabItem {
                    Label("Home", systemImage: "house")
                }

            ScenesView(
                server: server,
                client: connection.client
            )
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
        List {
            Section {
                if connection.rooms.isEmpty {
                    Text(emptyRoomsMessage)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(connection.rooms, id: \.identifier) { room in
                        NavigationLink {
                            RoomDetailView(
                                room: room,
                                topology: connection.topology,
                                client: connection.client
                            )
                        } label: {
                            VStack(alignment: .leading) {
                                Text(room.displayName)
                                Text(
                                    room.resolvedDeviceIdentifiers.count == 1
                                        ? "1 device"
                                        : "\(room.resolvedDeviceIdentifiers.count) devices"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Rooms")
            } footer: {
                if connection.topLevelGroups.isEmpty {
                    connectionStatus
                }
            }

            if !connection.topLevelGroups.isEmpty {
                Section {
                    ForEach(connection.topLevelGroups, id: \.identifier) { group in
                        NavigationLink {
                            GroupDetailView(
                                group: group,
                                topology: connection.topology,
                                client: connection.client
                            )
                        } label: {
                            TopologyGroupRow(group: group)
                        }
                    }
                } header: {
                    Text("Groups")
                } footer: {
                    connectionStatus
                }
            }
        }
        .navigationTitle(server.endpoint.host)
        .refreshable {
            await connection.refresh()
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch connection.state {
        case .disconnected:
            Label("Disconnected", systemImage: "network.slash")
                .foregroundStyle(.secondary)
        case .connecting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Connecting…")
            }
            .foregroundStyle(.secondary)
        case .connected:
            Label(
                "Connected",
                systemImage: "dot.radiowaves.left.and.right"
            )
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 5) {
                Label("Connection Failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.red)
                Button("Try Again") {
                    Task {
                        await connection.load()
                    }
                }
            }
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

    var rooms: [HBTopologyRoomDescriptor] {
        topology.rooms
    }

    var topLevelGroups: [HBTopologyGroupDescriptor] {
        TopologyGroupPlacement(topology: topology).topLevelGroups
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
