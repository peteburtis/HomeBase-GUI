#if os(macOS)
import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class MacHomeNavigationModelTests: XCTestCase {
    func testAllDevicesShowsVisibleCatalogWithoutGroupControls() throws {
        let topology = HBTopologyListResult(
            devices: [device("unassigned", name: "Zulu"), device("b", name: "Beta"),
                      device("hidden", hidden: true), device("a", name: "Alpha")],
            rooms: [room("Study", devices: ["a", "b"])],
            groups: [group("Task", devices: ["a", "b"], presented: true)]
        )
        let content = try XCTUnwrap(MacHomeContent(container: .allDevices, topology: topology))

        XCTAssertEqual(content.deviceItems.map(\.id), ["device:a", "device:b", "device:unassigned"])
        XCTAssertTrue(content.rooms.isEmpty)
        XCTAssertTrue(content.groups.isEmpty)
        XCTAssertNil(content.controlDeviceIdentifier)
        XCTAssertEqual(content.hiddenDestination, .hiddenAllDevices)
        XCTAssertEqual(content.hiddenCount, 1)

        var selection = MacHomeNavigationSelection()
        selection.selectSidebar(.allDevices, in: topology)
        XCTAssertEqual(selection.currentContainer, .allDevices)
        XCTAssertNil(selection.detail)
        selection.setPath([.group("Task")], in: topology)
        XCTAssertTrue(selection.path.isEmpty, "All Devices presents physical devices rather than group navigation.")
        selection.detail = .groupControls("control-Task")
        selection.reconcile(in: topology)
        XCTAssertNil(selection.detail)
    }

    func testAllDevicesHiddenItemsRequireNestedNavigation() throws {
        let topology = HBTopologyListResult(
            devices: [device("visible"), device("hidden-b", name: "Beta", hidden: true),
                      device("hidden-a", name: "Alpha", hidden: true)],
            rooms: [], groups: []
        )
        let hidden = try XCTUnwrap(MacHomeContent(container: .hiddenAllDevices, topology: topology))
        XCTAssertEqual(hidden.deviceItems.map(\.id), ["device:hidden-a", "device:hidden-b"])
        XCTAssertNil(hidden.hiddenDestination)
        XCTAssertEqual(hidden.hiddenCount, 0)
        XCTAssertNil(hidden.controlDeviceIdentifier)

        var selection = MacHomeNavigationSelection()
        selection.selectSidebar(.hiddenAllDevices, in: topology)
        XCTAssertNil(selection.sidebar, "Hidden All Devices is a child, not a direct sidebar destination.")
        selection.selectSidebar(.allDevices, in: topology)
        selection.detail = .device("hidden-a")
        selection.reconcile(in: topology)
        XCTAssertNil(selection.detail)

        selection.setPath([.hiddenAllDevices], in: topology)
        XCTAssertEqual(selection.currentContainer, .hiddenAllDevices)
        XCTAssertNil(selection.detail)
        selection.detail = .device("hidden-a")
        selection.reconcile(in: topology)
        XCTAssertEqual(selection.detail, .device("hidden-a"))
    }

    func testAllDevicesRemainsAValidRootForAnEmptyCatalog() throws {
        let topology = HBTopologyListResult(devices: [], rooms: [], groups: [])
        let content = try XCTUnwrap(MacHomeContent(container: .allDevices, topology: topology))
        XCTAssertTrue(content.deviceItems.isEmpty)
        XCTAssertNil(content.hiddenDestination)
        XCTAssertNil(content.controlDeviceIdentifier)

        var selection = MacHomeNavigationSelection()
        selection.selectSidebar(.allDevices, in: topology)
        selection.reconcile(in: topology)
        XCTAssertEqual(selection.sidebar, .allDevices)
        XCTAssertEqual(selection.currentContainer, .allDevices)
        XCTAssertNil(selection.detail)
        selection.setPath([.hiddenAllDevices], in: topology)
        XCTAssertTrue(selection.path.isEmpty, "An empty hidden catalog must not create a navigation destination.")
    }

    func testAllDevicesSelectionReconcilesCatalogAdditionsAndRemovals() {
        var topology = HBTopologyListResult(devices: [device("a")], rooms: [], groups: [])
        var selection = MacHomeNavigationSelection()
        selection.selectSidebar(.allDevices, in: topology)
        selection.detail = .device("a")

        topology.devices = [device("b"), device("a", name: "Renamed")]
        selection.reconcile(in: topology)
        XCTAssertEqual(selection.detail, .device("a"), "Adding devices and refreshing metadata must retain the selection.")

        topology.devices = [device("b")]
        selection.reconcile(in: topology)
        XCTAssertEqual(selection.sidebar, .allDevices)
        XCTAssertNil(selection.detail, "A removed device must not remain in the detail column.")

        topology.devices = []
        selection.reconcile(in: topology)
        XCTAssertEqual(selection.currentContainer, .allDevices)
        XCTAssertTrue(selection.path.isEmpty)
        XCTAssertNil(selection.detail)
    }

    func testAllDevicesReconcilePrunesAnEmptyHiddenDestination() {
        var topology = HBTopologyListResult(
            devices: [device("visible"), device("hidden", hidden: true)], rooms: [], groups: []
        )
        var selection = MacHomeNavigationSelection()
        selection.selectSidebar(.allDevices, in: topology)
        selection.setPath([.hiddenAllDevices], in: topology)
        selection.detail = .device("hidden")

        topology.devices = [device("visible")]
        selection.reconcile(in: topology)
        XCTAssertEqual(selection.sidebar, .allDevices)
        XCTAssertEqual(selection.currentContainer, .allDevices)
        XCTAssertTrue(selection.path.isEmpty)
        XCTAssertNil(selection.detail)
    }

    func testChangingSidebarClearsNestedNavigationAndSelectsGroupControls() {
        let topology = fixture()
        var selection = MacHomeNavigationSelection()
        selection.selectSidebar(.room("Study"), in: topology)
        selection.setPath([.group("Task")], in: topology)
        selection.detail = .device("a")

        selection.selectSidebar(.room("Workshop"), in: topology)
        XCTAssertEqual(selection.currentContainer, .room("Workshop"))
        XCTAssertTrue(selection.path.isEmpty)
        XCTAssertNil(selection.detail)

        selection.selectSidebar(.group("All"), in: topology)
        XCTAssertEqual(selection.detail, .groupControls("control-All"))
        selection.selectSidebar(nil, in: topology)
        XCTAssertNil(selection.sidebar)
        XCTAssertNil(selection.currentContainer)
        XCTAssertNil(selection.detail)
    }

    func testRepeatedSelectionAndMetadataRefreshKeepTheCurrentDevice() {
        let topology = fixture()
        var selection = MacHomeNavigationSelection()
        selection.selectSidebar(.room("Study"), in: topology)
        selection.setPath([.group("Task")], in: topology)
        selection.detail = .device("a")

        selection.selectSidebar(.room("Study"), in: topology)
        selection.setPath([.group("Task")], in: topology)
        var renamed = topology
        renamed.devices = [device("a", name: "Renamed Lamp"), device("b"), device("c"), device("d")]
        selection.reconcile(in: renamed)

        XCTAssertEqual(selection.sidebar, .room("Study"))
        XCTAssertEqual(selection.path, [.group("Task")])
        XCTAssertEqual(selection.detail, .device("a"))
    }

    func testPresentedGroupsSuppressConstituentsButAllowNestedNavigation() throws {
        let inner = group("Inner", devices: ["a", "b"], presented: true)
        let outer = group("Outer", devices: ["a", "b", "c"], presented: true,
                          members: [.init(kind: .group, identifier: "Inner"), .init(kind: .device, identifier: "c")])
        let topology = HBTopologyListResult(
            devices: ["a", "b", "c", "d"].map { device($0) },
            rooms: [room("Study", devices: ["a", "b", "c", "d"])],
            groups: [outer, inner]
        )
        let roomContent = try XCTUnwrap(MacHomeContent(container: .room("Study"), topology: topology))
        XCTAssertEqual(Set(roomContent.deviceItems.map(\.id)), ["group:Outer", "device:d"])
        XCTAssertTrue(roomContent.groups.isEmpty)
        let outerContent = try XCTUnwrap(MacHomeContent(container: .group("Outer"), topology: topology))
        XCTAssertEqual(Set(outerContent.deviceItems.map(\.id)), ["group:Inner", "device:c"])
        let innerContent = try XCTUnwrap(MacHomeContent(container: .group("Inner"), topology: topology))
        XCTAssertEqual(innerContent.deviceItems.map(\.id), ["device:a", "device:b"])

        var selection = MacHomeNavigationSelection()
        selection.selectSidebar(.room("Study"), in: topology)
        selection.setPath([.group("Outer"), .group("Inner")], in: topology)
        XCTAssertEqual(selection.currentContainer, .group("Inner"))
        XCTAssertEqual(selection.detail, .groupControls("control-Inner"))
        selection.detail = .device("a")
        selection.setPath([.group("Outer"), .group("Inner"), .room("Study")], in: topology)
        XCTAssertEqual(selection.path, [.group("Outer"), .group("Inner")], "Unreachable children must not enter the middle-column path.")
        XCTAssertEqual(selection.detail, .device("a"))
        selection.setPath([.group("Outer")], in: topology)
        XCTAssertEqual(selection.detail, .groupControls("control-Outer"))
    }

    func testRoomAndGroupHiddenItemsRequireExplicitHiddenNavigation() throws {
        let topology = HBTopologyListResult(
            devices: [device("visible"), device("hidden", hidden: true)],
            rooms: [room("Study", devices: ["visible", "hidden"])],
            groups: [group("HiddenGroup", devices: ["hidden"], hidden: true)]
        )
        let visible = try XCTUnwrap(MacHomeContent(container: .room("Study"), topology: topology))
        XCTAssertEqual(visible.deviceItems.map(\.id), ["device:visible"])
        XCTAssertTrue(visible.groups.isEmpty)
        XCTAssertEqual(visible.hiddenDestination, .hiddenRoom("Study"))
        XCTAssertEqual(visible.hiddenCount, 2)

        let hidden = try XCTUnwrap(MacHomeContent(container: .hiddenRoom("Study"), topology: topology))
        XCTAssertEqual(hidden.deviceItems.map(\.id), ["device:hidden"])
        XCTAssertEqual(hidden.groups.map(\.identifier), ["HiddenGroup"])
        XCTAssertNil(hidden.hiddenDestination)
        XCTAssertNil(hidden.controlDeviceIdentifier)

        var selection = MacHomeNavigationSelection()
        selection.selectSidebar(.room("Study"), in: topology)
        selection.setPath([.group("HiddenGroup")], in: topology)
        XCTAssertTrue(selection.path.isEmpty)
        selection.setPath([.hiddenRoom("Study"), .group("HiddenGroup")], in: topology)
        XCTAssertEqual(selection.detail, .groupControls("control-HiddenGroup"))
        selection.setPath([.hiddenRoom("Study"), .group("HiddenGroup"), .hiddenGroup("HiddenGroup")], in: topology)
        XCTAssertNil(selection.detail)
        let groupHidden = try XCTUnwrap(MacHomeContent(container: selection.currentContainer!, topology: topology))
        XCTAssertEqual(groupHidden.deviceItems.map(\.id), ["device:hidden"])
        XCTAssertNil(groupHidden.controlDeviceIdentifier)
    }

    func testHiddenRootMatchesHiddenTopLevelRoomsGroupsAndDeviceGroups() throws {
        let topology = HBTopologyListResult(
            devices: ["a", "b", "c", "d"].map { device($0) },
            rooms: [room("Secret", devices: ["a"], hidden: true), room("Public", devices: ["b"]),
                    room("Third", devices: ["c"]), room("Fourth", devices: ["d"])],
            groups: [group("HiddenGroup", devices: ["a", "b"], hidden: true),
                     group("HiddenDeviceGroup", devices: ["c", "d"], presented: true, hidden: true)]
        )
        let hidden = try XCTUnwrap(MacHomeContent(container: .hiddenRoot, topology: topology))
        XCTAssertEqual(hidden.rooms.map(\.identifier), ["Secret"])
        XCTAssertEqual(hidden.groups.map(\.identifier), ["HiddenGroup"])
        XCTAssertEqual(hidden.deviceItems.map(\.id), ["group:HiddenDeviceGroup"])

        var selection = MacHomeNavigationSelection()
        selection.selectSidebar(.room("Secret"), in: topology)
        XCTAssertNil(selection.sidebar)
        selection.selectSidebar(.hiddenRoot, in: topology)
        selection.setPath([.room("Secret")], in: topology)
        XCTAssertEqual(selection.currentContainer, .room("Secret"))
        selection.setPath([.group("HiddenDeviceGroup")], in: topology)
        XCTAssertEqual(selection.detail, .groupControls("control-HiddenDeviceGroup"))
    }

    func testReconcilePrunesRemovedContainersAndHiddenPaths() {
        var topology = fixture()
        var selection = MacHomeNavigationSelection()
        selection.selectSidebar(.room("Study"), in: topology)
        selection.setPath([.group("Task")], in: topology)
        selection.detail = .device("a")
        topology.groups = [group("Task", devices: ["a", "b"], presented: true, hidden: true),
                           group("All", devices: ["a", "b", "c", "d"])]
        selection.reconcile(in: topology)
        XCTAssertEqual(selection.sidebar, .room("Study"))
        XCTAssertTrue(selection.path.isEmpty, "A newly hidden child must no longer be reachable through the visible path.")
        XCTAssertNil(selection.detail)

        selection.setPath([.hiddenRoom("Study"), .group("Task")], in: topology)
        XCTAssertEqual(selection.currentContainer, .group("Task"))
        topology.groups = []
        selection.reconcile(in: topology)
        XCTAssertTrue(selection.path.isEmpty, "Remove an empty Hidden Items path along with its removed child.")
        XCTAssertNil(selection.detail)

        topology.rooms = topology.rooms.filter { $0.identifier != "Study" }
        selection.reconcile(in: topology)
        XCTAssertNil(selection.sidebar)
        XCTAssertNil(selection.detail)
    }

    func testReconcileClearsRemovedDeviceAndRestoresGroupDefault() {
        var topology = HBTopologyListResult(
            devices: [device("a"), device("b")], rooms: [],
            groups: [group("All", devices: ["a", "b"])]
        )
        var selection = MacHomeNavigationSelection()
        selection.selectSidebar(.group("All"), in: topology)
        selection.detail = .device("b")
        selection.reconcile(in: topology)
        XCTAssertEqual(selection.detail, .device("b"))
        topology.groups = [group("All", devices: ["a"])]
        topology.devices = [device("a")]
        selection.reconcile(in: topology)
        XCTAssertEqual(selection.detail, .groupControls("control-All"))

        topology.rooms = [room("Study", devices: ["a", "b"])]
        topology.groups = []
        selection.selectSidebar(.room("Study"), in: topology)
        selection.detail = .device("b")
        topology.rooms = [room("Study", devices: ["a"])]
        selection.reconcile(in: topology)
        XCTAssertNil(selection.detail)
    }

    func testReferencedDeviceMissingFromCatalogRemainsSelectable() throws {
        let topology = HBTopologyListResult(devices: [], rooms: [room("Study", devices: ["missing"])], groups: [])
        let content = try XCTUnwrap(MacHomeContent(container: .room("Study"), topology: topology))
        XCTAssertEqual(content.deviceItems.map(\.id), ["device:missing"])
        var selection = MacHomeNavigationSelection()
        selection.selectSidebar(.room("Study"), in: topology)
        selection.detail = .device("missing")
        selection.reconcile(in: topology)
        XCTAssertEqual(selection.detail, .device("missing"))
    }

    func testSyntheticOtherRoomUsesPresentedTopologyAndSurvivesRefresh() throws {
        let topology = HBTopologyListResult(devices: [device("orphan")], rooms: [], groups: []).includingOtherRoom
        let other = try XCTUnwrap(topology.rooms.first)
        var selection = MacHomeNavigationSelection()
        selection.selectSidebar(.room(other.identifier), in: topology)
        selection.detail = .device("orphan")
        selection.reconcile(in: topology)
        XCTAssertEqual(selection.currentContainer, .room(other.identifier))
        XCTAssertEqual(selection.detail, .device("orphan"))
        XCTAssertEqual(MacHomeContent(container: .room(other.identifier), topology: topology)?.title, "Other")
    }

    private func fixture() -> HBTopologyListResult {
        HBTopologyListResult(
            devices: ["a", "b", "c", "d"].map { device($0) },
            rooms: [room("Study", devices: ["a", "b", "c"]), room("Workshop", devices: ["d"])],
            groups: [group("Task", devices: ["a", "b"], presented: true),
                     group("All", devices: ["a", "b", "c", "d"])]
        )
    }

    private func device(_ identifier: String, name: String? = nil, hidden: Bool = false) -> HBTopologyDeviceDescriptor {
        HBTopologyDeviceDescriptor(identifier: identifier, addressableName: identifier, displayName: name ?? identifier,
                                   metadata: hidden ? ["hidden": true] : [:])
    }

    private func room(_ identifier: String, devices: [String], hidden: Bool = false) -> HBTopologyRoomDescriptor {
        HBTopologyRoomDescriptor(identifier: identifier, displayName: identifier,
                                 members: devices.map { .init(kind: .device, identifier: $0) },
                                 resolvedDeviceIdentifiers: devices, metadata: hidden ? ["hidden": true] : [:])
    }

    private func group(_ identifier: String, devices: [String], presented: Bool = false, hidden: Bool = false,
                       members: [HBTopologyMemberDescriptor]? = nil) -> HBTopologyGroupDescriptor {
        var metadata: [String: HBJSONValue] = [:]
        if presented { metadata["presentationDisposition"] = "device" }
        if hidden { metadata["hidden"] = true }
        return HBTopologyGroupDescriptor(
            identifier: identifier, displayName: identifier, origin: .configured, role: .general,
            members: members ?? devices.map { .init(kind: .device, identifier: $0) },
            resolvedDeviceIdentifiers: devices, controlDeviceIdentifier: "control-\(identifier)", metadata: metadata
        )
    }
}
#endif
