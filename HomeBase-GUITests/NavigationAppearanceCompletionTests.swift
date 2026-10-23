#if os(iOS)
import HomeBaseProtocol
import SwiftUI
import UIKit
import XCTest
@testable import HomeBase_GUI

@MainActor
final class NavigationAppearanceCompletionTests: XCTestCase {
    func testNonAnimatedPushSelectsControlAllAfterAppearing() async throws {
        var selection: TopologyDetailDestination?
        let selected = expectation(description: "Nonanimated appearance selects Control All")
        let fixture = try await makeFixture(selection: Binding(
            get: { selection },
            set: { value in
                selection = value
                selected.fulfill()
            }
        ))
        defer { fixture.close() }

        fixture.navigation.pushViewController(fixture.group, animated: false)
        await fulfillment(of: [selected], timeout: 3)
        XCTAssertEqual(selection, .groupControls("group-controls"))
    }

    func testControlAllSelectionWaitsUntilThePushCompletes() async throws {
        var selection: TopologyDetailDestination? = .device("previous-device")
        var transitionCompleted = false
        let selected = expectation(description: "Control All selected after appearance")
        let prematureSelection = expectation(description: "No selection during the push")
        prematureSelection.isInverted = true
        let fixture = try await makeFixture(selection: Binding(
            get: { selection },
            set: { value in
                selection = value
                if transitionCompleted {
                    selected.fulfill()
                } else {
                    prematureSelection.fulfill()
                }
            }
        ))
        defer { fixture.close() }

        fixture.navigation.pushViewController(fixture.group, animated: true)
        await fulfillment(of: [fixture.transition.started], timeout: 3)
        await fulfillment(of: [prematureSelection], timeout: 0.1)
        XCTAssertEqual(selection, .device("previous-device"))

        transitionCompleted = true
        fixture.transition.complete(true)
        await fulfillment(of: [selected], timeout: 3)
        XCTAssertEqual(selection, .groupControls("group-controls"))
        XCTAssertTrue(fixture.navigation.topViewController === fixture.group)
    }

    func testCancelledPushDoesNotSelectControlAll() async throws {
        var selection: TopologyDetailDestination? = .device("previous-device")
        let selectionChanged = expectation(description: "A cancelled appearance must not change selection")
        selectionChanged.isInverted = true
        let fixture = try await makeFixture(selection: Binding(
            get: { selection },
            set: { value in
                selection = value
                selectionChanged.fulfill()
            }
        ))
        defer { fixture.close() }

        fixture.navigation.pushViewController(fixture.group, animated: true)
        await fulfillment(of: [fixture.transition.started], timeout: 3)
        fixture.transition.complete(false)
        await fulfillment(of: [selectionChanged], timeout: 0.2)
        XCTAssertEqual(selection, .device("previous-device"))
        XCTAssertEqual(fixture.navigation.viewControllers.count, 1)
    }

    private func makeFixture(selection: Binding<TopologyDetailDestination?>) async throws -> Fixture {
        let endpoint = try XCTUnwrap(HomeBaseEndpoint(host: "appearance.test.invalid", port: 10503))
        let group = HBTopologyGroupDescriptor(
            identifier: "group", displayName: "Group", origin: .configured,
            role: .general, members: [], resolvedDeviceIdentifiers: [],
            controlDeviceIdentifier: "group-controls"
        )
        let topology = HBTopologyListResult(devices: [], rooms: [], groups: [group])
        let host = UIHostingController(rootView: GroupDetailView(
            group: group, topology: topology,
            client: HomeBaseWebSocketClient(endpoint: endpoint), selection: selection
        ).environment(\.homeSplitViewLayout, .expanded))
        let navigation = UINavigationController(rootViewController: UIViewController())
        let transition = HeldPushTransition()
        navigation.delegate = transition
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = navigation
        window.isHidden = false
        navigation.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        return Fixture(window: window, navigation: navigation, group: host, transition: transition)
    }

    private struct Fixture {
        let window: UIWindow
        let navigation: UINavigationController
        let group: UIViewController
        let transition: HeldPushTransition

        func close() {
            transition.complete(false)
            window.isHidden = true
            window.rootViewController = nil
        }
    }
}

/// Holds a real navigation appearance open until the test explicitly completes
/// or cancels it, so the test does not depend on the system animation duration.
@MainActor
private final class HeldPushTransition: NSObject, UINavigationControllerDelegate, UIViewControllerAnimatedTransitioning {
    let started = XCTestExpectation(description: "Push transition started")
    private var context: (any UIViewControllerContextTransitioning)?

    func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        operation == .push ? self : nil
    }

    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        1
    }

    func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
        context = transitionContext
        if let destination = transitionContext.viewController(forKey: .to) {
            destination.view.frame = transitionContext.finalFrame(for: destination)
            transitionContext.containerView.addSubview(destination.view)
        }
        started.fulfill()
    }

    func complete(_ completed: Bool) {
        guard let context else { return }
        self.context = nil
        if !completed {
            context.view(forKey: .to)?.removeFromSuperview()
        }
        context.completeTransition(completed)
    }
}
#endif
