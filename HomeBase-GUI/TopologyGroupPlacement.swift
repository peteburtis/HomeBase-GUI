//
//  TopologyGroupPlacement.swift
//  HomeBase-GUI
//

import HomeBaseProtocol

struct TopologyGroupPlacement {
    let topLevelGroups: [HBTopologyGroupDescriptor]
    private let groupsByRoomIdentifier: [String: [HBTopologyGroupDescriptor]]

    init(topology: HBTopologyListResult) {
        let rooms = topology.rooms.map(Room.init)
        var topLevelGroups: [HBTopologyGroupDescriptor] = []
        var groupsByRoomIdentifier: [String: [HBTopologyGroupDescriptor]] = [:]

        for group in topology.groups {
            guard let roomIdentifier = Self.roomIdentifier(
                containing: group,
                among: rooms
            ) else {
                topLevelGroups.append(group)
                continue
            }

            groupsByRoomIdentifier[roomIdentifier, default: []].append(group)
        }

        self.topLevelGroups = topLevelGroups
        self.groupsByRoomIdentifier = groupsByRoomIdentifier
    }

    func groups(in room: HBTopologyRoomDescriptor) -> [HBTopologyGroupDescriptor] {
        groupsByRoomIdentifier[room.identifier] ?? []
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

    private struct Room {
        let identifier: String
        let deviceIdentifiers: Set<String>

        init(_ room: HBTopologyRoomDescriptor) {
            identifier = room.identifier
            deviceIdentifiers = Set(room.resolvedDeviceIdentifiers)
        }
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
