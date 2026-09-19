import Foundation
import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraStreamArbiterTests: XCTestCase {
    private func eventually(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Condition was not reached", file: file, line: line)
    }

    func testSharedConnectionBootstrapAndTwoSecondHandoff() async throws {
        let f = Fixture()
        let first = try await f.join("a", .low)
        await eventually { await f.wire.count == 1 }
        await f.wire.ready(0)
        await eventually { first.video.count == 1 }
        await f.wire.video(0, sequence: 2)
        await eventually { first.video.count == 2 }
        let second = try await f.join("a", .low)
        await eventually { second.video.count == 2 }
        let separate = try await f.join("b", .low)
        await eventually { await f.wire.count == 2 }
        XCTAssertEqual(second.video.map(\.sequence), [1, 2])
        XCTAssertEqual(first.configurations, second.configurations)
        await f.leave(first)
        await f.wire.video(0, sequence: 3)
        await eventually { second.video.count == 3 }
        await f.leave(second)
        await eventually { await f.clock.hasWait(2) }
        await f.clock.advance(1)
        let returning = try await f.join("a", .low)
        await eventually { returning.video.count == 3 }
        await f.clock.advance(1)
        let opens = await f.wire.count
        XCTAssertEqual(opens, 2, "Returning view reuses camera a, while b is independent")
        await f.leave(returning)
        await eventually { await f.clock.hasWait(2) }
        await f.clock.advance(2)
        await eventually { await f.wire.closed.contains(0) }
        XCTAssertTrue(separate.video.isEmpty)
        await f.end()
    }

    func testMakeBeforeBreakAndGenerationRemapping() async throws {
        let f = Fixture()
        let preview = try await f.join("a", .low)
        await eventually { await f.wire.count == 1 }
        await f.wire.ready(0)
        await eventually { preview.video.count == 1 }
        let full = try await f.join("a", .high)
        await eventually { await f.wire.count == 2 }
        await eventually { full.video.count == 1 }
        await f.wire.configuration(1)
        await f.wire.video(1, sequence: 5, key: false)
        await f.wire.video(0, sequence: 10)
        await eventually { full.video.last?.sequence == 10 }
        XCTAssertEqual(full.configurations.count, 1, "Warm-up config/deltas cannot replace playing video")
        let closedBefore = await f.wire.closed
        XCTAssertTrue(closedBefore.isEmpty)
        await f.wire.video(1, sequence: 6, key: true)
        await eventually { full.configurations.count == 2 && preview.configurations.count == 2 }
        await eventually { await f.wire.closed.contains(0) }
        XCTAssertNotEqual(full.configurations[0], full.configurations[1], "Independent wire leases both use generation 1")
        XCTAssertEqual(full.video.last?.generation, full.configurations.last)
        XCTAssertEqual(full.video.last?.sequence, 6)
        await f.end()
    }

    func testPreservesAdvertisedDeviceAddressSpelling() async throws {
        let f = Fixture()
        let c = try await f.join("BedroomCamera", .low)
        await eventually { await f.wire.count == 1 }
        let addresses = await f.wire.cameras
        XCTAssertEqual(addresses, ["BedroomCamera"])
        await f.leave(c)
        await f.end()
    }

    func testHighestQualityWinsAndDowngradeIsDelayed() async throws {
        let f = Fixture()
        let high = try await f.join("a", .high)
        await eventually { await f.wire.count == 1 }
        await f.wire.ready(0)
        await eventually { high.video.count == 1 }
        let low = try await f.join("a", .low)
        await eventually { low.video.count == 1 }
        let opens = await f.wire.count
        XCTAssertEqual(opens, 1)
        await f.leave(high)
        await eventually { await f.clock.hasWait(2) }
        await f.clock.advance(1)
        let stillOne = await f.wire.count
        XCTAssertEqual(stillOne, 1)
        await f.clock.advance(1)
        await eventually { await f.wire.count == 2 }
        let qualities = await f.wire.qualities
        XCTAssertEqual(qualities, [.high, .low])
        await f.wire.video(0, sequence: 11)
        await eventually { low.video.last?.sequence == 11 }
        await f.wire.ready(1)
        await eventually { await f.wire.closed.contains(0) }
        await f.end()
    }

    func testRapidChangesBoundOverlapAndOnlyLatestCandidateCanWin() async throws {
        let f = Fixture()
        let c = try await f.join("a", .low)
        await eventually { await f.wire.count == 1 }
        await f.wire.ready(0)
        await eventually { c.video.count == 1 }
        await f.arbiter.update(c.subscription, quality: .medium)
        await eventually { await f.wire.count == 2 }
        await f.wire.holdClose(1)
        await f.arbiter.update(c.subscription, quality: .high)
        await eventually { await f.wire.count == 3 }
        await f.wire.holdClose(2)
        await f.arbiter.update(c.subscription, quality: .medium)
        await eventually { await f.wire.closing.contains(2) }
        let capped = await f.wire.count
        XCTAssertEqual(capped, 3, "No fourth upstream while retirements are outstanding")
        await f.wire.ready(1)
        await f.wire.ready(2)
        await f.wire.video(0, sequence: 12)
        await eventually { c.video.last?.sequence == 12 }
        XCTAssertEqual(c.configurations.count, 1)
        await f.wire.releaseClose(1)
        await eventually { await f.wire.count == 4 }
        await f.wire.ready(3)
        await eventually { c.configurations.count == 2 }
        let qualities = await f.wire.qualities
        XCTAssertEqual(qualities, [.low, .medium, .high, .medium])
        await f.wire.releaseClose(2)
        await f.end()
    }

    func testFailedQualityWarmupKeepsOldFeedAndRetries() async throws {
        let f = Fixture()
        let c = try await f.join("a", .low)
        await eventually { await f.wire.count == 1 }
        await f.wire.ready(0)
        await eventually { c.video.count == 1 }
        await f.arbiter.update(c.subscription, quality: .high)
        await eventually { await f.wire.count == 2 }
        await f.wire.fail(1)
        await eventually { c.warning != nil }
        await f.wire.video(0, sequence: 14)
        await eventually { c.video.last?.sequence == 14 }
        XCTAssertNil(c.error)
        await eventually { await f.clock.hasWait(2) }
        await f.clock.advance(2)
        await eventually { await f.wire.count == 3 }
        await f.wire.ready(2)
        await eventually { c.configurations.count == 2 && c.warning == nil }
        await f.end()
    }

    func testWarmupDeadlineAndReturningToCurrentQualityClearsWarning() async throws {
        let f = Fixture()
        let c = try await f.join("a", .low)
        await eventually { await f.wire.count == 1 }
        await f.wire.ready(0)
        await eventually { c.video.count == 1 }
        await f.arbiter.update(c.subscription, quality: .high)
        await eventually { await f.wire.count == 2 }
        await eventually { await f.clock.hasWait(20) }
        await f.clock.advance(20)
        await eventually { c.warning != nil }
        await f.arbiter.update(c.subscription, quality: .low)
        await eventually { c.warning == nil }
        await f.wire.video(0, sequence: 15)
        await eventually { c.video.last?.sequence == 15 }
        await f.clock.advance(30)
        let count = await f.wire.count
        XCTAssertEqual(count, 2)
        await f.end()
    }

    func testOldFeedFailureDoesNotDiscardAnAlreadyWarmingReplacement() async throws {
        let f = Fixture()
        let c = try await f.join("a", .low)
        await eventually { await f.wire.count == 1 }
        await f.wire.ready(0)
        await eventually { c.video.count == 1 }
        await f.arbiter.update(c.subscription, quality: .high)
        await eventually { await f.wire.count == 2 }
        await f.wire.fail(0)
        await eventually { await f.wire.closed.contains(0) }
        await f.wire.ready(1)
        await eventually { c.configurations.count == 2 }
        XCTAssertNil(c.error)
        await f.end()
    }

    func testBootstrapLimitWaitsForNextKeyframeInsteadOfReplayingBrokenGOP() async throws {
        var policy = CameraStreamArbiter.Policy(); policy.bootstrapFrames = 2
        let f = Fixture(policy: policy)
        let c = try await f.join("a", .low)
        await eventually { await f.wire.count == 1 }
        await f.wire.ready(0)
        await f.wire.video(0, sequence: 2)
        await f.wire.video(0, sequence: 3)
        await eventually { c.video.count == 3 }
        let late = try await f.join("a", .low)
        await f.wire.video(0, sequence: 4)
        await eventually { c.video.count == 4 }
        XCTAssertTrue(late.video.isEmpty)
        await f.wire.video(0, sequence: 5, key: true)
        await eventually { late.video.count == 1 }
        XCTAssertEqual(late.video.first?.sequence, 5)
        XCTAssertEqual(late.configurations.count, 1)
        await f.end()
    }

    func testSlowConsumerDoesNotInterruptHealthyConsumer() async throws {
        var policy = CameraStreamArbiter.Policy(); policy.consumerQueue = 4
        let f = Fixture(policy: policy)
        let fast = try await f.join("a", .low)
        let slow = try await f.arbiter.subscribe(camera: "a", quality: .low)
        await eventually { await f.wire.count == 1 }
        await f.wire.ready(0)
        await eventually { fast.video.count == 1 }
        for index in 2...12 {
            await f.wire.video(0, sequence: UInt64(index))
            await eventually { fast.video.count == index }
        }
        do {
            for try await _ in slow.events {}
            XCTFail("Slow subscription should fail")
        } catch { XCTAssertEqual(error as? CameraStreamError, .slowConsumer) }
        XCTAssertNil(fast.error)
        let closed = await f.wire.closed
        XCTAssertTrue(closed.isEmpty)
        await f.end()
    }

    func testRevocationDuringAcquireClosesLateLeaseAndRejectsOldAuthorization() async throws {
        let f = Fixture()
        let authorization = CameraStreamAuthorization()
        await f.wire.holdNextOpen()
        let sub = try await f.arbiter.subscribe(camera: "a", quality: .low, authorization: authorization)
        let collector = Collector(sub)
        await eventually { await f.wire.count == 1 }
        authorization.invalidate()
        await f.arbiter.revoke(authorization)
        await f.wire.releaseOpen()
        await eventually { await f.wire.closed.contains(0) }
        XCTAssertTrue(collector.video.isEmpty)
        do {
            _ = try await f.arbiter.subscribe(camera: "a", quality: .low, authorization: authorization)
            XCTFail("Revoked authorization reused")
        } catch { XCTAssertEqual(error as? CameraStreamError, .closed) }
        await f.end()
    }

    func testImmediateReleaseAndShutdownSkipGrace() async throws {
        let f = Fixture()
        let c = try await f.join("a", .low)
        await eventually { await f.wire.count == 1 }
        await f.wire.ready(0)
        await eventually { c.video.count == 1 }
        await f.arbiter.unsubscribe(camera: "a", id: c.subscription.id, immediately: true)
        await eventually { await f.wire.closed.contains(0) }
        let new = try await f.join("a", .low)
        await eventually { await f.wire.count == 2 }
        XCTAssertTrue(new.video.isEmpty, "No bootstrap survives immediate teardown")
        await f.end()
        await eventually { await f.wire.closed.contains(1) }
        do {
            _ = try await f.arbiter.subscribe(camera: "a", quality: .low)
            XCTFail("Disconnected session was reused")
        } catch { XCTAssertEqual(error as? CameraStreamError, .closed) }
    }

    private final class Fixture {
        let wire = Wire()
        let clock = ManualClock()
        let arbiter: CameraStreamArbiter
        init(policy: CameraStreamArbiter.Policy = .init()) {
            let wire = wire, clock = clock
            arbiter = CameraStreamArbiter(policy: policy, sleep: { try await clock.sleep($0) }, open: { try await wire.open($0, $1) })
        }
        func join(_ camera: String, _ quality: HBCameraLiveQuality) async throws -> Collector {
            Collector(try await arbiter.subscribe(camera: camera, quality: quality))
        }
        func leave(_ c: Collector) async { await arbiter.unsubscribe(camera: c.subscription.camera, id: c.subscription.id) }
        func end() async { await arbiter.shutdown() }
    }

    private final class Collector {
        let subscription: CameraStreamSubscription
        var video: [HBMediaFrame] = []
        var configurations: [UInt32] = []
        var warning: String?
        var error: Error?
        var task: Task<Void, Never>?
        init(_ subscription: CameraStreamSubscription) {
            self.subscription = subscription
            task = Task { [weak self] in
                do {
                    for try await event in subscription.events {
                        guard let self else { break }
                        switch event {
                        case .qualityWarning(let value): warning = value
                        case .frames(let frames):
                            for frame in frames {
                                if frame.type == .videoAccessUnit { video.append(frame) }
                                if frame.type == .streamConfiguration { configurations.append(frame.generation) }
                            }
                        }
                    }
                } catch { self?.error = error }
            }
        }
        deinit { task?.cancel() }
    }
}

