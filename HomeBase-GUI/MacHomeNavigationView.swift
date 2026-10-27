#if os(macOS)
import HomeBaseProtocol
import SwiftUI

struct MacHomeNavigationView<Sidebar: View>: View {
    @ObservedObject var connection: ServerConnectionModel
    let container: MacHomeContainer?
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @ViewBuilder let sidebar: () -> Sidebar
    @State private var navigation = MacHomeNavigationSelection()

    private var topology: HBTopologyListResult { connection.presentedTopology }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar()
        } content: {
            NavigationStack(path: contentPath) {
                contents(for: navigation.sidebar)
                    .navigationDestination(for: MacHomeContainer.self) { container in
                        contents(for: container)
                    }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
        } detail: {
            TopologyDetailDestinationView(
                selection: navigation.detail,
                topology: topology,
                client: connection.client
            )
            // A new device also replaces any Advanced screen from the old device.
            .id(navigation.detail)
            .navigationSplitViewColumnWidth(min: 320, ideal: 420)
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: container, initial: true) { _, container in
            navigation.selectSidebar(container, in: topology)
        }
        .onChange(of: topology) { _, topology in
            navigation.reconcile(in: topology)
        }
    }

    private var contentPath: Binding<[MacHomeContainer]> {
        Binding(
            get: { navigation.path },
            set: { navigation.setPath($0, in: topology) }
        )
    }

    @ViewBuilder
    private func contents(for container: MacHomeContainer?) -> some View {
        if let container, let content = MacHomeContent(container: container, topology: topology) {
            MacHomeContentList(content: content, selection: $navigation.detail)
                .id(container)
        } else {
            ContentUnavailableView(
                "Select a Room or Group", systemImage: "square.grid.2x2",
                description: Text("Choose a room or group to browse its devices.")
            )
            .navigationTitle("Devices")
        }
    }
}

private struct MacHomeContentList: View {
    let content: MacHomeContent
    @Binding var selection: TopologyDetailDestination?

    var body: some View {
        List(selection: $selection) {
            if let identifier = content.controlDeviceIdentifier {
                Section(content.title) {
                    Label("Control All", systemImage: "slider.horizontal.3")
                        .tag(TopologyDetailDestination.groupControls(identifier))
                }
            }
            if !content.rooms.isEmpty {
                Section("Rooms") {
                    ForEach(content.rooms, id: \.identifier) { room in
                        NavigationLink(value: MacHomeContainer.room(room.identifier)) {
                            TopologyRowLabel(title: room.displayName, technicalName: room.identifier)
                        }
                    }
                }
            }
            if !content.deviceItems.isEmpty || (content.rooms.isEmpty && content.groups.isEmpty) {
                Section("Devices") {
                    if content.deviceItems.isEmpty {
                        Text(content.emptyDevicesMessage).foregroundStyle(.secondary)
                    }
                    ForEach(content.deviceItems) { item in
                        switch item {
                        case .device(let device):
                            // Native List selection drives the third column. Container
                            // links alone push the middle column's navigation stack.
                            TopologyRowLabel(title: device.displayName, technicalName: device.addressableName)
                                .tag(TopologyDetailDestination.device(device.identifier))
                        case .group(let group):
                            NavigationLink(value: MacHomeContainer.group(group.identifier)) {
                                TopologyDeviceGroupRow(group: group)
                            }
                        }
                    }
                }
            }
            if !content.groups.isEmpty {
                Section("Groups") {
                    ForEach(content.groups, id: \.identifier) { group in
                        NavigationLink(value: MacHomeContainer.group(group.identifier)) {
                            TopologyGroupRow(group: group)
                        }
                    }
                }
            }
            if let hidden = content.hiddenDestination {
                Section("Hidden") {
                    NavigationLink(value: hidden) {
                        HiddenItemsRowLabel(title: "Hidden Items", count: content.hiddenCount)
                    }
                }
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("home.contents")
        .navigationTitle(content.title)
        .connectionStatusClearance()
    }
}
#endif
