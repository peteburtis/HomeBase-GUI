#if os(iOS)
import HomeBaseProtocol
import SwiftUI
import UIKit
import XCTest
@testable import HomeBase_GUI

@MainActor
final class SplitNavigationPresentationTests: XCTestCase {
    func testCompactAllDevicesIncludesGroupedAndUnassignedDevicesAndHiddenItems() async throws {
        try await assertAllDevicesNavigation(sizeClass: .compact)
    }

    func testExpandedAllDevicesIncludesGroupedAndUnassignedDevicesAndHiddenItems() async throws {
        try await assertAllDevicesNavigation(sizeClass: .regular)
    }

    func testCompactDeviceStartsMonitoring() async throws {
        let fixture = try await makeFixture(sizeClass: .compact)
        defer { fixture.close() }
        let split = try XCTUnwrap(descendant(UISplitViewController.self, in: fixture.host))
        try await selectRow(0, section: 1, in: split)
        try await selectRow(0, in: split)
        XCTAssertTrue(titles(in: split).contains("Desk Lamp"))
        let requests = await fixture.requests.deviceDetailCount
        XCTAssertGreaterThan(requests, 0, "Showing a device in the collapsed split must start monitoring.")
        let subscriptions = await fixture.requests.activeControlDevices
        XCTAssertEqual(subscriptions, ["lamp"])
        snapshot(fixture, name: "Compact monitoring")
    }

