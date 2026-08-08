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
    private let deviceIdentifiers: [String]
    private let nestedGroups: [HBTopologyGroupDescriptor]
    private let topology: HBTopologyListResult
    private let client: HomeBaseWebSocketClient
    private let hasControlDevice: Bool
    @StateObject private var controlModel: LiveDeviceControlsModel

    init(
        room: HBTopologyRoomDescriptor,
        topology: HBTopologyListResult,
        client: HomeBaseWebSocketClient
    ) {
        title = room.displayName
        emptyMessage = "No devices are configured in this room."
        deviceIdentifiers = room.resolvedDeviceIdentifiers
        nestedGroups = TopologyGroupPlacement(topology: topology).groups(
            in: room
        )
        self.topology = topology
        self.client = client
        hasControlDevice = false
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
        title = group.displayName
        emptyMessage = "No devices are configured in this group."
        deviceIdentifiers = group.resolvedDeviceIdentifiers
        nestedGroups = []
        self.topology = topology
        self.client = client
        hasControlDevice = true
        _controlModel = StateObject(
            wrappedValue: LiveDeviceControlsModel(
                device: controlDevice,
                client: client
            )
        )
    }

    var body: some View {
        List {
            if hasControlDevice {
                LiveDeviceControlSections(
                    model: controlModel,
                    subjectKind: "group"
                )
            }

            Section("Devices") {
                TopologyDeviceRows(
                    emptyMessage: emptyMessage,
                    deviceIdentifiers: deviceIdentifiers,
                    topology: topology,
                    client: client
                )
            }

            if !nestedGroups.isEmpty {
                Section("Groups") {
                    ForEach(nestedGroups, id: \.identifier) { group in
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
        }
        .navigationTitle(title)
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
            displayName: group.displayName
        )
    }

}

private struct TopologyDeviceRows: View {
    let emptyMessage: String
    let deviceIdentifiers: [String]
    let topology: HBTopologyListResult
    let client: HomeBaseWebSocketClient

    var body: some View {
        if devices.isEmpty {
            Text(emptyMessage)
                .foregroundStyle(.secondary)
        } else {
            ForEach(devices, id: \.identifier) { device in
                NavigationLink {
                    DeviceDetailView(device: device, client: client)
                } label: {
                    VStack(alignment: .leading) {
                        Text(device.displayName)
                        if device.addressableName != device.displayName {
                            Text(device.addressableName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var devices: [HBTopologyDeviceDescriptor] {
        let devicesByIdentifier = Dictionary(
            uniqueKeysWithValues: topology.devices.map {
                ($0.identifier, $0)
            }
        )
        return deviceIdentifiers
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
