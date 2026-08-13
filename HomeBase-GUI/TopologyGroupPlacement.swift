//
//  TopologyGroupPlacement.swift
//  HomeBase-GUI
//

import Foundation
import HomeBaseProtocol

@MainActor
struct TopologyGroupPlacement {
    let topLevelGroups: [HBTopologyGroupDescriptor]
    let topLevelDeviceGroups: [HBTopologyGroupDescriptor]
    private let topology: HBTopologyListResult
    private let groupsByRoomIdentifier: [String: [HBTopologyGroupDescriptor]]
    private let deviceGroupsByRoomIdentifier:
        [String: [HBTopologyGroupDescriptor]]
    private let groupsByIdentifier: [String: HBTopologyGroupDescriptor]

    init(topology: HBTopologyListResult) {
        let rooms = topology.rooms.map(Room.init)
        let groupsByIdentifier = Dictionary(
            uniqueKeysWithValues: topology.groups.map {
                ($0.identifier, $0)
            }
        )
        let groupsSuppressedByPresentingAncestors = Set(
            topology.groups
                .filter(\.presentsAsDevice)
                .flatMap {
                    Self.descendantGroupIdentifiers(
                        of: $0,
                        groupsByIdentifier: groupsByIdentifier
                    )
                }
        )
        var topLevelGroups: [HBTopologyGroupDescriptor] = []
        var topLevelDeviceGroups: [HBTopologyGroupDescriptor] = []
        var groupsByRoomIdentifier: [String: [HBTopologyGroupDescriptor]] = [:]
        var deviceGroupsByRoomIdentifier:
            [String: [HBTopologyGroupDescriptor]] = [:]

        for group in topology.groups {
            guard !groupsSuppressedByPresentingAncestors.contains(
                group.identifier
            ) else {
                continue
            }
            guard let roomIdentifier = Self.roomIdentifier(
                containing: group,
                among: rooms
            ) else {
                if group.presentsAsDevice {
                    topLevelDeviceGroups.append(group)
                } else {
                    topLevelGroups.append(group)
                }
                continue
            }

            if group.presentsAsDevice {
                deviceGroupsByRoomIdentifier[
                    roomIdentifier,
                    default: []
                ].append(group)
            } else {
                groupsByRoomIdentifier[roomIdentifier, default: []].append(
                    group
                )
            }
        }

        self.topology = topology
        self.topLevelGroups = topLevelGroups
        self.topLevelDeviceGroups = topLevelDeviceGroups
        self.groupsByRoomIdentifier = groupsByRoomIdentifier
        self.deviceGroupsByRoomIdentifier = deviceGroupsByRoomIdentifier
        self.groupsByIdentifier = groupsByIdentifier
    }

    func groups(in room: HBTopologyRoomDescriptor) -> [HBTopologyGroupDescriptor] {
        groupsByRoomIdentifier[room.identifier] ?? []
    }

    func deviceItems(in room: HBTopologyRoomDescriptor)
        -> [TopologyDeviceListItem]
    {
        let deviceGroups = deviceGroupsByRoomIdentifier[room.identifier] ?? []
        let suppressedIdentifiers = Set(
            (topLevelDeviceGroups + deviceGroups)
                .flatMap(\.resolvedDeviceIdentifiers)
        )
        let physicalDevices = topology.devices(
            identifiedBy: room.resolvedDeviceIdentifiers.filter {
                !suppressedIdentifiers.contains($0)
            }
        )
        return Self.sortedDeviceItems(
            physicalDevices.map(TopologyDeviceListItem.device)
                + deviceGroups.map(TopologyDeviceListItem.group)
        )
    }

    func deviceItems(in group: HBTopologyGroupDescriptor)
        -> [TopologyDeviceListItem]
    {
        let deviceGroups: [HBTopologyGroupDescriptor] =
            group.members.compactMap { member -> HBTopologyGroupDescriptor? in
            guard member.kind == .group,
                  let nestedGroup = groupsByIdentifier[member.identifier],
                  nestedGroup.presentsAsDevice else {
                return nil
            }
            return nestedGroup
        }
        let suppressedIdentifiers = Set(
            deviceGroups.flatMap { $0.resolvedDeviceIdentifiers }
        )
        let physicalDevices = topology.devices(
            identifiedBy: group.resolvedDeviceIdentifiers.filter {
                !suppressedIdentifiers.contains($0)
            }
        )
        return Self.sortedDeviceItems(
            physicalDevices.map(TopologyDeviceListItem.device)
                + deviceGroups.map(TopologyDeviceListItem.group)
        )
    }

