import Foundation
import XCTest
@testable import HomeBase_GUI

@MainActor
final class BluetoothControlTransportTests: XCTestCase {
    func testMailboxPreservesWholeMessageOrder() async throws {
        let transport = makeTransport()
        let messages = [Data("first".utf8), Data(repeating: 0x2a, count: 90_000), Data("last".utf8)]
        messages.forEach(transport.deliver)
        for expected in messages {
            let received = try await transport.receive()
            XCTAssertEqual(received, expected)
        }
        transport.close()
    }

    func testWaitingReceiverGetsOneCompleteMessage() async throws {
        let transport = makeTransport()
        let waiting = Task { try await transport.receive() }
        await Task.yield()
        let message = Data("a complete CnC envelope".utf8)
        transport.deliver(message)
        let received = try await waiting.value
        XCTAssertEqual(received, message)
        transport.close()
    }

    func testCloseFailsPendingReceiveAndPreventsFurtherDeliveryOrSend() async {
        var sent = 0
        let transport = HomeBaseBluetoothTransport(sender: { _ in sent += 1 }, closer: {})
        let waiting = Task { try await transport.receive() }
        await Task.yield()
        transport.close()
        transport.deliver(Data("late".utf8))
        do { _ = try await waiting.value; XCTFail("Closing must resume a pending receive with an error") }
        catch { }
        do { _ = try await transport.receive(); XCTFail("A closed mailbox must not return late data") }
        catch { }
        do { try await transport.send(Data("late mutation".utf8)); XCTFail("A closed transport must reject sends") }
        catch { }
        XCTAssertEqual(sent, 0)
    }

    func testCancellingReceiveClosesOnlyThatLogicalTransport() async {
        let closed = expectation(description: "logical adapter detached")
        closed.assertForOverFulfill = true
        let transport = HomeBaseBluetoothTransport(sender: { _ in }, closer: { closed.fulfill() })
        let waiting = Task { try await transport.receive() }
        await Task.yield()
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Cancelled receive must finish") }
        catch { }
        transport.close() // Cancellation plus caller cleanup is deliberately idempotent.
        await fulfillment(of: [closed], timeout: 1)
    }

    func testRepeatedCloseInvokesDetachOnlyOnce() async {
        var closed = 0
        let detached = expectation(description: "detached")
        let transport = HomeBaseBluetoothTransport(sender: { _ in }, closer: {
            closed += 1
            detached.fulfill()
        })
        transport.close()
        transport.close()
        transport.close()
        await fulfillment(of: [detached], timeout: 1)
        await Task.yield()
        XCTAssertEqual(closed, 1)
    }

    func testByteLimitFailsClosedInsteadOfDroppingOldMessages() async {
        let transport = makeTransport()
        let block = Data(repeating: 0x61, count: 1_024 * 1_024)
        for _ in 0..<33 { transport.deliver(block) }
        do { _ = try await transport.receive(); XCTFail("A backlog over 32 MiB must close, not silently drop events") }
        catch { }
    }

    func testMessageCountLimitBoundsTinyMessageOverhead() async {
        let transport = makeTransport()
        for _ in 0..<4_097 { transport.deliver(Data([1])) }
        do { _ = try await transport.receive(); XCTFail("Thousands of tiny messages must also have a bounded backlog") }
        catch { }
    }

    private func makeTransport() -> HomeBaseBluetoothTransport {
        HomeBaseBluetoothTransport(sender: { _ in }, closer: {})
    }
}
