import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraLiveSynchronizationTests: XCTestCase {
    private func head(_ id: String, _ utc: Double, _ arrival: Double = 10) -> CameraLiveSynchronization.Head {
        .init(id: id, cameraUTC: utc, receivedAt: arrival)
    }

    func testLeadingFeedsTargetTheMostTardyWithinInclusiveWindow() async {
        var sync = CameraLiveSynchronization()
        XCTAssertEqual(sync.targets(for: [head("a", 100), head("b", 101), head("c", 102.5)], now: 10),
                       ["a": 100, "b": 100, "c": 100])
    }

    func testStallHoldsBrieflyThenReleasesBasedOnReceivedHeads() async {
        var sync = CameraLiveSynchronization()
        XCTAssertEqual(sync.targets(for: [head("a", 100), head("b", 101)], now: 10)["b"], 100)
        XCTAssertEqual(sync.targets(for: [head("a", 100), head("b", 102.5, 11)], now: 11)["b"], 100)
        XCTAssertTrue(sync.targets(for: [head("a", 100), head("b", 102.51, 11.1)], now: 11.1).isEmpty)
        // Matching frame times do not make a silent source fresh indefinitely.
        XCTAssertTrue(sync.targets(for: [head("a", 100), head("b", 101, 13)], now: 13).isEmpty)
        XCTAssertEqual(sync.targets(for: [head("a", 103, 13), head("b", 104, 13)], now: 13), ["a": 103, "b": 103])
    }

    func testClockOutlierCannotPreventOtherCamerasSynchronizing() async {
        var sync = CameraLiveSynchronization()
        let clocks = [head("a", 100), head("b", 100.5), head("fast-clock", 9000), head("slow-clock", -9000)]
        XCTAssertEqual(sync.targets(for: clocks, now: 10), ["a": 100, "b": 100])
        XCTAssertEqual(sync.targets(for: clocks.reversed(), now: 10), ["a": 100, "b": 100])
        XCTAssertTrue(sync.targets(for: [head("a", 100), head("b", 103)], now: 10).isEmpty)
    }

    func testInvalidMissingOrStaleClocksNeverHoldHealthyVideo() async {
        var sync = CameraLiveSynchronization()
        XCTAssertTrue(sync.targets(for: [], now: 10).isEmpty)
        XCTAssertTrue(sync.targets(for: [head("a", 100)], now: 10).isEmpty)
        XCTAssertTrue(sync.targets(for: [head("a", 100), head("bad", .nan), head("old", 100, 1), head("future-arrival", 100, 20)], now: 10).isEmpty)
    }

    func testCoherentGroupRemainsStableOnEqualSizeTie() async {
        var sync = CameraLiveSynchronization()
        _ = sync.targets(for: [head("a", 100), head("b", 101)], now: 10)
        XCTAssertEqual(sync.targets(for: [head("a", 100), head("b", 101), head("c", 900), head("d", 901)], now: 10), ["a": 100, "b": 100])
    }

    private func frame(_ index: Int, utc: Double? = nil, generation: UInt32 = 1) -> HBMediaFrame {
        .init(type: .videoAccessUnit, flags: index == 0 ? [.keyFrame] : [], sequence: UInt64(index + 1),
              presentationTimestamp: UInt64(index), generation: generation, payload: Data([0, 0, 0, 2, 0x65, 1]), cameraUTC: utc)
    }

    func testLivePresentationDelaysWithoutEnteringHistoryAndNeverRewindsOnRejoin() async throws {
        var timeline = CameraLivePlaybackTimeline(clock: { 10 })
        timeline.configure(generation: 1, timeScale: 10)
        for index in 0...30 { timeline.receive(frame(index, utc: 100 + Double(index) / 10), advancesLivePosition: false) }
        XCTAssertEqual(timeline.head, 3)
        XCTAssertNil(timeline.position)
        timeline.synchronizeLive(cameraTarget: 101)
        XCTAssertEqual(timeline.position, 1)
        guard case .frames(let frames, let reset) = timeline.presentation(includeLive: true) else { return XCTFail("Missing initial preroll") }
        XCTAssertTrue(reset)
        XCTAssertEqual(frames.last?.cameraUTC, 101)
        XCTAssertTrue(timeline.isLive)
        timeline.receive(frame(31, utc: 103.1), advancesLivePosition: false)
        XCTAssertEqual(timeline.head, 3.1)
        XCTAssertEqual(timeline.position, 1, "Reception must not advance the held picture")
        timeline.synchronizeLive(cameraTarget: nil) // Stalled peer was excluded.
        XCTAssertEqual(timeline.position, 3.1)
        guard case .frames(let catchup, _) = timeline.presentation(includeLive: true) else { return XCTFail("Missing release") }
        XCTAssertEqual(catchup.first?.sequence, 12)
        XCTAssertEqual(catchup.last?.sequence, 32)
        timeline.synchronizeLive(cameraTarget: 102) // Peer returns behind what we already showed.
        XCTAssertEqual(timeline.position, 3.1)
        guard case .unchanged = timeline.presentation(includeLive: true) else { return XCTFail("Rejoin rewound playback") }
    }

    func testInitialAheadCameraWaitsAndMissingMetadataStillPlays() async {
        var timeline = CameraLivePlaybackTimeline(clock: { 10 })
        timeline.configure(generation: 1, timeScale: 10)
        timeline.receive(frame(0, utc: 101), advancesLivePosition: false)
        timeline.synchronizeLive(cameraTarget: 100)
        guard case .unchanged = timeline.presentation(includeLive: true) else { return XCTFail("Showed future picture") }
        timeline.synchronizeLive(cameraTarget: nil)
        guard case .frames = timeline.presentation(includeLive: true) else { return XCTFail("Fallback did not play") }
        XCTAssertTrue(timeline.isLive)
    }

    func testReconnectedGenerationCannotUseOldClockFrames() async {
        var now = 10.0
        var timeline = CameraLivePlaybackTimeline(clock: { now })
        timeline.configure(generation: 1, timeScale: 10)
        timeline.receive(frame(0, utc: 100), advancesLivePosition: false)
        timeline.synchronizeLive(cameraTarget: 100)
        _ = timeline.presentation(includeLive: true)
        now = 12
        timeline.configure(generation: 2, timeScale: 10)
        timeline.receive(frame(0, utc: 102, generation: 2), advancesLivePosition: false)
        timeline.synchronizeLive(cameraTarget: 102)
        guard case .frames(let frames, let reset) = timeline.presentation(includeLive: true) else { return XCTFail("Missing recovered frame") }
        XCTAssertTrue(reset)
        XCTAssertEqual(frames.map(\.generation), [2])
        XCTAssertGreaterThan(timeline.position ?? 0, 0)
        XCTAssertTrue(timeline.isLive)
    }

    func testBufferPressureReleasesDelayInsteadOfWaitingForEvictedFrames() async {
        var timeline = CameraLivePlaybackTimeline(maximumBytes: 12, clock: { 10 })
        timeline.configure(generation: 1, timeScale: 10)
        for index in 0...10 {
            var value = frame(index, utc: 100 + Double(index) / 10)
            value.flags = [.keyFrame]
            timeline.receive(value, advancesLivePosition: false)
        }
        timeline.synchronizeLive(cameraTarget: 100)
        XCTAssertEqual(timeline.position, timeline.head)
        guard case .frames = timeline.presentation(includeLive: true) else { return XCTFail("Pressure left live video stalled") }
        XCTAssertTrue(timeline.isLive)
    }
}