private actor Wire {
    private var outputs: [AsyncThrowingStream<HBMediaFrame, Error>.Continuation] = []
    private(set) var qualities: [HBCameraLiveQuality] = []
    private(set) var cameras: [String] = []
    private(set) var closed: Set<Int> = []
    private(set) var closing: Set<Int> = []
    private var heldCloses: Set<Int> = []
    private var closeWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var holdsOpen = false
    private var openWaiter: CheckedContinuation<Void, Never>?
    var count: Int { outputs.count }
    func holdNextOpen() { holdsOpen = true }
    func releaseOpen() { holdsOpen = false; openWaiter?.resume(); openWaiter = nil }
    func holdClose(_ index: Int) { heldCloses.insert(index) }
    func releaseClose(_ index: Int) { heldCloses.remove(index); closeWaiters.removeValue(forKey: index)?.resume() }
    func open(_ camera: String, _ quality: HBCameraLiveQuality) async throws -> CameraStreamUpstream {
        let pair = AsyncThrowingStream<HBMediaFrame, Error>.makeStream()
        let index = outputs.count
        outputs.append(pair.continuation); qualities.append(quality); cameras.append(camera)
        if holdsOpen { await withCheckedContinuation { openWaiter = $0 } }
        return CameraStreamUpstream(frames: pair.stream, close: { await self.close(index) })
    }
    private func close(_ index: Int) async {
        closing.insert(index)
        if heldCloses.contains(index) { await withCheckedContinuation { closeWaiters[index] = $0 } }
        closed.insert(index); outputs[index].finish()
    }
    func configuration(_ index: Int) {
        let config = HBMediaStreamConfiguration(generation: 1, quality: qualities[index], width: 640, height: 360,
                                                sequenceParameterSet: Data([0x67, 0x64]).base64EncodedString(),
                                                pictureParameterSet: Data([0x68, 0x01]).base64EncodedString())
        outputs[index].yield(HBMediaFrame(type: .streamConfiguration, generation: 1, payload: try! JSONEncoder().encode(config)))
    }
    func video(_ index: Int, sequence: UInt64, key: Bool = false) {
        outputs[index].yield(HBMediaFrame(type: .videoAccessUnit, flags: key ? [.keyFrame] : [], sequence: sequence,
                                         presentationTimestamp: sequence * 6000, generation: 1, payload: Data([0, 0, 0, 2, key ? 0x65 : 0x41, 1])))
    }
    func ready(_ index: Int) { configuration(index); video(index, sequence: 1, key: true) }
    func fail(_ index: Int) { outputs[index].finish(throwing: CameraStreamError.ended) }
}

private actor ManualClock {
    private struct Waiter { let deadline: Double; let continuation: CheckedContinuation<Void, Error> }
    private var now = 0.0
    private var waiters: [UUID: Waiter] = [:]
    func hasWait(_ seconds: Double) -> Bool { waiters.values.contains { $0.deadline == now + seconds } }
    func sleep(_ seconds: Double) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { waiters[id] = Waiter(deadline: now + seconds, continuation: $0) }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
    func advance(_ seconds: Double) {
        now += seconds
        for (id, waiter) in waiters where waiter.deadline <= now {
            waiters.removeValue(forKey: id); waiter.continuation.resume()
        }
    }
}
