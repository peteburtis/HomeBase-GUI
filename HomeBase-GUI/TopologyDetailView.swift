//
//  TopologyDetailView.swift
//  HomeBase-GUI
//

import HomeBaseProtocol
import SwiftUI

struct TopologyDetailView: View {
    @Environment(\.scenePhase) private var scenePhase

    private let title: String
    private let emptyMessage: String
    private let deviceItems: [TopologyDeviceListItem]
    private let nestedGroups: [HBTopologyGroupDescriptor]
    private let topology: HBTopologyListResult
    private let client: HomeBaseWebSocketClient
    private let controlDevice: HBTopologyDeviceDescriptor?
    @StateObject private var controlModel: LiveDeviceControlsModel

    init(
        room: HBTopologyRoomDescriptor,
        topology: HBTopologyListResult,
        client: HomeBaseWebSocketClient
    ) {
        let placement = TopologyGroupPlacement(topology: topology)
        title = room.displayName
        emptyMessage = "No devices are configured in this room."
        deviceItems = placement.deviceItems(in: room)
        nestedGroups = placement.groups(in: room)
        self.topology = topology
        self.client = client
        controlDevice = nil
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
        client: HomeBaseWebSocketClient
    ) {
        let controlDevice = Self.controlDevice(for: group)
        let placement = TopologyGroupPlacement(topology: topology)
        title = group.displayName
        emptyMessage = "No devices are configured in this group."
        deviceItems = placement.deviceItems(in: group)
        nestedGroups = []
        self.topology = topology
        self.client = client
        self.controlDevice = controlDevice
        _controlModel = StateObject(
            wrappedValue: LiveDeviceControlsModel(
                device: controlDevice,
                client: client
            )
        )
    }

    var body: some View {
        List {
            if let controlDevice {
                LiveDeviceControlSections(
                    model: controlModel,
                    subjectKind: "group"
                )

                Section {
                    NavigationLink {
                        DeviceAdvancedView(
                            device: controlDevice,
                            client: client
                        )
                    } label: {
                        Label("Advanced", systemImage: "slider.horizontal.3")
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
                    client: client
                )
            }

            if !visibleNestedGroups.isEmpty {
                Section("Groups") {
                    ForEach(visibleNestedGroups, id: \.identifier) { group in
                        NavigationLink {
                            GroupDetailView(
                                group: group,
                                topology: topology,
                                client: client
                            )
                        } label: {
                            TopologyGroupRow(group: group)
                        }
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
                            client: client
                        )
                    } label: {
                        HiddenItemsRowLabel(
                            title: "Hidden Items",
                            count: hiddenDeviceItems.count
                                + hiddenNestedGroups.count
                        )
                    }
                }
            }
        }
        .navigationTitle(title)
        .connectionStatusOverlay(
            controlDevice != nil
                ? controlModel.state.connectionStatusPresentation
                : nil
        ) {
            Task {
                await controlModel.run()
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active {
                await controlModel.run(reactivating: true)
            } else {
                await controlModel.stop()
            }
        }
        .onDisappear {
            Task {
                await controlModel.stop()
            }
        }
    }

    private static func controlDevice(
        for group: HBTopologyGroupDescriptor
    ) -> HBTopologyDeviceDescriptor {
        HBTopologyDeviceDescriptor(
            identifier: group.controlDeviceIdentifier,
            addressableName: group.controlDeviceIdentifier,
            displayName: group.displayName,
            metadata: group.metadata
        )
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
            NavigationLink {
                DeviceDetailView(device: device, client: client)
            } label: {
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
                    client: client
                )
            } label: {
                TopologyDeviceGroupRow(group: group)
            }
        }
    }
}

struct HiddenTopologyItemsView: View {
    let rooms: [HBTopologyRoomDescriptor]
    let deviceItems: [TopologyDeviceListItem]
    let groups: [HBTopologyGroupDescriptor]
    let topology: HBTopologyListResult
    let client: HomeBaseWebSocketClient

    var body: some View {
        List {
            if !rooms.isEmpty {
                Section("Rooms") {
                    ForEach(rooms, id: \.identifier) { room in
                        NavigationLink {
                            RoomDetailView(
                                room: room,
                                topology: topology,
                                client: client
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
                                client: client
                            )
                        } label: {
                            TopologyGroupRow(group: group)
                        }
                    }
                }
            }

            if !deviceItems.isEmpty {
                Section("Devices") {
                    TopologyDeviceRows(
                        emptyMessage: "No hidden devices.",
                        items: deviceItems,
                        topology: topology,
                        client: client
                    )
                }
            }
        }
        .navigationTitle("Hidden")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
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
