import XCTest
@testable import HomeBase_GUI

@MainActor
final class LiveMonitoringSessionTests: XCTestCase {
    func testRepeatedActivationKeepsTheSameMonitoringRun() async {
        let probe = Probe()
        let started = expectation(description: "Monitoring started")
        let stopped = expectation(description: "Monitoring stopped")
        probe.onStart = { started.fulfill() }
        probe.onStop = { stopped.fulfill() }
        let session = LiveMonitoringSession()
        activate(session, probe: probe)
        await fulfillment(of: [started], timeout: 1)

        // A compact split can deliver initial onChange more than once while
        // moving the same screen. Neither activation may retire its stream.
        activate(session, probe: probe)
        activate(session, probe: probe)
        await Task.yield()
        XCTAssertEqual(probe.starts, 1)
        XCTAssertEqual(probe.cancellations, 0)
        session.setActive(false, operation: { await probe.run() })
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertEqual(probe.cancellations, 1)
    }

    func testReleasingScreenOwnershipCancelsAndCleansUp() async {
        let probe = Probe()
        let started = expectation(description: "Monitoring started")
        let stopped = expectation(description: "Owner released its subscription")
        probe.onStart = { started.fulfill() }
        probe.onStop = { stopped.fulfill() }
        var session: LiveMonitoringSession? = LiveMonitoringSession()
        weak var releasedSession = session
        activate(session!, probe: probe)
        await fulfillment(of: [started], timeout: 1)
        session = nil
        XCTAssertNil(releasedSession, "The running operation must not retain its owner.")
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertEqual(probe.cancellations, 1)
    }

    func testForegroundWaitsForBackgroundCleanup() async {
        let probe = Probe()
        let started = expectation(description: "First run started")
        let cancelling = expectation(description: "First run cancelling")
        let resumed = expectation(description: "Foreground monitoring started")
        let stopped = expectation(description: "Foreground monitoring stopped")
        probe.holdFirstCleanup = true
        probe.onStart = { (probe.starts == 1 ? started : resumed).fulfill() }
        probe.onCancel = { if probe.cancellations == 1 { cancelling.fulfill() } }
        probe.onStop = { if probe.cancellations == 2 { stopped.fulfill() } }
        let session = LiveMonitoringSession()
        activate(session, probe: probe)
        await fulfillment(of: [started], timeout: 1)
        session.setActive(false, operation: { await probe.run() })
        activate(session, probe: probe)
        await fulfillment(of: [cancelling], timeout: 1)
        XCTAssertEqual(probe.starts, 1, "A new run cannot overlap cleanup of the old one.")
        probe.cleanup?.resume()
        probe.cleanup = nil
        await fulfillment(of: [resumed], timeout: 1)
        XCTAssertEqual(probe.starts, 2)
        session.setActive(false, operation: { await probe.run() })
        await fulfillment(of: [stopped], timeout: 1)
    }

    func testExplicitRetryReplacesTheSubscription() async {
        let probe = Probe()
        let started = expectation(description: "First run started")
        let retried = expectation(description: "Explicit retry started")
        probe.onStart = { (probe.starts == 1 ? started : retried).fulfill() }
        let session = LiveMonitoringSession()
        activate(session, probe: probe)
        await fulfillment(of: [started], timeout: 1)
        session.restart()
        await fulfillment(of: [retried], timeout: 1)
        XCTAssertEqual(probe.cancellations, 1)
        XCTAssertEqual(probe.starts, 2)
    }

    private func activate(_ session: LiveMonitoringSession, probe: Probe) {
        session.setActive(true, operation: { await probe.run() })
    }

    private final class Probe {
        var starts = 0
        var cancellations = 0
        var onStart: () -> Void = {}
        var onCancel: () -> Void = {}
        var onStop: () -> Void = {}
        var holdFirstCleanup = false
        var cleanup: CheckedContinuation<Void, Never>?

        func run() async {
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            starts += 1
            onStart()
            for await _ in stream {}
            cancellations += 1
            if holdFirstCleanup && cancellations == 1 {
                await withCheckedContinuation { cleanup = $0; onCancel() }
            } else {
                onCancel()
            }
            onStop()
        }
    }
}