    func testMonitoringSurvivesCollapseAndReopeningDevice() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let split = try XCTUnwrap(descendant(UISplitViewController.self, in: fixture.host))
        try await selectRow(0, section: 1, in: XCTUnwrap(split.viewController(for: .primary)))
        try await selectRow(0, in: XCTUnwrap(split.viewController(for: .primary)))
        let originalSubscriptions = await fixture.requests.activeControlSubscriptionIDs
        fixture.window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        fixture.host.traitOverrides.horizontalSizeClass = .compact
        try await settle()
        let foldedSubscriptions = await fixture.requests.activeControlSubscriptionIDs
        XCTAssertEqual(foldedSubscriptions, originalSubscriptions, "Folding a selected device must retain the same subscription, not restart it.")
        let navigation = try XCTUnwrap(descendant(UINavigationController.self, in: split))
        for _ in 0..<2 {
            navigation.popViewController(animated: false)
            try await settle()
            XCTAssertTrue(titles(in: split).contains("Study"), titles(in: split).description)
            try await selectRow(0, in: split)
            XCTAssertTrue(titles(in: split).contains("Desk Lamp"))
            let subscriptions = await fixture.requests.activeControlDevices
            XCTAssertEqual(subscriptions, ["lamp"], "Returning to a device after folding must restore its live subscription.")
        }
        let starts = await fixture.requests.controlSubscriptionStarts
        XCTAssertEqual(starts, 3, "Initial selection plus two explicit revisits; no appearance-triggered restarts.")
    }

    func testEmptyControlsStillReleaseMonitoringWhenCancelled() async throws {
        let fixture = try await makeFixture(hasControls: false)
        defer { fixture.close() }
        let model = LiveDeviceControlsModel(
            device: .init(identifier: "lamp", addressableName: "lamp", displayName: "Desk Lamp"),
            client: fixture.connection.client
        )
        let run = Task { await model.run() }
        try await settle()
        XCTAssertEqual(model.state, .live)
        XCTAssertTrue(model.controls.isEmpty)
        run.cancel()
        let finished = expectation(description: "Empty controls release the metadata observer")
        Task { await run.value; finished.fulfill() }
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(model.state, .idle)
    }

    func testRootContainersPushOneLevelOnRepeatedVisits() async throws {
        for sizeClass in [UIUserInterfaceSizeClass.regular, .compact] {
            let fixture = try await makeFixture(sizeClass: sizeClass)
            defer { fixture.close() }
            let split = try XCTUnwrap(descendant(UISplitViewController.self, in: fixture.host))
            let sidebar = split.isCollapsed ? split : try XCTUnwrap(split.viewController(for: .primary))
            let navigation = try XCTUnwrap(descendant(UINavigationController.self, in: sidebar))
            XCTAssertEqual(navigation.viewControllers.count, 1)

            // Visit again after Control All has populated the detail column.
            for _ in 0..<2 {
                for (section, title) in [(0, "All Devices"), (1, "Study"), (2, "Entire Home")] {
                    try await selectRow(0, section: section, in: sidebar)
                    XCTAssertTrue(titles(in: sidebar).contains(title))
                    XCTAssertEqual(navigation.viewControllers.count, 2, "A root link must add exactly one sidebar screen.")
                    navigation.popViewController(animated: false)
                    try await settle()
                    XCTAssertTrue(titles(in: sidebar).contains("Home"), "One Back must return directly to Home.")
                    XCTAssertEqual(navigation.viewControllers.count, 1)
                }
            }
        }
    }

    func testHomeBrowsesRoomsInSidebarAndSelectsDevicesInDetail() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let split = try XCTUnwrap(descendant(UISplitViewController.self, in: fixture.host))
        XCTAssertEqual(split.style, .doubleColumn)
        XCTAssertFalse(split.isCollapsed)

        let sidebar = try XCTUnwrap(split.viewController(for: .primary))
        try await selectRow(0, section: 1, in: sidebar)
        XCTAssertTrue(titles(in: sidebar).contains("Study"), titles(in: sidebar).description)
        XCTAssertFalse(try titles(in: XCTUnwrap(split.viewController(for: .secondary))).contains("Study"))

        try await selectRow(0, in: sidebar)
        let detail = try XCTUnwrap(split.viewController(for: .secondary))
        XCTAssertTrue(titles(in: detail).contains("Desk Lamp"), titles(in: detail).description)
        XCTAssertTrue(titles(in: sidebar).contains("Study"), "Device selection must not push the sidebar.")
        snapshot(fixture, name: "Home — room navigation and device detail")

        // Browsing another room stays in the sidebar until a new device is selected.
        let navigation = try XCTUnwrap(descendant(UINavigationController.self, in: sidebar))
        navigation.popViewController(animated: false)
        try await settle()
        XCTAssertTrue(titles(in: sidebar).contains("Home"))
        try await selectRow(1, section: 1, in: sidebar)
        XCTAssertTrue(titles(in: sidebar).contains("Workshop"))
        try await selectRow(1, in: sidebar)
        let currentDetail = try XCTUnwrap(split.viewController(for: .secondary))
        XCTAssertTrue(titles(in: currentDetail).contains("Workshop Sensor"), titles(in: currentDetail).description)
        XCTAssertFalse(titles(in: currentDetail).contains("Desk Lamp"), titles(in: currentDetail).description)
        XCTAssertTrue(titles(in: sidebar).contains("Workshop"))
        snapshot(fixture, name: "Home — switched room")
    }

    func testHomeSelectionSurvivesCollapseAndExpansion() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let split = try XCTUnwrap(descendant(UISplitViewController.self, in: fixture.host))
        try await selectRow(0, section: 1, in: XCTUnwrap(split.viewController(for: .primary)))
        try await selectRow(0, in: XCTUnwrap(split.viewController(for: .primary)))

        fixture.window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        fixture.host.traitOverrides.horizontalSizeClass = .compact
        try await settle()
        XCTAssertTrue(split.isCollapsed)
        XCTAssertTrue(titles(in: split).contains("Desk Lamp"), titles(in: split).description)
        snapshot(fixture, name: "Home — compact device detail")

        fixture.window.frame = CGRect(x: 0, y: 0, width: 1366, height: 1024)
        fixture.host.traitOverrides.horizontalSizeClass = .regular
        try await settle()
        XCTAssertFalse(split.isCollapsed)
        XCTAssertTrue(try titles(in: XCTUnwrap(split.viewController(for: .primary))).contains("Study"))
        XCTAssertTrue(try titles(in: XCTUnwrap(split.viewController(for: .secondary))).contains("Desk Lamp"))
    }

    func testCompactHomeStartsAtHomeAndDrillsIntoDevice() async throws {
        let fixture = try await makeFixture(sizeClass: .compact)
        defer { fixture.close() }
        let split = try XCTUnwrap(descendant(UISplitViewController.self, in: fixture.host))
        XCTAssertTrue(split.isCollapsed)
        XCTAssertTrue(titles(in: split).contains("Home"), titles(in: split).description)
        try await selectRow(0, section: 1, in: split)
        XCTAssertTrue(titles(in: split).contains("Study"), titles(in: split).description)
        try await selectRow(0, in: split)
        XCTAssertTrue(titles(in: split).contains("Desk Lamp"), titles(in: split).description)
        let navigation = try XCTUnwrap(descendant(UINavigationController.self, in: split))
        navigation.popViewController(animated: false)
        try await settle()
        XCTAssertTrue(titles(in: split).contains("Study"), titles(in: split).description)
        try await selectRow(0, in: split)
        XCTAssertTrue(titles(in: split).contains("Desk Lamp"), "The same device must be selectable again after Back.")
        navigation.popViewController(animated: false)
        try await settle()
        navigation.popViewController(animated: false)
        try await settle()
        XCTAssertTrue(titles(in: split).contains("Home"), titles(in: split).description)
    }

    func testSelectingAnotherDeviceKeepsSidebarList() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let split = try XCTUnwrap(descendant(UISplitViewController.self, in: fixture.host))
        let sidebar = try XCTUnwrap(split.viewController(for: .primary))
        try await selectRow(0, section: 2, in: sidebar)
        try await selectRow(0, section: 1, in: sidebar)
        XCTAssertTrue(try titles(in: XCTUnwrap(split.viewController(for: .secondary))).contains("Desk Lamp"))
        try await selectRow(1, section: 1, in: sidebar)
        XCTAssertTrue(try titles(in: XCTUnwrap(split.viewController(for: .secondary))).contains("Workshop Sensor"))
        XCTAssertTrue(titles(in: sidebar).contains("Entire Home"))
        let navigation = try XCTUnwrap(descendant(UINavigationController.self, in: sidebar))
        XCTAssertEqual(navigation.viewControllers.count, 2, "Device selections must not accumulate in the sidebar stack.")
    }

    func testSelectingDeviceReplacesAnAdvancedDetail() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let split = try XCTUnwrap(descendant(UISplitViewController.self, in: fixture.host))
        let sidebar = try XCTUnwrap(split.viewController(for: .primary))
        try await selectRow(0, section: 2, in: sidebar)
        let detail = try XCTUnwrap(split.viewController(for: .secondary))
        try await selectRow(0, section: 1, in: detail)
        XCTAssertTrue(titles(in: detail).contains("all-devices"))

        try await selectRow(0, section: 1, in: sidebar)
        let currentDetail = try XCTUnwrap(split.viewController(for: .secondary))
        XCTAssertTrue(titles(in: currentDetail).contains("Desk Lamp"))
        XCTAssertFalse(titles(in: currentDetail).contains("all-devices"), "A new selection must replace the old detail's drill-down without a forced stack identity reset.")
        XCTAssertTrue(titles(in: sidebar).contains("Entire Home"))
    }

    func testHomeNavigationAtSystemWindowSize() async throws {
        // No size-class or window-size overrides: exercise the simulator's
        // actual display, including the Duo's inner display when unfolded.
        let fixture = try await makeFixture(sizeClass: nil)
        defer { fixture.close() }
        let split = try XCTUnwrap(descendant(UISplitViewController.self, in: fixture.host))
        XCTAssertEqual(split.style, .doubleColumn)
        snapshot(fixture, name: "Home — initial system layout")
        // The system may initially hide the sidebar at this width. Reveal it
        // through the split controller just as its sidebar button does.
        if !split.isCollapsed {
            split.show(.primary)
            try await settle()
        }
        let sidebar = split.isCollapsed ? split : try XCTUnwrap(split.viewController(for: .primary))
        try await selectRow(0, section: 1, in: sidebar)
        XCTAssertTrue(titles(in: sidebar).contains("Study"))
        try await selectRow(0, in: sidebar)
        let detail = split.isCollapsed ? split : try XCTUnwrap(split.viewController(for: .secondary))
        XCTAssertTrue(titles(in: detail).contains("Desk Lamp"), titles(in: detail).description)
        if !split.isCollapsed {
            XCTAssertTrue(titles(in: sidebar).contains("Study"))
        }
        let layout = XCTAttachment(string: "Window: \(fixture.window.bounds); horizontal size class: \(split.traitCollection.horizontalSizeClass.rawValue); collapsed: \(split.isCollapsed); display mode: \(split.displayMode.rawValue)")
        layout.lifetime = .keepAlways
        add(layout)
        snapshot(fixture, name: "Home — system window size")
    }

    func testExpandedGroupDefaultsToControlAllAndCanReselectIt() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let split = try XCTUnwrap(descendant(UISplitViewController.self, in: fixture.host))
        let sidebar = try XCTUnwrap(split.viewController(for: .primary))
        try await selectRow(0, section: 2, in: sidebar)
        let list = try collection(in: sidebar)
        XCTAssertEqual(list.numberOfSections, 2, "Control All and Devices; no inline group controls.")
        XCTAssertTrue(list.indexPathsForSelectedItems?.contains(IndexPath(item: 0, section: 0)) == true)
        XCTAssertTrue(try titles(in: XCTUnwrap(split.viewController(for: .secondary))).contains("Entire Home"))
        snapshot(fixture, name: "Group — expanded Control All")

        try await selectRow(0, section: 1, in: sidebar)
        XCTAssertTrue(try titles(in: XCTUnwrap(split.viewController(for: .secondary))).contains("Desk Lamp"))
        try await selectRow(0, in: sidebar)
        XCTAssertTrue(try titles(in: XCTUnwrap(split.viewController(for: .secondary))).contains("Entire Home"))

        try await selectRow(0, section: 1, in: sidebar)
        let navigation = try XCTUnwrap(descendant(UINavigationController.self, in: sidebar))
        navigation.popViewController(animated: false)
        try await settle()
        try await selectRow(0, section: 2, in: sidebar)
        XCTAssertTrue(try collection(in: sidebar).indexPathsForSelectedItems?.contains(IndexPath(item: 0, section: 0)) == true)
        let writes = await fixture.requests.controlWriteCount
        XCTAssertEqual(writes, 0, "Opening or selecting Control All must never issue a control command.")
    }

    func testCompactGroupKeepsControlsInlineWithoutPushingControlAll() async throws {
        let fixture = try await makeFixture(sizeClass: .compact)
        defer { fixture.close() }
        let split = try XCTUnwrap(descendant(UISplitViewController.self, in: fixture.host))
        try await selectRow(0, section: 2, in: split)
        let navigation = try XCTUnwrap(descendant(UINavigationController.self, in: split))
        XCTAssertTrue(titles(in: navigation).contains("Entire Home"))
        XCTAssertEqual(try collection(in: navigation).numberOfSections, 3, "Inline Controls, Advanced, and Devices.")
        XCTAssertEqual(navigation.viewControllers.count, 2, "Opening a group must not push a separate Control All screen.")
        snapshot(fixture, name: "Group — compact inline controls")
        try await selectRow(0, section: 2, in: navigation)
        XCTAssertTrue(titles(in: navigation).contains("Desk Lamp"))
        navigation.popViewController(animated: false)
        try await settle()
        XCTAssertEqual(try collection(in: navigation).numberOfSections, 3)
        let writes = await fixture.requests.controlWriteCount
        XCTAssertEqual(writes, 0)
    }

    func testGroupControlsMoveInlineOnCollapseAndBackToDetailOnExpansion() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let split = try XCTUnwrap(descendant(UISplitViewController.self, in: fixture.host))
        try await selectRow(0, section: 2, in: XCTUnwrap(split.viewController(for: .primary)))
        XCTAssertTrue(try titles(in: XCTUnwrap(split.viewController(for: .secondary))).contains("Entire Home"))

        fixture.window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        fixture.host.traitOverrides.horizontalSizeClass = .compact
        try await settle()
        XCTAssertTrue(split.isCollapsed)
        XCTAssertTrue(titles(in: split).contains("Entire Home"), titles(in: split).description)
        snapshot(fixture, name: "Group — collapsed presentation")
        XCTAssertEqual(try collection(in: split).numberOfSections, 3)
        XCTAssertEqual(
            try XCTUnwrap(descendant(UINavigationController.self, in: split)).viewControllers.count,
            2,
            "Collapse must pop only Control All, leaving Home and the group list."
        )
        snapshot(fixture, name: "Group — Control All collapsed inline")

        fixture.window.frame = CGRect(x: 0, y: 0, width: 1366, height: 1024)
        fixture.host.traitOverrides.horizontalSizeClass = .regular
        try await settle()
        XCTAssertFalse(split.isCollapsed)
        let sidebar = try XCTUnwrap(split.viewController(for: .primary))
        XCTAssertEqual(try collection(in: sidebar).numberOfSections, 2)
        XCTAssertTrue(try titles(in: XCTUnwrap(split.viewController(for: .secondary))).contains("Entire Home"))

        try await selectRow(0, section: 1, in: sidebar)
        fixture.host.traitOverrides.horizontalSizeClass = .compact
        try await settle()
        XCTAssertTrue(titles(in: split).contains("Desk Lamp"))
        fixture.host.traitOverrides.horizontalSizeClass = .regular
        try await settle()
        XCTAssertTrue(try titles(in: XCTUnwrap(split.viewController(for: .secondary))).contains("Desk Lamp"), "Expanding must preserve an explicitly selected device.")
    }

    func testGroupControlsAtSystemWindowSize() async throws {
        let fixture = try await makeFixture(sizeClass: nil)
        defer { fixture.close() }
        let split = try XCTUnwrap(descendant(UISplitViewController.self, in: fixture.host))
        if !split.isCollapsed {
            split.show(.primary)
            try await settle()
        }
        let sidebar = split.isCollapsed ? split : try XCTUnwrap(split.viewController(for: .primary))
        try await selectRow(0, section: 2, in: sidebar)
        XCTAssertEqual(try collection(in: sidebar).numberOfSections, split.isCollapsed ? 3 : 2)
        if !split.isCollapsed {
            XCTAssertTrue(try titles(in: XCTUnwrap(split.viewController(for: .secondary))).contains("Entire Home"))
        }
        snapshot(fixture, name: "Group — system window size")
    }

    func testControlAllReturnPreservesSidebarHistoryAcrossRepeatedCollapses() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let split = try XCTUnwrap(descendant(UISplitViewController.self, in: fixture.host))
        try await selectRow(0, section: 2, in: XCTUnwrap(split.viewController(for: .primary)))

        for _ in 0..<3 {
            fixture.host.traitOverrides.horizontalSizeClass = .compact
            try await settle()
            let navigation = try XCTUnwrap(descendant(UINavigationController.self, in: split))
            XCTAssertEqual(navigation.viewControllers.count, 2)
            XCTAssertEqual(try collection(in: navigation).numberOfSections, 3)

            fixture.host.traitOverrides.horizontalSizeClass = .regular
            try await settle()
            XCTAssertTrue(try titles(in: XCTUnwrap(split.viewController(for: .secondary))).contains("Entire Home"))
        }

        fixture.host.traitOverrides.horizontalSizeClass = .compact
        try await settle()
        let navigation = try XCTUnwrap(descendant(UINavigationController.self, in: split))
        navigation.popViewController(animated: false)
        try await settle()
        XCTAssertEqual(navigation.viewControllers.count, 1)
        XCTAssertTrue(titles(in: navigation).contains("Home"), "The parent action must preserve the group's own Back history.")
        let writes = await fixture.requests.controlWriteCount
        XCTAssertEqual(writes, 0)
    }

    func testControlAllReturnDoesNotPopPastHomeAfterLeavingGroup() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let split = try XCTUnwrap(descendant(UISplitViewController.self, in: fixture.host))
        let sidebar = try XCTUnwrap(split.viewController(for: .primary))
        try await selectRow(0, section: 2, in: sidebar)
        let navigation = try XCTUnwrap(descendant(UINavigationController.self, in: sidebar))
        navigation.popViewController(animated: false)
        try await settle()
        XCTAssertTrue(titles(in: sidebar).contains("Home"))

        fixture.host.traitOverrides.horizontalSizeClass = .compact
        try await settle()
        let collapsedNavigation = try XCTUnwrap(descendant(UINavigationController.self, in: split))
        XCTAssertEqual(collapsedNavigation.viewControllers.count, 1)
        XCTAssertTrue(titles(in: collapsedNavigation).contains("Home"))
    }

    func testGroupAdvancedDetailSurvivesCollapse() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let split = try XCTUnwrap(descendant(UISplitViewController.self, in: fixture.host))
        try await selectRow(0, section: 2, in: XCTUnwrap(split.viewController(for: .primary)))
        try await selectRow(0, section: 1, in: XCTUnwrap(split.viewController(for: .secondary)))
        XCTAssertTrue(try titles(in: XCTUnwrap(split.viewController(for: .secondary))).contains("all-devices"))

        fixture.host.traitOverrides.horizontalSizeClass = .compact
        try await settle()
        XCTAssertTrue(titles(in: split).contains("all-devices"), "Folding must not dismiss an explicitly opened Advanced screen.")
        let navigation = try XCTUnwrap(descendant(UINavigationController.self, in: split))
        navigation.popViewController(animated: false)
        try await settle()
        XCTAssertTrue(titles(in: split).contains("Entire Home"))
        XCTAssertEqual(navigation.viewControllers.count, 2)
        XCTAssertEqual(try collection(in: navigation).numberOfSections, 3)
    }

    func testScenesAndTriggersUseNavigationStacksAndCameraHasNoNavigationContainer() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let tabs = try XCTUnwrap(descendant(UITabBarController.self, in: fixture.host))
        // SwiftUI supplies UITab models; UIKit need not populate the legacy
        // viewControllers array before their content is selected.
        XCTAssertEqual(tabs.tabs.count, 4)
        XCTAssertEqual(tabs.tabs.map(\.title), ["Home", "Cameras", "Scenes", "Triggers"])

        for (index, title) in [(2, "Scenes"), (3, "Triggers")] {
            let controller = try await selectTab(index, in: tabs)
            XCTAssertNil(descendant(UISplitViewController.self, in: controller), title)
            let navigation = try XCTUnwrap(descendant(UINavigationController.self, in: controller))
            XCTAssertTrue(titles(in: navigation).contains(title))
            snapshot(fixture, name: "\(title) — navigation stack")
        }

        let camera = try await selectTab(1, in: tabs)
        XCTAssertNil(descendant(UISplitViewController.self, in: camera))
        XCTAssertNil(descendant(UINavigationController.self, in: camera))
        snapshot(fixture, name: "Cameras — standalone tab")
    }

    func testGroupsAndHiddenItemsStillSupportDeeperNavigation() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let split = try XCTUnwrap(descendant(UISplitViewController.self, in: fixture.host))
        let sidebar = try XCTUnwrap(split.viewController(for: .primary))
        try await selectRow(0, section: 2, in: sidebar)
        XCTAssertTrue(titles(in: sidebar).contains("Entire Home"))
        try await selectRow(0, section: 1, in: XCTUnwrap(split.viewController(for: .secondary)))
        XCTAssertTrue(try titles(in: XCTUnwrap(split.viewController(for: .secondary))).contains("all-devices"))

        let navigation = try XCTUnwrap(descendant(UINavigationController.self, in: sidebar))
        navigation.popViewController(animated: false)
        try await settle()
        try await selectRow(0, section: 1, in: sidebar)
        try await selectRow(0, section: 1, in: sidebar)
        XCTAssertTrue(titles(in: sidebar).contains("Hidden"))
        try await selectRow(0, in: sidebar)
        let detail = try XCTUnwrap(split.viewController(for: .secondary))
        XCTAssertTrue(titles(in: detail).contains("Hidden Lamp"), titles(in: detail).description)
        XCTAssertTrue(titles(in: sidebar).contains("Hidden"))
    }

    func testTriggerStackSupportsBackAndSelectingAnotherTrigger() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let tabs = try XCTUnwrap(descendant(UITabBarController.self, in: fixture.host))
        let triggers = try await selectTab(3, in: tabs)
        let navigation = try XCTUnwrap(descendant(UINavigationController.self, in: triggers))
        try await selectRow(0, in: navigation)
        XCTAssertTrue(titles(in: navigation).contains("Alpha"))
        navigation.popViewController(animated: false)
        try await settle()
        XCTAssertTrue(titles(in: navigation).contains("Triggers"))
        try await selectRow(1, in: navigation)
        XCTAssertTrue(titles(in: navigation).contains("Beta"))
        let names = await fixture.requests.triggerDetailNames
        XCTAssertTrue(names.contains("Alpha"))
        XCTAssertTrue(names.contains("Beta"), "A new selection must create its own live detail model.")
    }

    private func assertAllDevicesNavigation(sizeClass: UIUserInterfaceSizeClass) async throws {
        let fixture = try await makeFixture(sizeClass: sizeClass)
        defer { fixture.close() }
        let split = try XCTUnwrap(descendant(UISplitViewController.self, in: fixture.host))
        XCTAssertEqual(split.isCollapsed, sizeClass == .compact)
        let sidebar = split.isCollapsed ? split : try XCTUnwrap(split.viewController(for: .primary))
        let navigation = try XCTUnwrap(descendant(UINavigationController.self, in: sidebar))
        XCTAssertEqual(try collection(in: sidebar).numberOfItems(inSection: 0), 1)

        try await selectRow(0, in: sidebar)
        XCTAssertTrue(titles(in: sidebar).contains("All Devices"))
        XCTAssertEqual(navigation.viewControllers.count, 2)
        let list = try collection(in: sidebar)
        XCTAssertEqual(list.numberOfSections, 2, "The complete catalog has Devices and Hidden, without synthetic Control All or Advanced rows.")
        XCTAssertEqual(list.numberOfItems(inSection: 0), 5, "Include physical constituents of device-presenting groups and unassigned devices; keep the hidden device separate.")
        XCTAssertEqual(list.numberOfItems(inSection: 1), 1)
        let initialDetails = await fixture.requests.deviceDetailCount
        let initialSubscriptions = await fixture.requests.activeControlDevices
        XCTAssertEqual(initialDetails, 0, "Opening All Devices must not invent a device-control endpoint.")
        XCTAssertTrue(initialSubscriptions.isEmpty)

        // Camera sorts first. These positions verify display-name ordering while
        // exercising ordinary, grouped, and unassigned physical devices.
        for (row, title, identifier) in [
            (1, "Desk Lamp", "lamp"),
            (2, "Grouped Relay", "grouped-relay"),
            (3, "Unassigned Outlet", "unassigned-outlet"),
            (4, "Workshop Sensor", "sensor")
        ] {
            try await selectRow(row, in: sidebar)
            let detail = split.isCollapsed ? split : try XCTUnwrap(split.viewController(for: .secondary))
            XCTAssertTrue(titles(in: detail).contains(title), titles(in: detail).description)
            let monitoredDevices = await fixture.requests.activeControlDevices
            XCTAssertEqual(monitoredDevices, [identifier], "Selection must monitor the physical device and release the preceding selection.")
            if split.isCollapsed {
                navigation.popViewController(animated: false)
                try await settle()
            }
            XCTAssertTrue(titles(in: sidebar).contains("All Devices"))
            XCTAssertEqual(navigation.viewControllers.count, 2, "Device selection must preserve the catalog's navigation history.")
        }

        try await selectRow(0, section: 1, in: sidebar)
        XCTAssertTrue(titles(in: sidebar).contains("Hidden"))
        try await selectRow(0, in: sidebar)
        let hiddenDetail = split.isCollapsed ? split : try XCTUnwrap(split.viewController(for: .secondary))
        XCTAssertTrue(titles(in: hiddenDetail).contains("Hidden Lamp"))
        let hiddenSubscriptions = await fixture.requests.activeControlDevices
        let subscriptionStarts = await fixture.requests.controlSubscriptionStarts
        let writes = await fixture.requests.controlWriteCount
        XCTAssertEqual(hiddenSubscriptions, ["hidden-lamp"])
        XCTAssertEqual(subscriptionStarts, 5, "Only the five explicitly selected devices should start monitoring.")
        XCTAssertEqual(writes, 0, "Browsing the catalog, hidden items, and device details must not issue control commands.")
        snapshot(fixture, name: "All Devices — \(sizeClass == .compact ? "compact" : "expanded") hidden device")
    }

    private func makeFixture(sizeClass: UIUserInterfaceSizeClass? = .regular, hasControls: Bool = true) async throws -> Fixture {
        let endpoint = try XCTUnwrap(HomeBaseEndpoint(host: "navigation.test.invalid", port: 10503))
        let requests = NavigationFixtureRequests()
        let client = HomeBaseWebSocketClient(endpoint: endpoint, makeControlSocket: { _ in
            NavigationFixtureSocket(requests: requests, hasControls: hasControls)
        })
        let connection = ServerConnectionModel(client: client)
        await connection.load()
        XCTAssertEqual(connection.state, .connected)
        let host = UIHostingController(rootView: ServerDetailView(
            server: PairedServer(endpoint: endpoint),
            connection: connection,
            showServers: {}
        ).environment(\.scenePhase, .active))
        if let sizeClass {
            host.traitOverrides.horizontalSizeClass = sizeClass
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        if let sizeClass {
            window.frame = sizeClass == .compact
                ? CGRect(x: 0, y: 0, width: 390, height: 844)
                : CGRect(x: 0, y: 0, width: 1366, height: 1024)
        }
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        try await settle()
        return Fixture(host: host, window: window, connection: connection, requests: requests)
    }

    private func selectRow(_ row: Int, section: Int = 0, in controller: UIViewController) async throws {
        // Exercises list selection, not SwiftUI's touch/gesture handling.
        // Also verify actual taps and Back in the simulator when changing links.
        let collection = try collection(in: controller)
        let indexPath = IndexPath(item: row, section: section)
        XCTAssertGreaterThan(collection.numberOfItems(inSection: section), row)
        collection.selectItem(at: indexPath, animated: false, scrollPosition: [])
        collection.delegate?.collectionView?(collection, didSelectItemAt: indexPath)
        try await settle()
        // SwiftUI may schedule the push after the selection callback returns.
        // Do not inspect or tap the destination until its real transition ends.
        if let transition = descendant(UINavigationController.self, in: controller)?.transitionCoordinator {
            let completed = expectation(description: "Navigation transition completed")
            transition.animate(alongsideTransition: nil) { _ in completed.fulfill() }
            await fulfillment(of: [completed], timeout: 3)
            try await settle()
        }
    }

    private func collection(in controller: UIViewController) throws -> UICollectionView {
        let visibleController = descendant(UINavigationController.self, in: controller)?.topViewController ?? controller
        return try XCTUnwrap(subview(UICollectionView.self, in: visibleController.view))
    }

    private func selectTab(_ index: Int, in tabs: UITabBarController) async throws -> UIViewController {
        tabs.selectedIndex = index
        let selected = try XCTUnwrap(tabs.selectedViewController)
        tabs.delegate?.tabBarController?(tabs, didSelect: selected)
        try await settle()
        return selected
    }

    private func titles(in controller: UIViewController) -> [String] {
        if let navigation = controller as? UINavigationController {
            return navigation.topViewController.map { titles(in: $0) } ?? []
        }
        return [controller.navigationItem.title].compactMap { $0 }
            + controller.children.flatMap { titles(in: $0) }
    }

    private func descendant<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        (controller as? T) ?? controller.children.compactMap { descendant(type, in: $0) }.first
    }

    private func subview<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        (view as? T) ?? view.subviews.compactMap { subview(type, in: $0) }.first
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(400))
    }

    private func snapshot(_ fixture: Fixture, name: String) {
        let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
            fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private struct Fixture {
        let host: UIViewController
        let window: UIWindow
        let connection: ServerConnectionModel
        let requests: NavigationFixtureRequests

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            connection.disconnect()
        }
    }
}

