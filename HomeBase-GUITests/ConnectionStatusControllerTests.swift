import XCTest
@testable import HomeBase_GUI

@MainActor
final class ConnectionStatusControllerTests: XCTestCase {
    func testLiveScreensCoalesceAndRouteChangesKeepOneConnectedState() {
        let controller = ConnectionStatusController()
        controller.updateConnection(presentation: .connected, route: .webSocket)
        controller.update(UUID(), presentation: .connected)
        controller.update(UUID(), presentation: .connected)
        XCTAssertEqual(controller.visibleReportCount, 2)
        XCTAssertEqual(controller.presentation, .connected)
        controller.updateConnection(presentation: .connected, route: .bluetooth)
        XCTAssertEqual(controller.presentation, .connected)
        XCTAssertEqual(controller.route, .bluetooth)
    }

    func testLostTransportCannotBeHiddenByLiveScreens() {
        let controller = ConnectionStatusController()
        controller.update(UUID(), presentation: .connected)
        controller.updateConnection(presentation: .pending("Reconnecting…"), route: nil)
        XCTAssertEqual(controller.presentation, .pending("Reconnecting…"))
        let failure = ConnectionStatusPresentation.failed(title: "Connection Failed", message: "Unavailable")
        controller.updateConnection(presentation: failure, route: nil)
        XCTAssertEqual(controller.presentation, failure)
    }

    func testLoadingScreenKeepsActualBluetoothRouteForPendingIndicator() {
        let controller = ConnectionStatusController()
        controller.updateConnection(presentation: .connected, route: .bluetooth)
        let source = UUID()
        controller.update(source, presentation: .pending("Loading controls…"))
        XCTAssertEqual(controller.presentation, .pending("Loading controls…"))
        XCTAssertEqual(controller.route, .bluetooth)
        controller.update(source, presentation: .connected)
        XCTAssertEqual(controller.presentation, .connected)
    }

    func testRemovingCoveredOrClosedScreenClearsItsFailureAndRetry() {
        let controller = ConnectionStatusController()
        controller.updateConnection(presentation: .connected, route: .webSocket)
        let source = UUID()
        controller.update(source, presentation: .failed(title: "Monitoring Failed", message: "Stopped"), retry: {})
        XCTAssertTrue(controller.canRetry)
        controller.remove(source)
        XCTAssertEqual(controller.visibleReportCount, 0)
        XCTAssertEqual(controller.presentation, .connected)
        XCTAssertFalse(controller.canRetry)
    }

    func testIdleScreenDoesNotMakeHealthyConnectionAppearDisconnected() {
        let controller = ConnectionStatusController()
        controller.updateConnection(presentation: .connected, route: .webSocket)
        controller.update(UUID(), presentation: .disconnected("Not Monitoring", systemImage: "pause.circle"))
        XCTAssertEqual(controller.presentation, .connected)
    }

    func testRetryIncludesEachFailedVisibleScreenOnceAndDropsClosedOnes() {
        let controller = ConnectionStatusController()
        controller.updateConnection(presentation: .connected, route: .webSocket)
        let first = UUID(), second = UUID()
        var firstRetries = 0, secondRetries = 0
        let failure = ConnectionStatusPresentation.failed(title: "Monitoring Failed", message: "Stopped")
        controller.update(first, presentation: failure, retry: { firstRetries += 1 })
        controller.update(first, presentation: failure, retry: { firstRetries += 1 })
        controller.update(second, presentation: failure, retry: { secondRetries += 1 })
        controller.retry()
        XCTAssertEqual(firstRetries, 1)
        XCTAssertEqual(secondRetries, 1)
        controller.remove(first)
        controller.retry()
        XCTAssertEqual(firstRetries, 1)
        XCTAssertEqual(secondRetries, 2)
    }

    func testUnrelatedUpdatesDoNotChangeWhichFailureIsPresented() {
        let controller = ConnectionStatusController()
        controller.updateConnection(presentation: .connected, route: .webSocket)
        let first = UUID(), second = UUID()
        let failure = ConnectionStatusPresentation.failed(title: "First", message: "One")
        controller.update(first, presentation: failure)
        controller.update(second, presentation: .failed(title: "Second", message: "Two"))
        controller.update(first, presentation: failure)
        XCTAssertEqual(controller.presentation, failure)
        controller.update(first, presentation: nil)
        XCTAssertEqual(controller.presentation, .failed(title: "Second", message: "Two"))
    }
}
