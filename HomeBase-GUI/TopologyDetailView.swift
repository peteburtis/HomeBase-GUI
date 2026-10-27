//
//  TopologyDetailView.swift
//  HomeBase-GUI
//

import HomeBaseProtocol
import SwiftUI

struct TopologyDetailView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.homeSplitViewLayout) private var splitLayout

    private let title: String
    private let emptyMessage: String
    private let deviceItems: [TopologyDeviceListItem]
    private let nestedGroups: [HBTopologyGroupDescriptor]
    private let topology: HBTopologyListResult
    private let client: HomeBaseWebSocketClient
    private let controlDevice: HBTopologyDeviceDescriptor?
    private let selection: Binding<TopologyDetailDestination?>
    @StateObject private var controlModel: LiveDeviceControlsModel
    @State private var monitoring = LiveMonitoringSession()
    @State private var hasInitializedControlSelection = false
    @State private var hasFinishedAppearing = false

    init(
        allDevicesIn topology: HBTopologyListResult,
        client: HomeBaseWebSocketClient,
        selection: Binding<TopologyDetailDestination?>
    ) {
        title = "All Devices"
        emptyMessage = "No devices are available."
        deviceItems = TopologyGroupPlacement(topology: topology).allDeviceItems
        nestedGroups = []
        self.topology = topology
        self.client = client
        controlDevice = nil
        self.selection = selection
        _controlModel = StateObject(wrappedValue: LiveDeviceControlsModel(device: nil, client: client))
    }

    init(
        room: HBTopologyRoomDescriptor,
        topology: HBTopologyListResult,
        client: HomeBaseWebSocketClient,
        selection: Binding<TopologyDetailDestination?>
    ) {
        let placement = TopologyGroupPlacement(topology: topology)
        title = room.displayName
        emptyMessage = "No devices are configured in this room."
        deviceItems = placement.deviceItems(in: room)
        nestedGroups = placement.groups(in: room)
        self.topology = topology
        self.client = client
        controlDevice = nil
        self.selection = selection
        _controlModel = StateObject(
            wrappedValue: LiveDeviceControlsModel(
                device: nil,
                client: client
            )
        )
    }

    init(
        group: HBTopologyGroupDescriptor,
        topology: HBTopologyListResult,
        client: HomeBaseWebSocketClient,
        selection: Binding<TopologyDetailDestination?>
    ) {
        let controlDevice = group.controlDeviceDescriptor
        let placement = TopologyGroupPlacement(topology: topology)
        title = group.displayName
        emptyMessage = "No devices are configured in this group."
        deviceItems = placement.deviceItems(in: group)
        nestedGroups = []
        self.topology = topology
        self.client = client
        self.controlDevice = controlDevice
        self.selection = selection
        _controlModel = StateObject(
            wrappedValue: LiveDeviceControlsModel(
                device: controlDevice,
                client: client
            )
        )
    }

    var body: some View {
        List(selection: selection) { sections }
        .navigationTitle(title)
        .connectionStatusReport(controlModel.state.connectionStatusPresentation(
            isActive: showsInlineGroupControls && scenePhase == .active
        )) {
            monitoring.restart()
        }
        .onNavigationAppearanceCompleted {
            hasFinishedAppearing = true
            updateDefaultControlSelection()
        }
        .onChange(of: splitLayout) { _, _ in
            guard hasFinishedAppearing else { return }
            updateDefaultControlSelection()
        }
        .onChange(of: showsInlineGroupControls && scenePhase == .active, initial: true) { _, active in
            monitoring.setActive(active) { [controlModel] in
                await controlModel.run(reactivating: true)
            }
        }
        .onDisappear {
            hasFinishedAppearing = false
        }
    }

    private func updateDefaultControlSelection() {
        guard let controlDevice else { return }
        switch splitLayout {
        case .expanded:
            if !hasInitializedControlSelection || selection.wrappedValue == nil {
                selection.wrappedValue = .groupControls(controlDevice.identifier)
            }
            hasInitializedControlSelection = true
        case .collapsed:
            hasInitializedControlSelection = true
        case .none:
            break
        }
    }

    @ViewBuilder
    private var sections: some View {
        if let controlDevice {
            if splitLayout == .expanded {
                Section {
                    NavigationLink(value: TopologyDetailDestination.groupControls(controlDevice.identifier)) {
                        Label("Control All", systemImage: "slider.horizontal.3")
                    }
                }
            } else {
                LiveDeviceControlSections(
                    model: controlModel,
                    subjectKind: "group"
                )

                Section {
                    NavigationLink(value: TopologyDetailDestination.groupAdvanced(controlDevice.identifier)) {
                        Label("Advanced", systemImage: "slider.horizontal.3")
                    }
                }
            }
        }

        Section("Devices") {
            TopologyDeviceRows(
                emptyMessage: deviceItems.isEmpty
                    ? emptyMessage
                    : "No visible devices are configured here.",
                items: visibleDeviceItems,
                topology: topology,
                client: client,
                selection: selection
            )
        }

        if !visibleNestedGroups.isEmpty {
            Section("Groups") {
                ForEach(visibleNestedGroups, id: \.identifier) { group in
                    NavigationLink {
                        GroupDetailView(
                            group: group,
                            topology: topology,
                            client: client,
                            selection: selection
                        )
                    } label: {
                        TopologyGroupRow(group: group)
                    }
#if os(iOS) || os(visionOS)
                    .isDetailLink(false)
#endif
                }
            }
        }

        if !hiddenDeviceItems.isEmpty || !hiddenNestedGroups.isEmpty {
            Section("Hidden") {
                NavigationLink {
                    HiddenTopologyItemsView(
                        rooms: [],
                        deviceItems: hiddenDeviceItems,
                        groups: hiddenNestedGroups,
                        topology: topology,
                        client: client,
                        selection: selection
                    )
                } label: {
                    HiddenItemsRowLabel(
                        title: "Hidden Items",
                        count: hiddenDeviceItems.count
                            + hiddenNestedGroups.count
                    )
                }
#if os(iOS) || os(visionOS)
                .isDetailLink(false)
#endif
            }
        }
    }

    private var showsInlineGroupControls: Bool {
        controlDevice != nil && splitLayout == .collapsed
    }

    private var visibleDeviceItems: [TopologyDeviceListItem] {
        deviceItems.filter { !$0.isHidden }
    }

    private var hiddenDeviceItems: [TopologyDeviceListItem] {
        deviceItems.filter(\.isHidden)
    }

    private var visibleNestedGroups: [HBTopologyGroupDescriptor] {
        nestedGroups.filter { !$0.metadata.hasHiddenFlag }
    }

    private var hiddenNestedGroups: [HBTopologyGroupDescriptor] {
        nestedGroups.filter { $0.metadata.hasHiddenFlag }
    }

}

