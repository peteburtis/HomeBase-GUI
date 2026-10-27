import Foundation
import XCTest
@testable import HomeBase_GUI

@MainActor
final class HomeBaseCarrierCoordinatorTests: XCTestCase {
    private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Carrier state did not settle", file: file, line: line)
    }

    func testBothCarriersStartWithoutSessionMessagesAndReadyWebSocketIsPreferred() async throws {
        let network = CoordinatorTestTransport(.webSocket)
        let bluetooth = CoordinatorTestTransport(.bluetooth)
        let coordinator = HomeBaseCarrierCoordinator(webSocket: { network }, bluetooth: { bluetooth })
        await coordinator.start()
        await eventually { network.readinessWaits == 1 && bluetooth.readinessWaits == 1 }
        network.open()
        bluetooth.open()
        await eventually {
            let networkReady = await coordinator.readyCarrier(for: .webSocket)
            let bluetoothReady = await coordinator.readyCarrier(for: .bluetooth)
            return networkReady != nil && bluetoothReady != nil
        }
        let chosen = try await coordinator.acquirePreferred()
        XCTAssertEqual(chosen.route, .webSocket)
        XCTAssertEqual(network.sentMessages, 0)
        XCTAssertEqual(bluetooth.sentMessages, 0)
        XCTAssertEqual(bluetooth.closeCount, 0, "A ready standby remains available after route selection")
        await coordinator.shutdown()
    }

    func testReadyBluetoothDoesNotWaitForStalledNetworkFactoryOrItsCancellation() async throws {
        let gate = CoordinatorFactoryGate()
        let network = CoordinatorTestTransport(.webSocket, ready: true)
        let bluetooth = CoordinatorTestTransport(.bluetooth, ready: true)
        let coordinator = HomeBaseCarrierCoordinator(
            webSocket: { await gate.wait() }, bluetooth: { bluetooth },
            webSocketAttemptTimeout: .milliseconds(50), retryDelay: .seconds(60))
        await coordinator.start()
        await eventually { await gate.isWaiting }
        let chosen = try await coordinator.acquirePreferred(timeout: .seconds(1))
        XCTAssertEqual(chosen.route, .bluetooth)
        // The network factory deliberately ignores cancellation. Its deadline
        // must not prevent the Bluetooth session owner from proceeding.
        try await Task.sleep(for: .milliseconds(100))
        let current = await coordinator.isCurrent(chosen)
        XCTAssertTrue(current)
        await gate.release(network)
        await eventually { network.closeCount == 1 }
        XCTAssertEqual(bluetooth.closeCount, 0)
        await coordinator.shutdown()
    }

    func testFactoryDeadlineAllowsRetryBeforeNoncooperativeAttemptReturns() async throws {
        let gate = CoordinatorFactoryGate()
        let obsolete = CoordinatorTestTransport(.webSocket, ready: true)
        let replacement = CoordinatorTestTransport(.webSocket, ready: true)
        let factory = CoordinatorReplacingFactory(gate: gate, replacement: replacement)
        let coordinator = HomeBaseCarrierCoordinator(
            webSocket: { await factory.make() },
            webSocketAttemptTimeout: .milliseconds(40), retryDelay: .milliseconds(10))
        await coordinator.start()
        await eventually { await factory.calls >= 2 }
        let chosen = try await coordinator.acquirePreferred()
        XCTAssertTrue(chosen.transport === replacement)
        await gate.release(obsolete)
        await eventually { obsolete.closeCount == 1 }
        let current = await coordinator.isCurrent(chosen)
        XCTAssertTrue(current, "Late completion must not replace the new carrier")
        await coordinator.shutdown()
    }

    func testReadinessDeadlineInvalidatesCarrierEvenWhenReadinessIgnoresCancellation() async throws {
        let gate = CoordinatorReadinessGate()
        let stalled = CoordinatorTestTransport(.webSocket, readinessGate: gate)
        let replacement = CoordinatorTestTransport(.webSocket, ready: true)
        let factory = CoordinatorTransportSequence([stalled, replacement])
        let coordinator = HomeBaseCarrierCoordinator(
            webSocket: { try await factory.make() },
            webSocketAttemptTimeout: .milliseconds(40), retryDelay: .milliseconds(10))
        await coordinator.start()
        await eventually { stalled.invalidateCount == 1 }
        await eventually { await coordinator.readyCarrier(for: .webSocket) != nil }
        let chosen = try await coordinator.acquirePreferred()
        XCTAssertTrue(chosen.transport === replacement)
        await gate.release()
        let current = await coordinator.isCurrent(chosen)
        XCTAssertTrue(current)
        await coordinator.shutdown()
    }

    func testBackgroundCancelsBluetoothGenerationAndForegroundStartsFreshAttempt() async throws {
        let gate = CoordinatorFactoryGate()
        let network = CoordinatorTestTransport(.webSocket, ready: true)
        let obsolete = CoordinatorTestTransport(.bluetooth, ready: true)
        let replacement = CoordinatorTestTransport(.bluetooth, ready: true)
        let factory = CoordinatorReplacingFactory(gate: gate, replacement: replacement)
        let coordinator = HomeBaseCarrierCoordinator(
            webSocket: { network }, bluetooth: { await factory.make() },
            bluetoothAttemptTimeout: .milliseconds(200))
        await coordinator.start()
        await eventually { await gate.isWaiting }
        await coordinator.setForeground(false)
        await coordinator.setForeground(true)
        let selected = try await coordinator.acquirePreferred(excluding: .webSocket, timeout: .seconds(1))
        XCTAssertTrue(selected.transport === replacement)
        await gate.release(obsolete)
        await eventually { obsolete.closeCount == 1 }
        try await Task.sleep(for: .milliseconds(250))
        let current = await coordinator.isCurrent(selected)
        XCTAssertTrue(current, "An old deadline must not expire a new foreground generation")
        XCTAssertEqual(network.closeCount, 0)
        await coordinator.shutdown()
    }

    func testAllFailedRoutesReportOriginalNetworkErrorWithoutWaitingForAcquisitionDeadline() async {
        let coordinator = HomeBaseCarrierCoordinator(
            webSocket: { throw URLError(.notConnectedToInternet) },
            bluetooth: { throw HomeBaseControlTransportError.unavailable },
            retryDelay: .seconds(60))
        do {
            _ = try await coordinator.acquirePreferred(timeout: .seconds(1))
            XCTFail("Both routes failed")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        await coordinator.shutdown()
    }

    func testCancellationOfOneAcquisitionDoesNotCancelCarriersOrAnotherWaiter() async throws {
        let network = CoordinatorTestTransport(.webSocket)
        let coordinator = HomeBaseCarrierCoordinator(webSocket: { network })
        let first = Task { try await coordinator.acquirePreferred() }
        let second = Task { try await coordinator.acquirePreferred() }
        await eventually { network.readinessWaits == 1 }
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("The canceled caller must finish")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(network.closeCount, 0)
        network.open()
        let selected = try await second.value
        XCTAssertTrue(selected.transport === network)
        await coordinator.shutdown()
    }

    func testStandbyClosureIsObservedWithoutReadingApplicationMessages() async throws {
        let network = CoordinatorTestTransport(.webSocket, ready: true)
        let bluetooth = CoordinatorTestTransport(.bluetooth, ready: true)
        let coordinator = HomeBaseCarrierCoordinator(
            webSocket: { network }, bluetooth: { bluetooth }, retryDelay: .seconds(60))
        await coordinator.start()
        await eventually {
            let networkReady = await coordinator.readyCarrier(for: .webSocket)
            let bluetoothReady = await coordinator.readyCarrier(for: .bluetooth)
            return networkReady != nil && bluetoothReady != nil
        }
        network.remoteClose()
        await eventually { await coordinator.readyCarrier(for: .webSocket) == nil }
        let selected = try await coordinator.acquirePreferred()
        XCTAssertEqual(selected.route, .bluetooth)
        XCTAssertEqual(network.receivedMessages, 0)
        XCTAssertEqual(bluetooth.receivedMessages, 0)
        await coordinator.shutdown()
    }

    func testDiscardInvalidatesOnlyMatchingCarrierAndRetrySignalWarmsReplacement() async throws {
        let first = CoordinatorTestTransport(.webSocket, ready: true)
        let replacement = CoordinatorTestTransport(.webSocket, ready: true)
        let factory = CoordinatorTransportSequence([first, replacement])
        let coordinator = HomeBaseCarrierCoordinator(
            webSocket: { try await factory.make() }, retryDelay: .seconds(60))
        let old = try await coordinator.acquirePreferred()
        await coordinator.discard(old, invalidate: true)
        XCTAssertEqual(first.invalidateCount, 1)
        await coordinator.retryUnavailable(.webSocket)
        let current = try await coordinator.acquirePreferred()
        await coordinator.discard(old, invalidate: true)
        XCTAssertEqual(replacement.closeCount, 0)
        XCTAssertEqual(replacement.invalidateCount, 0)
        let isCurrent = await coordinator.isCurrent(current)
        XCTAssertTrue(isCurrent)
        await coordinator.shutdown()
    }

    func testSessionDiscardAfterObservedCloseWaitsForFreshCarrier() async throws {
        let first = CoordinatorTestTransport(.webSocket, ready: true)
        let replacement = CoordinatorTestTransport(.webSocket, ready: true)
        let factory = CoordinatorTransportSequence([first, replacement])
        let coordinator = HomeBaseCarrierCoordinator(
            webSocket: { try await factory.make() }, retryDelay: .milliseconds(100))
        let old = try await coordinator.acquirePreferred()
        first.remoteClose()
        await eventually { await coordinator.readyCarrier(for: .webSocket) == nil }
        // The close monitor won the race with the session owner's rejection.
        await coordinator.discard(old)
        let next = try await coordinator.acquirePreferred(timeout: .seconds(1))
        XCTAssertTrue(next.transport === replacement)
        XCTAssertNotEqual(next.id, old.id)
        await coordinator.shutdown()
    }

    func testBackgroundNeverStartsBluetoothAndShutdownFinishesWaitingAcquisition() async {
        let network = CoordinatorTestTransport(.webSocket)
        let bluetooth = CoordinatorTestTransport(.bluetooth, ready: true)
        let coordinator = HomeBaseCarrierCoordinator(
            webSocket: { network }, bluetooth: { bluetooth }, foreground: false)
        let waiting = Task { try await coordinator.acquirePreferred() }
        await eventually { network.readinessWaits == 1 }
        XCTAssertEqual(bluetooth.readinessWaits, 0)
        await coordinator.shutdown()
        do {
            _ = try await waiting.value
            XCTFail("Shutdown must finish every waiting caller")
        } catch {
            XCTAssertTrue(error is HomeBaseCarrierCoordinator.CoordinatorError)
        }
        XCTAssertEqual(network.closeCount, 1)
    }

    func testBackgroundStopsNetworkRetryAndForegroundReplacesClosedCarrier() async throws {
        let first = CoordinatorTestTransport(.webSocket, ready: true)
        let replacement = CoordinatorTestTransport(.webSocket, ready: true)
        let factory = CoordinatorTransportSequence([first, replacement])
        let coordinator = HomeBaseCarrierCoordinator(
            webSocket: { try await factory.make() }, retryDelay: .milliseconds(50))
        _ = try await coordinator.acquirePreferred()
        first.remoteClose()
        await eventually { await coordinator.readyCarrier(for: .webSocket) == nil }
        await coordinator.setForeground(false)
        try await Task.sleep(for: .milliseconds(100))
        let backgroundCalls = await factory.calls
        XCTAssertEqual(backgroundCalls, 1, "A background app must not poll for network recovery")
        await coordinator.setForeground(true)
        let next = try await coordinator.acquirePreferred(timeout: .seconds(1))
        XCTAssertTrue(next.transport === replacement, "Foreground recovery must not return the old close error")
        await coordinator.shutdown()
    }
}

