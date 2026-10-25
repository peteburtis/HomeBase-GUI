import Foundation
import XCTest
@testable import HomeBase_GUI

@MainActor
final class ConnectionStatusForegroundRecoveryTests: XCTestCase {
    private let connecting = ConnectionStatusPresentation.pending("Connecting…")
    private let failure = ConnectionStatusPresentation.failed(title: "Connection Failed", message: "Unavailable")

    func testInitialActiveStateShowsErrorsWithoutStartingARecoveryWindow() async {
        let gate = ForegroundRecoveryDelayGate()
        defer { gate.finishAll() }
        let controller = ConnectionStatusController(foregroundRecoveryDelay: { try await gate.wait() })
        var retries = 0
        controller.updateConnection(presentation: failure, route: .bluetooth, retry: { retries += 1 })
        controller.setActive(true)
        XCTAssertEqual(controller.presentation, failure)
        XCTAssertEqual(controller.route, .bluetooth)
        XCTAssertTrue(controller.canRetry)
        controller.retry()
        XCTAssertEqual(retries, 1)
        XCTAssertEqual(gate.startedCount, 0)
    }

    func testInactiveStateSuppressesEveryPresentationAndRetainsUpdatedRouteAndReports() {
        let gate = ForegroundRecoveryDelayGate()
        defer { gate.finishAll() }
        let controller = ConnectionStatusController(foregroundRecoveryDelay: { try await gate.wait() })
        let report = UUID()
        var retries = 0
        controller.updateConnection(presentation: .connected, route: .webSocket)
        controller.setActive(false)
        XCTAssertEqual(controller.presentation, connecting)
        controller.update(report, presentation: failure, retry: { retries += 1 })
        controller.updateConnection(presentation: failure, route: .bluetooth, retry: { retries += 1 })
        XCTAssertEqual(controller.presentation, connecting)
        XCTAssertEqual(controller.route, .bluetooth)
        XCTAssertEqual(controller.visibleReportCount, 1)
        XCTAssertFalse(controller.canRetry)
        controller.retry()
        XCTAssertEqual(retries, 0)
        controller.updateConnection(presentation: .pending("Loading session…"), route: .webSocket)
        XCTAssertEqual(controller.presentation, connecting)
        controller.update(report, presentation: .connected)
        controller.updateConnection(presentation: .connected, route: .bluetooth)
        XCTAssertEqual(controller.presentation, connecting, "Even a stale connected update must not present an inactive scene as recovered.")
        XCTAssertEqual(gate.startedCount, 0)
    }

    func testFixedGraceRevealsLatestFailureAndRetryWithoutAnotherTransportUpdate() async {
        let gate = ForegroundRecoveryDelayGate()
        defer { gate.finishAll() }
        let controller = ConnectionStatusController(foregroundRecoveryDelay: { try await gate.wait() })
        var oldRetries = 0, currentRetries = 0, screenRetries = 0, removedRetries = 0
        let screen = UUID(), removedScreen = UUID()
        controller.updateConnection(presentation: failure, route: .webSocket, retry: { oldRetries += 1 })
        controller.setActive(false)
        controller.setActive(true)
        await eventually("The foreground delay must start once") { gate.startedCount == 1 }
        let latest = ConnectionStatusPresentation.failed(title: "Still unavailable", message: "The retry failed.")
        controller.updateConnection(presentation: latest, route: .bluetooth, retry: { currentRetries += 1 })
        controller.update(screen, presentation: failure, retry: { screenRetries += 1 })
        controller.update(removedScreen, presentation: failure, retry: { removedRetries += 1 })
        controller.remove(removedScreen)
        controller.setActive(true)
        controller.setActive(true)
        XCTAssertEqual(gate.startedCount, 1, "Repeated active callbacks and state updates must not extend the fixed window.")
        XCTAssertEqual(controller.presentation, connecting)
        XCTAssertEqual(controller.route, .bluetooth)
        XCTAssertFalse(controller.canRetry)
        controller.retry()
        XCTAssertEqual(oldRetries + currentRetries + screenRetries + removedRetries, 0)

        gate.release(0)
        await eventually("Expiry must publish the current failure without a new event") { controller.presentation == latest }
        XCTAssertTrue(controller.canRetry)
        controller.retry()
        XCTAssertEqual(oldRetries, 0)
        XCTAssertEqual(currentRetries, 1)
        XCTAssertEqual(screenRetries, 1)
        XCTAssertEqual(removedRetries, 0)
        XCTAssertEqual(controller.visibleReportCount, 1)
    }

    func testPendingAndSuccessfulRecoveryAreVisibleImmediatelyDuringGrace() async {
        let gate = ForegroundRecoveryDelayGate()
        defer { gate.finishAll() }
        let controller = ConnectionStatusController(foregroundRecoveryDelay: { try await gate.wait() })
        let screen = UUID()
        controller.updateConnection(presentation: failure, route: .bluetooth)
        controller.setActive(false)
        controller.setActive(true)
        await eventually("The recovery window must start") { gate.startedCount == 1 }
        controller.updateConnection(presentation: .pending("Restoring session…"), route: .bluetooth)
        XCTAssertEqual(controller.presentation, .pending("Restoring session…"))
        controller.update(screen, presentation: .pending("Loading controls…"))
        controller.updateConnection(presentation: .connected, route: .bluetooth)
        XCTAssertEqual(controller.presentation, .pending("Loading controls…"))
        controller.update(screen, presentation: .connected)
        XCTAssertEqual(controller.presentation, .connected)
        XCTAssertEqual(controller.route, .bluetooth)
        XCTAssertFalse(controller.canRetry)
        gate.release(0)
        await eventually("The injected delay must finish") { gate.completedCount == 1 }
        XCTAssertEqual(controller.presentation, .connected)
    }

