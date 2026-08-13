//
//  TopologyGroupPlacementTests.swift
//  HomeBase-GUITests
//

import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class TopologyGroupPlacementTests: XCTestCase {
    func testDeviceDispositionMovesGroupIntoDevicesAndSuppressesMembers() {
        let presentedGroup = group(
            "TaskLights",
            members: [.device("lamp-a"), .device("lamp-b")],
            resolvedDevices: ["lamp-a", "lamp-b"],
            metadata: ["presentationDisposition": "device"]
        )
        let ordinaryGroup = group(
            "AccentLights",
            members: [.device("lamp-c")],
            resolvedDevices: ["lamp-c"]
        )
        let room = room(
            "Study",
            devices: ["lamp-a", "lamp-b", "lamp-c"]
        )
        let placement = TopologyGroupPlacement(
            topology: topology(
                devices: ["lamp-a", "lamp-b", "lamp-c"],
                rooms: [room],
                groups: [presentedGroup, ordinaryGroup]
            )
        )

        XCTAssertEqual(
            placement.deviceItems(in: room).map(\.id),
            ["device:lamp-c", "group:TaskLights"]
        )
        XCTAssertEqual(
            placement.groups(in: room).map(\.identifier),
            ["AccentLights"]
        )
    }

    func testTopLevelDeviceGroupSuppressesItsMembersAcrossRooms() {
        let presentedGroup = group(
            "WholeHomeTaskLights",
            members: [.device("lamp-a"), .device("lamp-b")],
            resolvedDevices: ["lamp-a", "lamp-b"],
            metadata: ["presentationDisposition": "device"]
        )
        let firstRoom = room("First", devices: ["lamp-a", "sensor-a"])
        let secondRoom = room("Second", devices: ["lamp-b", "sensor-b"])
        let placement = TopologyGroupPlacement(
            topology: topology(
                devices: ["lamp-a", "lamp-b", "sensor-a", "sensor-b"],
                rooms: [firstRoom, secondRoom],
                groups: [presentedGroup]
            )
        )

        XCTAssertEqual(
            placement.topLevelDeviceItems.map(\.id),
            ["group:WholeHomeTaskLights"]
        )
        XCTAssertEqual(
            placement.deviceItems(in: firstRoom).map(\.id),
            ["device:sensor-a"]
        )
        XCTAssertEqual(
            placement.deviceItems(in: secondRoom).map(\.id),
            ["device:sensor-b"]
        )
    }

    func testOpeningPresentedGroupRevealsItsConstituents() {
        let nestedPresentedGroup = group(
            "ReadingLights",
            members: [.device("lamp-a"), .device("lamp-b")],
            resolvedDevices: ["lamp-a", "lamp-b"],
            metadata: ["presentationDisposition": "device"]
        )
        let presentedGroup = group(
            "TaskLights",
            members: [.group("ReadingLights"), .device("lamp-c")],
            resolvedDevices: ["lamp-a", "lamp-b", "lamp-c"],
            metadata: ["presentationDisposition": "device"]
        )
        let room = room(
            "Study",
            devices: ["lamp-a", "lamp-b", "lamp-c"]
        )
        let placement = TopologyGroupPlacement(
            topology: topology(
                devices: ["lamp-a", "lamp-b", "lamp-c"],
                rooms: [room],
                groups: [presentedGroup, nestedPresentedGroup]
            )
        )

        XCTAssertEqual(
            placement.deviceItems(in: room).map(\.id),
            ["group:TaskLights"]
        )
        XCTAssertEqual(
            placement.deviceItems(in: presentedGroup).map(\.id),
            ["device:lamp-c", "group:ReadingLights"]
        )
        XCTAssertEqual(
            placement.deviceItems(in: nestedPresentedGroup).map(\.id),
            ["device:lamp-a", "device:lamp-b"]
        )
    }

    func testUnknownDispositionKeepsNormalGroupPresentation() {
        let ordinaryGroup = group(
            "TaskLights",
            members: [.device("lamp-a")],
            resolvedDevices: ["lamp-a"],
            metadata: ["presentationDisposition": "future-value"]
        )
        let room = room("Study", devices: ["lamp-a"])
        let placement = TopologyGroupPlacement(
            topology: topology(
                devices: ["lamp-a"],
                rooms: [room],
                groups: [ordinaryGroup]
            )
        )

        XCTAssertEqual(
            placement.deviceItems(in: room).map(\.id),
            ["device:lamp-a"]
        )
        XCTAssertEqual(
            placement.groups(in: room).map(\.identifier),
            ["TaskLights"]
        )
    }

    private func topology(
        devices: [String],
        rooms: [HBTopologyRoomDescriptor],
        groups: [HBTopologyGroupDescriptor]
    ) -> HBTopologyListResult {
        HBTopologyListResult(
            devices: devices.map { identifier in
                HBTopologyDeviceDescriptor(
                    identifier: identifier,
                    addressableName: identifier,
                    displayName: identifier
                )
            },
            rooms: rooms,
            groups: groups
        )
    }

    private func room(
        _ identifier: String,
        devices: [String]
    ) -> HBTopologyRoomDescriptor {
        HBTopologyRoomDescriptor(
            identifier: identifier,
            displayName: identifier,
            members: devices.map { .device($0) },
            resolvedDeviceIdentifiers: devices
        )
    }

    private func group(
        _ identifier: String,
        members: [HBTopologyMemberDescriptor],
        resolvedDevices: [String],
        metadata: [String: HBJSONValue] = [:]
    ) -> HBTopologyGroupDescriptor {
        HBTopologyGroupDescriptor(
            identifier: identifier,
            displayName: identifier,
            origin: .configured,
            role: .general,
            members: members,
            resolvedDeviceIdentifiers: resolvedDevices,
            controlDeviceIdentifier: identifier,
            metadata: metadata
        )
    }
}

private extension HBTopologyMemberDescriptor {
    static func device(_ identifier: String) -> Self {
        Self(kind: .device, identifier: identifier)
    }

    static func group(_ identifier: String) -> Self {
        Self(kind: .group, identifier: identifier)
    }
}
