#if os(macOS)
import HomeBaseProtocol
import SwiftUI

enum MacSidebarDestination: Hashable {
    case cameras, scenes, triggers
    case container(MacHomeContainer)
}

/// A shared sidebar with three columns for devices and two for feature pages.
struct MacServerNavigationView<Cameras: View, Scenes: View, Triggers: View>: View {
    @ObservedObject var connection: ServerConnectionModel
    @Binding var selection: MacSidebarDestination
    @ViewBuilder let cameras: () -> Cameras
    @ViewBuilder let scenes: () -> Scenes
    @ViewBuilder let triggers: () -> Triggers
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var topology: HBTopologyListResult { connection.presentedTopology }
    private var isBrowsingDevices: Bool {
        switch selection {
        case .container: true
        case .cameras, .scenes, .triggers: false
        }
    }
    private var homeContainer: MacHomeContainer? {
        if case .container(let container) = selection { container } else { nil }
    }

    var body: some View {
        Group {
            if isBrowsingDevices {
                MacHomeNavigationView(
                    connection: connection, container: homeContainer,
                    columnVisibility: $columnVisibility
                ) { sidebar }
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar
                } detail: {
                    NavigationStack {
                        switch selection {
                        case .cameras:
                            cameras()
                                .navigationTitle("Cameras")
                                .connectionStatusClearance()
                        case .scenes:
                            scenes()
                        case .triggers:
                            triggers()
                        case .container:
                            EmptyView()
                        }
                    }
                    .id(selection)
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .onChange(of: topology, initial: true) { _, topology in
            reconcileSelection(in: topology)
        }
    }

    private var sidebarSelection: Binding<MacSidebarDestination?> {
        Binding(get: { selection }, set: { if let destination = $0 { selection = destination } })
    }

    private var sidebar: some View {
        let placement = TopologyGroupPlacement(topology: topology)
        let rooms = topology.rooms.filter { !$0.metadata.hasHiddenFlag }
        let deviceGroups = placement.topLevelDeviceGroups.filter { !$0.metadata.hasHiddenFlag }
        let groups = placement.topLevelGroups.filter { !$0.metadata.hasHiddenFlag }
        let hiddenCount = topology.rooms.filter(\.metadata.hasHiddenFlag).count
            + placement.topLevelDeviceItems.filter(\.isHidden).count
            + placement.topLevelGroups.filter(\.metadata.hasHiddenFlag).count

        return List(selection: sidebarSelection) {
            Label("All Devices", systemImage: "square.grid.2x2")
                .tag(MacSidebarDestination.container(.allDevices))
            Label("Cameras", systemImage: "video").tag(MacSidebarDestination.cameras)
            Label("Scenes", systemImage: "sparkles").tag(MacSidebarDestination.scenes)
            Label("Triggers", systemImage: "bolt").tag(MacSidebarDestination.triggers)

            Section("Rooms") {
                if rooms.isEmpty {
                    Text(emptyRoomsMessage).foregroundStyle(.secondary)
                }
                ForEach(rooms, id: \.identifier) { room in
                    TopologyRowLabel(
                        title: room.displayName,
                        technicalName: connection.topology.containsRoom(identifier: room.identifier)
                            ? room.identifier : nil,
                        detail: TopologyRowLabel.deviceCountDescription(
                            placement.deviceItems(in: room).filter { !$0.isHidden }.count
                        )
                    )
                    .tag(MacSidebarDestination.container(.room(room.identifier)))
                }
            }
            if !deviceGroups.isEmpty {
                Section("Devices") {
                    ForEach(deviceGroups, id: \.identifier) { group in
                        TopologyDeviceGroupRow(group: group)
                            .tag(MacSidebarDestination.container(.group(group.identifier)))
                    }
                }
            }
            if !groups.isEmpty {
                Section("Groups") {
                    ForEach(groups, id: \.identifier) { group in
                        TopologyGroupRow(group: group)
                            .tag(MacSidebarDestination.container(.group(group.identifier)))
                    }
                }
            }
            if hiddenCount > 0 {
                Section("Hidden") {
                    HiddenItemsRowLabel(title: "Hidden Items", count: hiddenCount)
                        .tag(MacSidebarDestination.container(.hiddenRoot))
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("home.sidebar")
        .navigationTitle("Home")
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        .refreshable { await connection.refresh() }
        .connectionStatusClearance()
    }

    private func reconcileSelection(in topology: HBTopologyListResult) {
        guard let container = homeContainer else { return }
        var navigation = MacHomeNavigationSelection()
        navigation.selectSidebar(container, in: topology)
        if navigation.sidebar == nil {
            selection = .container(.allDevices)
        }
    }

    private var emptyRoomsMessage: String {
        switch connection.state {
        case .connected: "No rooms are configured."
        case .failed: "Rooms could not be loaded."
        case .disconnected, .connecting: "Rooms will appear after connecting."
        }
    }
}
#endif