struct TopologyDeviceRows: View {
    let emptyMessage: String
    let items: [TopologyDeviceListItem]
    let topology: HBTopologyListResult
    let client: HomeBaseWebSocketClient
    let selection: Binding<TopologyDetailDestination?>

    var body: some View {
        if items.isEmpty {
            Text(emptyMessage)
                .foregroundStyle(.secondary)
        } else {
            ForEach(items) { item in
                itemRow(item)
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: TopologyDeviceListItem) -> some View {
        switch item {
        case .device(let device):
            NavigationLink(value: TopologyDetailDestination.device(device.identifier)) {
                TopologyRowLabel(
                    title: device.displayName,
                    technicalName: device.addressableName
                )
            }

        case .group(let group):
            NavigationLink {
                GroupDetailView(
                    group: group,
                    topology: topology,
                    client: client,
                    selection: selection
                )
            } label: {
                TopologyDeviceGroupRow(group: group)
            }
#if os(iOS) || os(visionOS)
            .isDetailLink(false)
#endif
        }
    }
}

struct HiddenTopologyItemsView: View {
    let rooms: [HBTopologyRoomDescriptor]
    let deviceItems: [TopologyDeviceListItem]
    let groups: [HBTopologyGroupDescriptor]
    let topology: HBTopologyListResult
    let client: HomeBaseWebSocketClient
    let selection: Binding<TopologyDetailDestination?>

    var body: some View {
        List(selection: selection) { sections }
        .navigationTitle("Hidden")
        .connectionStatusClearance()
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    @ViewBuilder
    private var sections: some View {
        if !rooms.isEmpty {
            Section("Rooms") {
                ForEach(rooms, id: \.identifier) { room in
                    NavigationLink {
                        RoomDetailView(
                            room: room,
                            topology: topology,
                            client: client,
                            selection: selection
                        )
                    } label: {
                        TopologyRowLabel(
                            title: room.displayName,
                            technicalName: room.identifier,
                            detail: TopologyRowLabel
                                .deviceCountDescription(
                                    room.resolvedDeviceIdentifiers.count
                                )
                        )
                    }
#if os(iOS) || os(visionOS)
                    .isDetailLink(false)
#endif
                }
            }
        }

        if !groups.isEmpty {
            Section("Groups") {
                ForEach(groups, id: \.identifier) { group in
                    NavigationLink {
                        GroupDetailView(
                            group: group,
                            topology: topology,
                            client: client,
                            selection: selection
                        )
                    } label: {
                        TopologyGroupRow(group: group)
                    }
#if os(iOS) || os(visionOS)
                    .isDetailLink(false)
#endif
                }
            }
        }

        if !deviceItems.isEmpty {
            Section("Devices") {
                TopologyDeviceRows(
                    emptyMessage: "No hidden devices.",
                    items: deviceItems,
                    topology: topology,
                    client: client,
                    selection: selection
                )
            }
        }
    }
}

extension HBTopologyListResult {
    func isHiddenDevice(identifiedBy identifier: String) -> Bool {
        devices.first { $0.identifier == identifier }?
            .metadata.hasHiddenFlag == true
    }

    func devices(identifiedBy identifiers: [String])
        -> [HBTopologyDeviceDescriptor]
    {
        let devicesByIdentifier = Dictionary(
            uniqueKeysWithValues: devices.map {
                ($0.identifier, $0)
            }
        )
        return identifiers
            .map { identifier in
                devicesByIdentifier[identifier]
                    ?? HBTopologyDeviceDescriptor(
                        identifier: identifier,
                        addressableName: identifier,
                        displayName: identifier
                    )
            }
            .sorted {
                let displayOrder = $0.displayName
                    .localizedCaseInsensitiveCompare($1.displayName)
                if displayOrder != .orderedSame {
                    return displayOrder == .orderedAscending
                }
                return $0.identifier < $1.identifier
            }
    }
}
