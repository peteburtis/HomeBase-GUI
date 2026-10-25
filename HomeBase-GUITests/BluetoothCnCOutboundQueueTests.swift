import Foundation
import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class BluetoothCnCOutboundQueueTests: XCTestCase {
    func testLargeMessageDetachAndReattachBarriersPreserveWireOrder() async throws {
        let pair = try Pair()
        let queue = BluetoothCnCOutboundQueue(channel: pair.sender)
        let large = try envelope(operation: "control.set", payload: String(repeating: "x", count: 200_000))
        let detach = try envelope(operation: "bluetooth.cnc.detach")
        let reattach = try envelope(operation: HBProtocolOperations.resumeSession)
        let next = try envelope(operation: "control.set", payload: "next attachment")
        try queue.enqueue(large)
        // Start the large message before the foreground route changes.
        XCTAssertNil(try pair.receiver.receiveRecord(XCTUnwrap(queue.nextRecord())))
        try queue.enqueue(detach, barrier: true)
        try queue.enqueue(reattach, barrier: true)
        try queue.enqueue(next)
        XCTAssertEqual(try drain(queue, receiver: pair.receiver), [large, detach, reattach, next])
        XCTAssertTrue(queue.isEmpty)
        try pair.receiver.validateEndOfStream()
    }

    func testSmallMessageCannotOvertakeEarlierLargeCommands() async throws {
        let pair = try Pair()
        let queue = BluetoothCnCOutboundQueue(channel: pair.sender)
        let first = Data(repeating: 1, count: 100_000)
        let second = Data(repeating: 2, count: 100_000)
        let small = Data("interactive reply".utf8)
        try queue.enqueue(first)
        try queue.enqueue(second)
        try queue.enqueue(small)
        XCTAssertEqual(try drain(queue, receiver: pair.receiver), [first, second, small])
        try pair.receiver.validateEndOfStream()
    }

    func testManyLargeMessagesCompleteFIFOWithinReceiverConcurrency() async throws {
        let pair = try Pair()
        let queue = BluetoothCnCOutboundQueue(channel: pair.sender)
        let messages = (0..<25).map { Data(repeating: UInt8($0), count: 70_000) }
        for message in messages { try queue.enqueue(message) }
        var completed: [Data] = []
        var peak = 0
        while let record = try queue.nextRecord() {
            if case .message(let data) = try pair.receiver.receiveRecord(record) { completed.append(data) }
            peak = max(peak, pair.receiver.incompleteMessageCount)
            XCTAssertLessThanOrEqual(peak, pair.receiver.resourcePolicy.maximumConcurrentMessages)
        }
        XCTAssertEqual(completed, messages)
        XCTAssertEqual(peak, 1, "The CnC lane preserves logical command and deliverySequence order.")
        try pair.receiver.validateEndOfStream()
    }

    func testLargeBarrierFinishesBeforeLaterSmallMessageStarts() async throws {
        let pair = try Pair()
        let queue = BluetoothCnCOutboundQueue(channel: pair.sender)
        let prior = Data(repeating: 1, count: 50_000)
        let barrier = Data(repeating: 2, count: 150_000)
        let later = Data("later".utf8)
        try queue.enqueue(prior)
        try queue.enqueue(barrier, barrier: true)
        try queue.enqueue(later)
        XCTAssertEqual(try drain(queue, receiver: pair.receiver), [prior, barrier, later])
        try pair.receiver.validateEndOfStream()
    }

    func testByteBudgetRetainsWholeMessagesUntilTheyFinish() async throws {
        let pair = try Pair()
        let queue = BluetoothCnCOutboundQueue(channel: pair.sender)
        let limit = pair.sender.resourcePolicy.maximumMessageBytes
        try queue.enqueue(Data(repeating: 1, count: limit))
        try queue.enqueue(Data(repeating: 2, count: limit))
        XCTAssertThrowsError(try queue.enqueue(Data([3])))
        XCTAssertNil(try pair.receiver.receiveRecord(XCTUnwrap(queue.nextRecord())))
        XCTAssertThrowsError(try queue.enqueue(Data([3])),
            "A partially sent outbound message still retains its full source Data.")
        let completed = try drain(queue, receiver: pair.receiver)
        XCTAssertEqual(completed.map(\.count), [limit, limit])
        try queue.enqueue(Data([3]))
        XCTAssertEqual(try drain(queue, receiver: pair.receiver), [Data([3])])
        try pair.receiver.validateEndOfStream()
    }

    func testMessageCountLimitRejectsBeforeAdvancingCipher() async throws {
        let pair = try Pair()
        let queue = BluetoothCnCOutboundQueue(channel: pair.sender)
        for _ in 0..<4_096 { try queue.enqueue(Data([1])) }
        XCTAssertThrowsError(try queue.enqueue(Data([2])))
        let completed = try drain(queue, receiver: pair.receiver)
        XCTAssertEqual(completed.count, 4_096)
        XCTAssertTrue(completed.allSatisfy { $0 == Data([1]) })
        try queue.enqueue(Data([2]))
        XCTAssertEqual(try drain(queue, receiver: pair.receiver), [Data([2])])
        try pair.receiver.validateEndOfStream()
    }

    func testInvalidatedChannelCannotProduceMoreQueuedCiphertext() async throws {
        let pair = try Pair()
        let queue = BluetoothCnCOutboundQueue(channel: pair.sender)
        try queue.enqueue(Data(repeating: 1, count: 100_000))
        XCTAssertNotNil(try queue.nextRecord())
        pair.sender.invalidate()
        XCTAssertThrowsError(try queue.nextRecord())
        XCTAssertThrowsError(try queue.enqueue(Data([2])))
    }

    private func drain(_ queue: BluetoothCnCOutboundQueue,
                       receiver: HBBluetoothCnCChannel) throws -> [Data] {
        var complete: [Data] = []
        var records = 0
        while let record = try queue.nextRecord() {
            if case .message(let message) = try receiver.receiveRecord(record) { complete.append(message) }
            records += 1
            guard records < 100_000 else {
                XCTFail("Queue failed to make progress")
                break
            }
        }
        return complete
    }

    private func envelope(operation: String, payload: String = "") throws -> Data {
        try JSONEncoder().encode(HBProtocolEnvelope.request(operation: operation,
            clientID: UUID(uuidString: "25C756A4-4711-4B36-8F71-F89D605B1E32")!,
            payload: ["value": payload]))
    }

    private struct Pair {
        let sender: HBBluetoothCnCChannel
        let receiver: HBBluetoothCnCChannel
        init() throws {
            let credential = HBBluetoothCnCCredential(controllerID: UUID(), registrationID: UUID(),
                keyID: UUID(), secret: Data(repeating: 42, count: 32))
            let client = try HBBluetoothCnCClientHandshake(credential: credential)
            let server = try HBBluetoothCnCServerHandshake.accept(client.request, credential: credential)
            sender = try client.finish(server.result)
            receiver = server.channel
            XCTAssertEqual(try receiver.receiveRecord(sender.makeConfirmation()), .confirmed)
        }
    }
}
