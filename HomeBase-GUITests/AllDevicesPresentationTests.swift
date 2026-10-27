import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class AllDevicesPresentationTests: XCTestCase {
    func testAllDevicesUsesTheCatalogWithoutRoomOrGroupSuppression() {
        let room = HBTopologyRoomDescriptor(
            identifier: "Study", displayName: "Study",
            members: ["lamp-a", "lamp-b", "missing"].map { .init(kind: .device, identifier: $0) },
            resolvedDeviceIdentifiers: ["lamp-a", "lamp-b", "missing"]
        )
        let group = HBTopologyGroupDescriptor(
            identifier: "TaskLights", displayName: "Task Lights", origin: .configured, role: .general,
            members: ["lamp-a", "lamp-b"].map { .init(kind: .device, identifier: $0) },
            resolvedDeviceIdentifiers: ["lamp-a", "lamp-b"],
            controlDeviceIdentifier: "control-TaskLights",
            metadata: ["presentationDisposition": "device"]
        )
        let topology = HBTopologyListResult(
            devices: [device("unassigned", name: "Unassigned"), device("lamp-b", name: "Beta Lamp"),
                      device("hidden", name: "Hidden Sensor", hidden: true), device("lamp-a", name: "Alpha Lamp")],
            rooms: [room], groups: [group]
        )
        let placement = TopologyGroupPlacement(topology: topology)

        XCTAssertEqual(Set(placement.deviceItems(in: room).map(\.id)), ["group:TaskLights", "device:missing"])
        XCTAssertEqual(placement.allDeviceItems.map(\.id),
                       ["device:lamp-a", "device:lamp-b", "device:hidden", "device:unassigned"])
        XCTAssertEqual(placement.allDeviceItems.filter(\.isHidden).map(\.id), ["device:hidden"])
        XCTAssertFalse(placement.allDeviceItems.contains { item in
            if case .group = item { return true }
            return false
        }, "All Devices must not replace physical constituents with a synthetic group control.")
    }

    func testAllDevicesSortsByDisplayNameWithStableIdentifierTieBreak() {
        let topology = HBTopologyListResult(
            devices: [device("z", name: "Zulu"), device("b", name: "alpha"),
                      device("a", name: "Alpha"), device("m", name: "Bravo")],
            rooms: [], groups: []
        )

        XCTAssertEqual(TopologyGroupPlacement(topology: topology).allDeviceItems.map(\.id),
                       ["device:a", "device:b", "device:m", "device:z"])
    }

    private func device(_ identifier: String, name: String, hidden: Bool = false) -> HBTopologyDeviceDescriptor {
        HBTopologyDeviceDescriptor(identifier: identifier, addressableName: identifier, displayName: name,
                                   metadata: hidden ? ["hidden": true] : [:])
    }
}