    func testDisconnectedStateIsMaskedOnlyUntilGraceExpires() async {
        let gate = ForegroundRecoveryDelayGate()
        defer { gate.finishAll() }
        let controller = ConnectionStatusController(foregroundRecoveryDelay: { try await gate.wait() })
        let disconnected = ConnectionStatusPresentation.disconnected("Offline", systemImage: "wifi.slash")
        controller.updateConnection(presentation: disconnected, route: nil)
        controller.setActive(false)
        controller.setActive(true)
        await eventually("The recovery window must start") { gate.startedCount == 1 }
        XCTAssertEqual(controller.presentation, connecting)
        XCTAssertNil(controller.route)
        gate.release(0)
        await eventually("An unresolved disconnection must return after the grace") { controller.presentation == disconnected }
        XCTAssertFalse(controller.canRetry)
    }

    func testScreenFailureIsMaskedWithHealthyTransportThenRestoresItsRetry() async {
        let gate = ForegroundRecoveryDelayGate()
        defer { gate.finishAll() }
        let controller = ConnectionStatusController(foregroundRecoveryDelay: { try await gate.wait() })
        let screen = UUID()
        var retries = 0
        controller.updateConnection(presentation: .connected, route: .webSocket)
        controller.update(screen, presentation: failure, retry: { retries += 1 })
        controller.setActive(false)
        controller.setActive(true)
        await eventually("The recovery window must start") { gate.startedCount == 1 }
        XCTAssertEqual(controller.presentation, connecting)
        XCTAssertFalse(controller.canRetry)
        gate.release(0)
        await eventually("A persistent visible-screen failure must return") { controller.presentation == self.failure }
        XCTAssertTrue(controller.canRetry)
        controller.retry()
        XCTAssertEqual(retries, 1)
    }

    func testCancelledOldDelayCannotExpireANewerForegroundInterval() async {
        // Deliberately ignore cancellation inside this injected wait. The
        // controller must reject an obsolete completion independently.
        let gate = ForegroundRecoveryDelayGate(honorsCancellation: false)
        defer { gate.finishAll() }
        let controller = ConnectionStatusController(foregroundRecoveryDelay: { try await gate.wait() })
        controller.updateConnection(presentation: failure, route: .bluetooth)
        controller.setActive(false)
        controller.setActive(true)
        await eventually("The first delay must start") { gate.startedCount == 1 }
        controller.setActive(false)
        XCTAssertEqual(gate.cancelledCount, 1)
        XCTAssertEqual(controller.presentation, connecting)
        controller.setActive(true)
        await eventually("The new foreground interval needs its own delay") { gate.startedCount == 2 }
        gate.release(0)
        await eventually("The cancelled old wait must be allowed to finish") { gate.completedCount == 1 }
        // Let the resumed controller task process the obsolete completion.
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(controller.presentation, connecting)
        XCTAssertFalse(controller.canRetry)
        gate.release(1)
        await eventually("Only the current interval may reveal the failure") { controller.presentation == self.failure }
    }

    func testReleasingControllerCancelsThePendingDelayWithoutRetainingController() async {
        let gate = ForegroundRecoveryDelayGate()
        defer { gate.finishAll() }
        var controller: ConnectionStatusController? = ConnectionStatusController(foregroundRecoveryDelay: { try await gate.wait() })
        weak var released = controller
        controller?.setActive(false)
        controller?.setActive(true)
        await eventually("The delay must be in flight before release") { gate.startedCount == 1 }
        controller = nil
        XCTAssertNil(released, "The timer must not retain the controller while sleeping.")
        await eventually("Controller release must cancel its delay") { gate.cancelledCount == 1 }
        XCTAssertEqual(gate.pendingCount, 0)
    }

    private func eventually(_ message: String, condition: () -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message, file: file, line: line)
    }
}

/// Controls delay completion without sleeping for the production grace period.
/// The lock also makes cancellation registration safe when cancellation arrives
/// immediately before the checked continuation is installed.
private nonisolated final class ForegroundRecoveryDelayGate: @unchecked Sendable {
    private let lock = NSLock()
    private let honorsCancellation: Bool
    private var nextID = 0
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private var released: Set<Int> = []
    private var cancelled: Set<Int> = []
    private var completed: Set<Int> = []
    private var finished = false

    init(honorsCancellation: Bool = true) { self.honorsCancellation = honorsCancellation }
    var startedCount: Int { lock.withLock { nextID } }
    var cancelledCount: Int { lock.withLock { cancelled.count } }
    var completedCount: Int { lock.withLock { completed.count } }
    var pendingCount: Int { lock.withLock { waiters.count } }

    func wait() async throws {
        let id = lock.withLock { let id = nextID; nextID += 1; return id }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let disposition: Int = lock.withLock {
                    if finished || (honorsCancellation && cancelled.contains(id)) { return 1 }
                    if released.contains(id) { return 2 }
                    waiters[id] = continuation
                    return 0
                }
                if disposition == 1 { continuation.resume(throwing: CancellationError()) }
                if disposition == 2 { continuation.resume() }
            }
        } onCancel: {
            self.cancel(id)
        }
        _ = lock.withLock { completed.insert(id) }
    }

    func release(_ id: Int) {
        let continuation = lock.withLock {
            released.insert(id)
            return waiters.removeValue(forKey: id)
        }
        continuation?.resume()
    }

    private func cancel(_ id: Int) {
        let continuation = lock.withLock {
            cancelled.insert(id)
            return honorsCancellation ? waiters.removeValue(forKey: id) : nil
        }
        continuation?.resume(throwing: CancellationError())
    }

    func finishAll() {
        let continuations = lock.withLock {
            finished = true
            let continuations = Array(waiters.values)
            waiters.removeAll()
            return continuations
        }
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}