    var topLevelDeviceItems: [TopologyDeviceListItem] {
        Self.sortedDeviceItems(
            topLevelDeviceGroups.map(TopologyDeviceListItem.group)
        )
    }

    private static func sortedDeviceItems(
        _ items: [TopologyDeviceListItem]
    ) -> [TopologyDeviceListItem] {
        items.sorted {
            let displayOrder = $0.displayName.localizedCaseInsensitiveCompare(
                $1.displayName
            )
            if displayOrder != .orderedSame {
                return displayOrder == .orderedAscending
            }
            return $0.id < $1.id
        }
    }

    private static func roomIdentifier(
        containing group: HBTopologyGroupDescriptor,
        among rooms: [Room]
    ) -> String? {
        let deviceIdentifiers = Set(group.resolvedDeviceIdentifiers)
        guard !deviceIdentifiers.isEmpty else { return nil }

        let containingRooms = rooms.filter {
            deviceIdentifiers.isSubset(of: $0.deviceIdentifiers)
        }
        guard !containingRooms.isEmpty else { return nil }

        if let declaredRoomIdentifier = group.roomIdentifier,
           containingRooms.contains(where: {
               $0.identifier == declaredRoomIdentifier
           }) {
            return declaredRoomIdentifier
        }

        return containingRooms.min {
            if $0.deviceIdentifiers.count != $1.deviceIdentifiers.count {
                return $0.deviceIdentifiers.count < $1.deviceIdentifiers.count
            }
            return $0.identifier < $1.identifier
        }?.identifier
    }

    private static func descendantGroupIdentifiers(
        of group: HBTopologyGroupDescriptor,
        groupsByIdentifier: [String: HBTopologyGroupDescriptor]
    ) -> Set<String> {
        var descendants: Set<String> = []
        var pending = group.members.compactMap { member in
            member.kind == .group ? member.identifier : nil
        }
        while let identifier = pending.popLast() {
            guard descendants.insert(identifier).inserted,
                  let nestedGroup = groupsByIdentifier[identifier] else {
                continue
            }
            pending.append(
                contentsOf: nestedGroup.members.compactMap { member in
                    member.kind == .group ? member.identifier : nil
                }
            )
        }
        return descendants
    }

    private struct Room {
        let identifier: String
        let deviceIdentifiers: Set<String>

        init(_ room: HBTopologyRoomDescriptor) {
            identifier = room.identifier
            deviceIdentifiers = Set(room.resolvedDeviceIdentifiers)
        }
    }
}

enum TopologyDeviceListItem: Identifiable, Equatable, Sendable {
    case device(HBTopologyDeviceDescriptor)
    case group(HBTopologyGroupDescriptor)

    var id: String {
        switch self {
        case .device(let device):
            "device:\(device.identifier)"
        case .group(let group):
            "group:\(group.identifier)"
        }
    }

    var displayName: String {
        switch self {
        case .device(let device):
            device.displayName
        case .group(let group):
            group.displayName
        }
    }

    var isHidden: Bool {
        switch self {
        case .device(let device):
            device.metadata.hasHiddenFlag
        case .group(let group):
            group.metadata.hasHiddenFlag
        }
    }
}

extension HBTopologyGroupDescriptor {
    var presentsAsDevice: Bool {
        metadata.topologyPresentationDisposition == .device
    }
}

extension HBTopologyListResult {
    /// Adds the presentation-only room used by the app for devices that do
    /// not belong to any configured room. The synthetic room is appended so
    /// it remains the final room everywhere the topology is presented.
    var includingOtherRoom: HBTopologyListResult {
        let assignedDeviceIdentifiers = Set(
            rooms.flatMap(\.resolvedDeviceIdentifiers)
        )
        let unassignedDevices = devices.filter {
            !assignedDeviceIdentifiers.contains($0.identifier)
        }
        guard !unassignedDevices.isEmpty else { return self }

        var presentedTopology = self
        presentedTopology.rooms.append(
            HBTopologyRoomDescriptor(
                identifier: Self.otherRoomIdentifier(
                    avoiding: rooms.map(\.identifier)
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

    func containsRoom(identifier: String) -> Bool {
        rooms.contains { $0.identifier == identifier }
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