/// Keeps navigation tests independent of a running engine and real devices.
private nonisolated final class NavigationFixtureSocket: HomeBaseControlSocket, @unchecked Sendable {
    private let inbox = NavigationFixtureInbox()
    private let sessionID = UUID()
    private let requests: NavigationFixtureRequests
    private let hasControls: Bool
    var maximumMessageSize: Int { get { 4 * 1024 * 1024 } set {} }

    init(requests: NavigationFixtureRequests, hasControls: Bool) {
        self.requests = requests
        self.hasControls = hasControls
    }

    func resume() {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { await inbox.cancel() }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw URLError(.badServerResponse)
        }
        let request = try JSONDecoder().decode(HBProtocolEnvelope.self, from: data)
        await requests.recordOperation(request.operation)
        let body: HBProtocolResponse
        switch request.operation {
        case HBProtocolOperations.openSession:
            body = try .success(HBWebSocketSessionOpened(
                sessionID: sessionID, resumeToken: "navigation-fixture", serverInstanceID: UUID(),
                authorization: .administrator,
                limits: .init(resumeWindowSeconds: 60, maximumReplayMessages: 100,
                              maximumReplayBytes: 100000, maximumRequestRecords: 100)
            ))
        case HBProtocolOperations.ping:
            body = .successWithoutResult
        case HBProtocolOperations.acknowledgeSession:
            let ack = try request.decodedPayload(as: HBWebSocketSessionAckRequest.self)
            body = try .success(HBWebSocketSessionAckResult(acknowledgedDeliverySequence: ack.deliverySequence))
        case HBProtocolOperations.listDevices:
            let discovery = try request.decodedPayload(as: HBDeviceListRequest.self)
            let device = try XCTUnwrap(discovery.device)
            body = try .success(HBDeviceListResult(devices: [.init(
                identifier: device, addressableName: device, displayName: device,
                moduleName: "Navigation Fixture", controls: hasControls ? [.init(
                    identifier: "Reading", name: "Reading", kind: "Sensor",
                    value: .string("Live reading"), metadata: ["readable": true, "writable": false]
                )] : []
            )]))
        case HBProtocolOperations.streamControls:
            let watch = try request.decodedPayload(as: HBControlWatchStreamRequest.self)
            let device = try XCTUnwrap(watch.selectors.first?.target)
            let id = UUID()
            await requests.startControlSubscription(id, device: device)
            body = try .success(HBControlWatchStreamAccepted(subscriptionID: id, controls: [.init(
                control: "\(device).Reading", deviceIdentifier: device,
                controlIdentifier: "Reading", displayName: "Reading", kind: "Sensor",
                metadata: ["readable": true, "writable": false]
            )]))
        case HBProtocolOperations.cancelSubscription:
            let cancel = try request.decodedPayload(as: HBSubscriptionCancelRequest.self)
            await requests.cancelControlSubscription(cancel.subscriptionID)
            body = try .success(HBSubscriptionCancelResult(subscriptionID: cancel.subscriptionID))
        case HBProtocolOperations.streamScenes:
            body = try .success(HBSceneWatchStreamAccepted(subscriptionID: UUID(), scenes: [
                .init(name: "Evening", isActive: false)
            ]))
        case HBProtocolOperations.listScenes:
            body = try .success(HBSceneListResult(scenes: []))
        case HBProtocolOperations.streamTriggers:
            let watch = try request.decodedPayload(as: HBTriggerWatchStreamRequest.self)
            await requests.record(watch)
            body = try .success(HBTriggerWatchStreamAccepted(
                subscriptionID: UUID(), scope: watch.scope, detail: watch.detail,
                triggers: (watch.triggers ?? ["Alpha", "Beta"]).map { name in
                    HBTriggerStateResult(trigger: .init(
                        name: name, mode: .trigger, state: .satisfied, schedulerRunning: true
                    ))
                }
            ))
        case HBProtocolOperations.listTopology:
            body = try .success(HBTopologyListResult(
                devices: [
                    .init(identifier: "lamp", addressableName: "lamp", displayName: "Desk Lamp"),
                    .init(identifier: "hidden-lamp", addressableName: "hidden-lamp", displayName: "Hidden Lamp", metadata: ["hidden": true]),
                    .init(identifier: "sensor", addressableName: "sensor", displayName: "Workshop Sensor"),
                    .init(identifier: "camera", addressableName: "camera", displayName: "Camera",
                          metadata: ["cameraLiveVideo": true]),
                    .init(identifier: "unassigned-outlet", addressableName: "unassigned-outlet", displayName: "Unassigned Outlet"),
                    .init(identifier: "grouped-relay", addressableName: "grouped-relay", displayName: "Grouped Relay")
                ],
                rooms: [
                    .init(identifier: "study", displayName: "Study", members: [.init(kind: .device, identifier: "lamp"), .init(kind: .device, identifier: "hidden-lamp")], resolvedDeviceIdentifiers: ["lamp", "hidden-lamp"]),
                    .init(identifier: "workshop", displayName: "Workshop", members: [.init(kind: .device, identifier: "sensor"), .init(kind: .device, identifier: "camera")], resolvedDeviceIdentifiers: ["sensor", "camera"])
                ],
                groups: [
                    .init(
                        identifier: "all-devices", displayName: "Entire Home", origin: .configured,
                        role: .general, members: [.init(kind: .device, identifier: "lamp"), .init(kind: .device, identifier: "sensor")],
                        resolvedDeviceIdentifiers: ["lamp", "sensor"], controlDeviceIdentifier: "all-devices"
                    ),
                    .init(
                        identifier: "relay-group", displayName: "Relay Assembly", origin: .configured,
                        role: .general, members: [.init(kind: .device, identifier: "grouped-relay")],
                        resolvedDeviceIdentifiers: ["grouped-relay"], controlDeviceIdentifier: "relay-group",
                        metadata: ["presentationDisposition": "device"]
                    )
                ]
            ))
        default:
            body = .failure(.init(code: "test_fixture", message: "No live controls in navigation fixture."))
        }
        var response = try HBProtocolEnvelope.response(to: request, body: body)
        response.sessionID = sessionID
        if request.operation == HBProtocolOperations.listDevices {
            response.deliverySequence = await inbox.nextDeliverySequence()
        }
        await inbox.push(.data(try JSONEncoder().encode(response)))
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await inbox.receive()
    }
}