private nonisolated final class CoordinatorTestTransport: HomeBaseControlTransport, @unchecked Sendable {
    let route: HomeBaseControlRoute
    private let lifecycle = HomeBaseTransportLifecycle()
    private let readinessGate: CoordinatorReadinessGate?
    private let lock = NSLock()
    private var waits = 0
    private var closes = 0
    private var invalidations = 0
    private var sends = 0
    private var receives = 0

    init(_ route: HomeBaseControlRoute, ready: Bool = false, readinessGate: CoordinatorReadinessGate? = nil) {
        self.route = route
        self.readinessGate = readinessGate
        if ready { lifecycle.opened() }
    }

    var readinessWaits: Int { lock.withLock { waits } }
    var closeCount: Int { lock.withLock { closes } }
    var invalidateCount: Int { lock.withLock { invalidations } }
    var sentMessages: Int { lock.withLock { sends } }
    var receivedMessages: Int { lock.withLock { receives } }

    func waitUntilReady() async throws {
        lock.withLock { waits += 1 }
        if let readinessGate { await readinessGate.wait() }
        else { try await lifecycle.waitUntilReady() }
    }
    func waitUntilClosed() async { await lifecycle.waitUntilClosed() }
    func send(_ data: Data) async throws { lock.withLock { sends += 1 } }
    func receive() async throws -> Data {
        lock.withLock { receives += 1 }
        throw HomeBaseControlTransportError.closed
    }
    func open() { lifecycle.opened() }
    func remoteClose() { lifecycle.closed() }
    func close() {
        lock.withLock { if closes == 0 { closes += 1 } }
        lifecycle.closed()
    }
    func invalidate() {
        lock.withLock { invalidations += 1 }
        close()
    }
}

