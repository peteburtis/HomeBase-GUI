import Foundation
import XCTest
@testable import HomeBase_GUI

@MainActor
final class HomeBaseTransportLifecycleTests: XCTestCase {
    func testWebSocketReadinessWaitsForUpgradeWithoutSendingSessionMessages() async throws {
        let socket = LifecycleSocket()
        let transport = HomeBaseWebSocketTransport(socket: socket)
        defer { transport.close() }
        var ready = false
        let waiting = Task { try await transport.waitUntilReady(); ready = true }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(ready)
        XCTAssertTrue(socket.observerInstalledBeforeResume)
        XCTAssertEqual(socket.sentMessages, 0)
        socket.opened()
        try await waiting.value
        XCTAssertTrue(ready)
        XCTAssertEqual(socket.sentMessages, 0)
    }

    func testWebSocketFailureBeforeUpgradeFailsCurrentAndFutureReadinessWaiters() async {
        let socket = LifecycleSocket()
        let transport = HomeBaseWebSocketTransport(socket: socket)
        let waiting = Task { try await transport.waitUntilReady() }
        socket.failed(URLError(.cannotConnectToHost))
        do { try await waiting.value; XCTFail("A failed upgrade must fail its readiness waiter") }
        catch { XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost) }
        do { try await transport.waitUntilReady(); XCTFail("Failure must remain visible after the callback") }
        catch { XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost) }
        await transport.waitUntilClosed()
        transport.close()
    }

    func testCancellingOneReadinessObserverLeavesCarrierAndOtherObserversAlive() async throws {
        let lifecycle = HomeBaseTransportLifecycle()
        let cancelled = Task { try await lifecycle.waitUntilReady() }
        let remaining = Task { try await lifecycle.waitUntilReady() }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("A cancelled observer must finish") }
        catch { XCTAssertTrue(error is CancellationError) }
        lifecycle.opened()
        try await remaining.value
        try await lifecycle.waitUntilReady()
        lifecycle.closed()
    }

    func testCancellingCloseObserverDoesNotCloseCarrier() async throws {
        let lifecycle = HomeBaseTransportLifecycle()
        lifecycle.opened()
        let cancelled = Task { await lifecycle.waitUntilClosed() }
        cancelled.cancel()
        await cancelled.value
        try await lifecycle.waitUntilReady()
        let remaining = Task { await lifecycle.waitUntilClosed() }
        lifecycle.closed()
        await remaining.value
        await lifecycle.waitUntilClosed()
    }

    func testLateUpgradeCannotReopenClosedCarrier() async {
        let lifecycle = HomeBaseTransportLifecycle()
        lifecycle.closed(URLError(.networkConnectionLost))
        lifecycle.opened()
        do { try await lifecycle.waitUntilReady(); XCTFail("A late delegate callback cannot resurrect a closed carrier") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
    }

    func testURLSessionTaskDelegateReportsActualUpgradeAndCompletion() async throws {
        let lifecycle = HomeBaseTransportLifecycle()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let socket = session.webSocketTask(with: URL(string: "ws://lifecycle.invalid")!)
        socket.observeLifecycle(onOpen: { lifecycle.opened() }, onClose: { lifecycle.closed($0 ?? HomeBaseControlTransportError.closed) })
        guard let delegate = socket.delegate as? HomeBaseWebSocketLifecycleDelegate else {
            return XCTFail("The task must own a WebSocket upgrade delegate before resume")
        }
        // Invoke the real adapter's callbacks without starting network traffic.
        delegate.urlSession(session, webSocketTask: socket, didOpenWithProtocol: "homebase.v2")
        try await lifecycle.waitUntilReady()
        delegate.urlSession(session, task: socket, didCompleteWithError: URLError(.networkConnectionLost))
        await lifecycle.waitUntilClosed()
        do { try await lifecycle.waitUntilReady(); XCTFail("Task completion must retire the carrier") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
    }

    func testBluetoothFinishWakesCarrierObserversWithoutDetachingTwice() async throws {
        var detached = 0
        let transport = HomeBaseBluetoothTransport(sender: { _ in }, closer: { detached += 1 })
        try await transport.waitUntilReady()
        let waiting = Task { await transport.waitUntilClosed() }
        transport.finish(URLError(.networkConnectionLost))
        await waiting.value
        do { try await transport.waitUntilReady(); XCTFail("A finished mailbox must not be advertised as ready") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        XCTAssertEqual(detached, 0)
    }

    func testBluetoothInvalidationRetiresCarrierOnceAndOrdinaryCloseOnlyDetaches() async {
        let detached = expectation(description: "logical detach")
        let invalidated = expectation(description: "carrier invalidation")
        detached.assertForOverFulfill = true
        invalidated.assertForOverFulfill = true
        let transport = HomeBaseBluetoothTransport(sender: { _ in }, closer: { detached.fulfill() },
                                                    invalidator: { invalidated.fulfill() })
        transport.close()
        await fulfillment(of: [detached], timeout: 1)
        // A caller may discover a carrier failure while its logical attachment
        // is already unwinding. Physical invalidation is still needed once.
        transport.invalidate()
        transport.invalidate()
        transport.close()
        await fulfillment(of: [invalidated], timeout: 1)
        await transport.waitUntilClosed()
    }
}

private nonisolated final class LifecycleSocket: HomeBaseControlSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var openHandler: (@Sendable () -> Void)?
    private var closeHandler: (@Sendable (Error?) -> Void)?
    private var observedBeforeResume = false
    private var sent = 0
    var maximumMessageSize: Int = 0
    var observerInstalledBeforeResume: Bool { lock.withLock { observedBeforeResume } }
    var sentMessages: Int { lock.withLock { sent } }
    func observeLifecycle(onOpen: @escaping @Sendable () -> Void, onClose: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { openHandler = onOpen; closeHandler = onClose }
    }
    func resume() { lock.withLock { observedBeforeResume = openHandler != nil && closeHandler != nil } }
    func opened() { lock.withLock { openHandler }?() }
    func failed(_ error: Error) { lock.withLock { closeHandler }?(error) }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { failed(URLError(.cancelled)) }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { lock.withLock { sent += 1 } }
    func receive() async throws -> URLSessionWebSocketTask.Message { throw HomeBaseControlTransportError.closed }
}
