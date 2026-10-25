#if os(iOS)
import Combine
import SwiftUI
import UIKit
import XCTest
@testable import HomeBase_GUI

/// Uses the native tab/split/list controllers so a sidebar-local badge or a
/// guessed tab-bar height cannot pass merely because a SwiftUI preview looks right.
@MainActor
final class ConnectionStatusLayoutTests: XCTestCase {
    func testPortraitBadgeIsUniqueCenteredAndLeavesLastRowReachable() async throws {
        let fixture = try await makeFixture(orientation: .portrait, horizontal: .compact)
        try await verifyLayout(fixture, minimumVisibleLists: 1)
        snapshot(fixture, name: "Connection badge — portrait")
    }

    func testLandscapeSplitBadgeCentersAcrossBothColumnsAndClearsBothLists() async throws {
        let fixture = try await makeFixture(orientation: .landscapeRight, horizontal: .regular)
        let split = try XCTUnwrap(descendant(UISplitViewController.self, in: fixture.host))
        XCTAssertFalse(split.isCollapsed, "The fixture must exercise both columns, not a collapsed navigation stack.")
        try await verifyLayout(fixture, minimumVisibleLists: 2)
        snapshot(fixture, name: "Connection badge — landscape split")
    }

    func testRotationAndStatusChangesKeepOneBadgeAboveTheNativeBar() async throws {
        let fixture = try await makeFixture(orientation: .portrait, horizontal: .compact)
        try await verifyLayout(fixture, minimumVisibleLists: 1)
        fixture.controller.updateConnection(presentation: .pending("Restoring the connection"), route: .bluetooth)
        try await fixture.rotate(to: .landscapeRight, horizontal: .regular)
        try await settle(fixture)
        try await verifyLayout(fixture, minimumVisibleLists: 2)
        snapshot(fixture, name: "Connection badge — rotated pending")
        let pendingHeight = try XCTUnwrap(badgeFrames(in: fixture.window).first).height
        fixture.controller.updateConnection(
            presentation: .failed(title: "Connection interrupted",
                                  message: "The controller stopped responding.\nTry the connection again."),
            route: .bluetooth,
            retry: {})
        try await settle(fixture)
        let errorHeight = try XCTUnwrap(badgeFrames(in: fixture.window).first).height
        XCTAssertGreaterThan(errorHeight, pendingHeight + 10,
                             "This state must exercise clearance for a taller, measured badge.")
        try await verifyLayout(fixture, minimumVisibleLists: 2)
        snapshot(fixture, name: "Connection badge — landscape error with retry")
        fixture.controller.updateConnection(presentation: .connected, route: .webSocket)
        try await fixture.rotate(to: .portrait, horizontal: .compact)
        try await settle(fixture)
        try await verifyLayout(fixture, minimumVisibleLists: 1)
        snapshot(fixture, name: "Connection badge — portrait restored")
    }

    func testVisibleReportsFollowScopeAndViewLifetimeWhileDisabledScopeStaysOut() async throws {
        let controller = ConnectionStatusController()
        controller.updateConnection(presentation: .connected, route: .webSocket)
        let model = ConnectionStatusReportLifecycleModel()
        let fixture = try await makeFixture(orientation: .portrait, horizontal: .compact,
                                            controller: controller,
                                            content: AnyView(ConnectionStatusReportLifecycleView(model: model)))
        XCTAssertEqual(controller.visibleReportCount, 2, "A disabled scope must never publish its child error.")
        XCTAssertEqual(controller.presentation, .failed(title: "Visible failure", message: "A visible subscription failed."))

        model.failedScopeActive = false
        try await settle(fixture)
        XCTAssertEqual(controller.visibleReportCount, 1)
        XCTAssertEqual(controller.presentation, .connected, "An inactive tab or column must release its failure report.")

        model.failedScopeActive = true
        try await settle(fixture)
        XCTAssertEqual(controller.visibleReportCount, 2)
        XCTAssertEqual(controller.presentation, .failed(title: "Visible failure", message: "A visible subscription failed."))

        model.showsFailedReport = false
        try await settle(fixture)
        XCTAssertEqual(controller.visibleReportCount, 1)
        XCTAssertEqual(controller.presentation, .connected, "Removing a reporting view must release its failure.")

        model.showsConnectedReport = false
        try await settle(fixture)
        XCTAssertEqual(controller.visibleReportCount, 0)
        XCTAssertEqual(controller.presentation, .connected, "The transport remains authoritative after all screen reports disappear.")
    }