private actor NavigationFixtureRequests {
    private(set) var deviceDetailCount = 0
    private var controlSubscriptions: [UUID: String] = [:]
    var activeControlDevices: [String] { controlSubscriptions.values.sorted() }
    var activeControlSubscriptionIDs: Set<UUID> { Set(controlSubscriptions.keys) }
    private(set) var controlSubscriptionStarts = 0

    func startControlSubscription(_ id: UUID, device: String) {
        controlSubscriptionStarts += 1
        controlSubscriptions[id] = device
    }

    func cancelControlSubscription(_ id: UUID) {
        controlSubscriptions.removeValue(forKey: id)
    }
    private(set) var triggerDetailNames: Set<String> = []
    private(set) var controlWriteCount = 0

    func recordOperation(_ operation: String) {
        if operation == HBProtocolOperations.listDevices { deviceDetailCount += 1 }
        if operation == HBProtocolOperations.setControl {
            controlWriteCount += 1
        }
    }

    func record(_ request: HBTriggerWatchStreamRequest) {
        if request.scope == .triggers {
            triggerDetailNames.formUnion(request.triggers ?? [])
        }
    }
}

private actor NavigationFixtureInbox {
    private var deliverySequence: Int64 = 0

    func nextDeliverySequence() -> Int64 {
        deliverySequence += 1
        return deliverySequence
    }
    private var messages: [URLSessionWebSocketTask.Message] = []
    private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var cancelled = false

    func push(_ message: URLSessionWebSocketTask.Message) {
        guard !cancelled else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
        } else {
            messages.append(message)
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        if cancelled { throw URLError(.cancelled) }
        if !messages.isEmpty { return messages.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func cancel() {
        cancelled = true
        waiter?.resume(throwing: URLError(.cancelled))
        waiter = nil
        messages.removeAll()
    }
}
#endif