/// Intentionally ignores cancellation to exercise late OS/framework callbacks.
private actor CoordinatorFactoryGate {
    private var continuation: CheckedContinuation<any HomeBaseControlTransport, Never>?
    private var released: (any HomeBaseControlTransport)?
    var isWaiting: Bool { continuation != nil }
    func wait() async -> any HomeBaseControlTransport {
        if let released { return released }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ transport: any HomeBaseControlTransport) {
        released = transport
        continuation?.resume(returning: transport)
        continuation = nil
    }
}

private actor CoordinatorReadinessGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor CoordinatorReplacingFactory {
    let gate: CoordinatorFactoryGate
    let replacement: any HomeBaseControlTransport
    private(set) var calls = 0
    init(gate: CoordinatorFactoryGate, replacement: any HomeBaseControlTransport) {
        self.gate = gate
        self.replacement = replacement
    }
    func make() async -> any HomeBaseControlTransport {
        calls += 1
        if calls == 1 { return await gate.wait() }
        return replacement
    }
}

private actor CoordinatorTransportSequence {
    private var transports: [any HomeBaseControlTransport]
    private(set) var calls = 0
    init(_ transports: [any HomeBaseControlTransport]) { self.transports = transports }
    func make() throws -> any HomeBaseControlTransport {
        calls += 1
        guard !transports.isEmpty else { throw HomeBaseControlTransportError.unavailable }
        return transports.removeFirst()
    }
}