    private func makeFixture(orientation: UIInterfaceOrientation,
                             horizontal: UIUserInterfaceSizeClass,
                             controller suppliedController: ConnectionStatusController? = nil,
                             content: AnyView? = nil) async throws -> Fixture {
        let controller = suppliedController ?? ConnectionStatusController()
        if suppliedController == nil {
            controller.updateConnection(presentation: .connected, route: .bluetooth)
        }
        let host = ConnectionStatusLayoutHostingController(rootView: AnyView(
            (content ?? AnyView(ConnectionStatusLayoutTabs())).connectionStatusHost(controller)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        let fixture = Fixture(host: host, window: window, controller: controller,
                              previousKeyWindow: previousKeyWindow)
        addTeardownBlock { @MainActor in try await fixture.close() }
        window.makeKeyAndVisible()
        try await fixture.rotate(to: orientation, horizontal: horizontal)
        try await settle(fixture)
        return fixture
    }

    private func verifyLayout(_ fixture: Fixture, minimumVisibleLists: Int,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        defer { snapshot(fixture, name: "Connection layout \(Int(fixture.window.bounds.width))×\(Int(fixture.window.bounds.height))") }
        let tabs = try XCTUnwrap(descendant(UITabBarController.self, in: fixture.host), file: file, line: line)
        XCTAssertFalse(tabs.tabBar.isHidden, file: file, line: line)
        let bar = tabs.tabBar.convert(tabs.tabBar.bounds, to: fixture.window)
        XCTAssertGreaterThan(bar.height, 0, file: file, line: line)
        let frames = badgeFrames(in: fixture.window)
        XCTAssertEqual(frames.count, 1, "Only the root host renders connection status, even with two reporting columns.", file: file, line: line)
        let badge = try XCTUnwrap(frames.first, file: file, line: line)
        XCTAssertGreaterThan(badge.height, 0, file: file, line: line)
        XCTAssertEqual(badge.midX, fixture.window.bounds.midX, accuracy: 2,
                       "The badge must center on the whole window, not the sidebar.", file: file, line: line)
        XCTAssertLessThanOrEqual(badge.maxY, bar.minY + 1,
                                "The badge must stay above the actual native tab bar.", file: file, line: line)
        XCTAssertLessThan(bar.minY - badge.maxY, 40,
                          "The badge should follow the tab bar, not float far above it.", file: file, line: line)
        let lists = subviews(UICollectionView.self, in: tabs.selectedViewController?.view ?? tabs.view).filter {
            !$0.isHidden && $0.alpha > 0 && $0.window === fixture.window &&
                $0.convert($0.bounds, to: fixture.window).intersection(fixture.window.bounds).width > 20 &&
                $0.numberOfSections > 0 && $0.numberOfItems(inSection: 0) == ConnectionStatusLayoutList.rowCount
        }
        XCTAssertGreaterThanOrEqual(lists.count, minimumVisibleLists, file: file, line: line)
        let lastIndex = IndexPath(item: ConnectionStatusLayoutList.rowCount - 1, section: 0)
        var diagnostics = ["window=\(fixture.window.bounds) bar=\(bar) badge=\(badge)"]
        func describe(_ list: UICollectionView, phase: String) -> String {
            let attributes = list.layoutAttributesForItem(at: lastIndex)?.frame
            let row = attributes.map { list.convert($0, to: fixture.window) }
            return "\(phase): viewport=\(list.convert(list.bounds, to: fixture.window)) bounds=\(list.bounds) contentSize=\(list.contentSize) layoutSize=\(list.collectionViewLayout.collectionViewContentSize) contentInset=\(list.contentInset) adjustedInset=\(list.adjustedContentInset) offset=\(list.contentOffset) lastAttributes=\(String(describing: attributes)) lastWindowFrame=\(String(describing: row)) lastCell=\(String(describing: list.cellForItem(at: lastIndex)?.frame))"
        }
        for (number, list) in lists.enumerated() {
            let viewport = list.convert(list.bounds, to: fixture.window)
            XCTAssertGreaterThan(viewport.maxY, badge.minY,
                                 "Rows should scroll behind the floating badge; do not truncate the list at the badge.", file: file, line: line)
            diagnostics.append(describe(list, phase: "list\(number) before"))
            // Ask UIKit to realize the terminal self-sizing cell before using
            // contentSize; a distant row's initial height is only an estimate.
            list.scrollToItem(at: lastIndex, at: .bottom, animated: false)
        }
        try await settle(fixture)
        for pass in 0..<4 {
            let previousSizes = lists.map(\.contentSize)
            for (number, list) in lists.enumerated() {
                diagnostics.append(describe(list, phase: "list\(number) pass\(pass) before"))
                let offset = max(-list.adjustedContentInset.top,
                                 list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
                list.setContentOffset(CGPoint(x: list.contentOffset.x, y: offset), animated: false)
            }
            try await settle(fixture)
            let stable = zip(lists, previousSizes).allSatisfy { list, size in
                let end = max(-list.adjustedContentInset.top,
                              list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
                return abs(list.contentSize.height - size.height) < 0.5 && abs(list.contentOffset.y - end) < 0.5
            }
            if stable { break }
        }
        let finalBadge = try XCTUnwrap(badgeFrames(in: fixture.window).first, file: file, line: line)
        for (number, list) in lists.enumerated() {
            diagnostics.append(describe(list, phase: "list\(number) final"))
            let attributes = try XCTUnwrap(list.layoutAttributesForItem(at: lastIndex), file: file, line: line)
            XCTAssertNotNil(list.cellForItem(at: lastIndex), "The final row must actually be realized, not estimated below the viewport.", file: file, line: line)
            let row = list.convert(attributes.frame, to: fixture.window)
            XCTAssertLessThanOrEqual(row.maxY, finalBadge.minY + 1,
                                     "The last row must scroll fully clear of the measured badge in every visible column.", file: file, line: line)
        }
        let detail = diagnostics.joined(separator: "\n")
        print("Connection layout diagnostics:\n" + detail)
        let attachment = XCTAttachment(string: detail)
        attachment.name = "Connection list geometry"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func badgeFrames(in window: UIWindow) -> [CGRect] {
        // The production host includes an inert UIKit bounds marker; measuring
        // its real frame is independent of the host's own positioning arithmetic.
        func markers(in view: UIView) -> [UIView] {
            guard !view.isHidden, view.alpha > 0 else { return [] }
            if view.accessibilityIdentifier == "connection-status-bounds" { return [view] }
            return view.subviews.flatMap { markers(in: $0) }
        }
        let measured = markers(in: window).map { $0.convert($0.bounds, to: window) }
            .filter { !$0.isEmpty && $0.intersects(window.bounds) }
        if !measured.isEmpty { return measured }
        var visited: Set<ObjectIdentifier> = []
        var frames: [CGRect] = []
        func walk(_ object: NSObject, depth: Int) {
            guard depth < 40, visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? UIView, view.isHidden || view.alpha == 0 { return }
            if (object as? UIAccessibilityIdentification)?.accessibilityIdentifier == "connection-status" {
                let frame: CGRect
                if let view = object as? UIView {
                    frame = view.convert(view.bounds, to: window)
                } else {
                    frame = window.convert(object.accessibilityFrame, from: window.screen.coordinateSpace)
                }
                if !frame.isEmpty, frame.intersects(window.bounds),
                   !frames.contains(where: { abs($0.minX - frame.minX) < 0.5 && abs($0.minY - frame.minY) < 0.5 && abs($0.width - frame.width) < 0.5 && abs($0.height - frame.height) < 0.5 }) {
                    frames.append(frame)
                }
                return
            }
            if let view = object as? UIView { for child in view.subviews { walk(child, depth: depth + 1) } }
            if let elements = object.accessibilityElements {
                for case let element as NSObject in elements { walk(element, depth: depth + 1) }
            } else {
                let count = object.accessibilityElementCount()
                if count > 0, count < 1_000 {
                    for index in 0..<count {
                        if let element = object.accessibilityElement(at: index) as? NSObject { walk(element, depth: depth + 1) }
                    }
                }
            }
        }
        walk(window, depth: 0)
        return frames
    }

    private func descendant<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        (controller as? T) ?? controller.children.lazy.compactMap { self.descendant(type, in: $0) }.first
    }

    private func subviews<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { subviews(type, in: $0) }
    }

    private func settle(_ fixture: Fixture) async throws {
        fixture.host.view.setNeedsLayout()
        fixture.host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        fixture.host.view.layoutIfNeeded()
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
        let host: ConnectionStatusLayoutHostingController
        let window: UIWindow
        let controller: ConnectionStatusController
        let previousKeyWindow: UIWindow?

        func rotate(to orientation: UIInterfaceOrientation, horizontal: UIUserInterfaceSizeClass) async throws {
            let scene = try XCTUnwrap(window.windowScene)
            host.traitOverrides.horizontalSizeClass = horizontal
            host.traitOverrides.verticalSizeClass = orientation.isLandscape ? .compact : .regular
            host.setNeedsUpdateOfSupportedInterfaceOrientations()
            let mask: UIInterfaceOrientationMask = orientation == .portrait ? .portrait : .landscapeRight
            var requestError: Error?
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { requestError = $0 }
            for _ in 0..<50 {
                if let requestError { throw requestError }
                let geometry = scene.effectiveGeometry
                let bounds = geometry.coordinateSpace.bounds
                if geometry.interfaceOrientation == orientation,
                   (bounds.width > bounds.height) == orientation.isLandscape {
                    // Use the real scene geometry: an oversized synthetic window
                    // clips native glass to the physical screen in snapshots.
                    window.frame = bounds
                    window.layoutIfNeeded()
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw NSError(domain: "ConnectionStatusLayoutTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The test scene did not rotate to \(orientation.rawValue)."])
        }

        func close() async throws {
            defer {
                host.rootView = AnyView(Color.clear)
                window.isHidden = true
                window.rootViewController = nil
                previousKeyWindow?.makeKeyAndVisible()
            }
            try await rotate(to: .portrait, horizontal: .compact)
        }
    }
}

@MainActor
private final class ConnectionStatusLayoutHostingController: UIHostingController<AnyView> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var shouldAutorotate: Bool { true }
}

@MainActor
private final class ConnectionStatusReportLifecycleModel: ObservableObject {
    @Published var failedScopeActive = true
    @Published var showsFailedReport = true
    @Published var showsConnectedReport = true
    // Match the repository's iOS XCTest teardown convention.
    nonisolated deinit {}
}

private struct ConnectionStatusReportLifecycleView: View {
    @ObservedObject var model: ConnectionStatusReportLifecycleModel
    var body: some View {
        VStack {
            if model.showsConnectedReport {
                Text("Visible healthy screen").connectionStatusReport(.connected)
            }
            if model.showsFailedReport {
                Text("Visible failed screen")
                    .connectionStatusReport(.failed(title: "Visible failure", message: "A visible subscription failed."))
                    .connectionStatusScope(isActive: model.failedScopeActive)
            }
            Text("Independent sheet")
                .connectionStatusReport(.failed(title: "Disabled failure", message: "This must remain outside the server badge."))
                .connectionStatusScopeDisabled()
        }
    }
}

private struct ConnectionStatusLayoutTabs: View {
    @State private var selected = 0
    var body: some View {
        TabView(selection: $selected) {
            NavigationSplitView(columnVisibility: .constant(.all), preferredCompactColumn: .constant(.sidebar)) {
                ConnectionStatusLayoutList(title: "Home")
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 300)
            } detail: {
                ConnectionStatusLayoutList(title: "Device controls")
            }
            .navigationSplitViewStyle(.balanced)
            .connectionStatusScope(isActive: selected == 0)
            .tabItem { Label("Home", systemImage: "house") }.tag(0)
            NavigationStack {
                ConnectionStatusLayoutList(title: "Scenes")
            }
            .connectionStatusScope(isActive: selected == 1)
            .tabItem { Label("Scenes", systemImage: "sparkles") }.tag(1)
        }
    }
}

private struct ConnectionStatusLayoutList: View {
    static let rowCount = 36
    let title: String
    var body: some View {
        List(0..<Self.rowCount, id: \.self) { index in
            Text(index == Self.rowCount - 1 ? "Last \(title) row" : "\(title) row \(index + 1)")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .navigationTitle(title)
        .connectionStatusReport(.connected)
        .connectionStatusClearance()
    }
}
#endif
