import AVFoundation
import HomeBaseProtocol
import VideoToolbox
import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraLivePlaybackTests: XCTestCase {
    func testLiveImmediatelyBuffersAndPauseKeepsReceiving() {
        var timeline = configured()
        for second in 0...120 { timeline.receive(frame(second)) }
        XCTAssertEqual(timeline.retainedBytes, 121 * 5)
        XCTAssertEqual(timeline.entries.count, 121)
        timeline.pause()
        timeline.receive(frame(121, key: false))
        XCTAssertEqual(timeline.entries.count, 122)
        timeline.receive(frame(122))
        timeline.receive(frame(123, key: false))
        XCTAssertEqual(timeline.mode, .paused)
        XCTAssertEqual(timeline.position, 120)
        XCTAssertEqual(timeline.head, 123)
        XCTAssertEqual(timeline.tail, 0)
        XCTAssertEqual(timeline.retainedBytes, 124 * 5)
    }

    func testReturningLiveKeepsCollectingAndCanImmediatelyRewindAgain() {
        var timeline = buffered()
        let bytes = timeline.retainedBytes
        timeline.goLive()
        XCTAssertTrue(timeline.isLive)
        XCTAssertEqual(timeline.position, timeline.head)
        XCTAssertEqual(timeline.retainedBytes, bytes)
        timeline.receive(frame(11))
        timeline.pause()
        timeline.receive(frame(12, key: false))
        XCTAssertEqual(timeline.retainedBytes, bytes + 10)
        timeline.seek(by: -30)
        XCTAssertEqual(timeline.position, 0)
        guard case .frames(let frames, _) = timeline.presentation() else { return XCTFail() }
        XCTAssertEqual(frames.map(\.sequence), [0])
        timeline.reset()
        XCTAssertTrue(timeline.entries.isEmpty)
        XCTAssertEqual(timeline.retainedBytes, 0)
        XCTAssertFalse(timeline.canControlPlayback)
    }

    func testSeekBeforeTailShowsBlackButIsNotClampedToTail() {
        var timeline = buffered()
        timeline.hasAvailableNVRHistory = true
        timeline.seek(by: -30)
        XCTAssertEqual(timeline.position, -30)
        XCTAssertEqual(timeline.mode, .paused)
        guard case .black = timeline.presentation() else {
            return XCTFail("Unavailable positions must clear the picture")
        }
        guard case .unchanged = timeline.presentation() else {
            return XCTFail("Black should not continuously flush the decoder")
        }
        timeline.seek(by: 35)
        guard case .frames(let frames, let reset) = timeline.presentation() else {
            return XCTFail("Seeking back into retained footage must recover")
        }
        XCTAssertTrue(reset)
        XCTAssertEqual(frames.map(\.sequence), [4, 5])
    }

    func testPausedForwardWithinBufferStaysPaused() {
        var timeline = buffered()
        timeline.seek(by: 5)
        XCTAssertEqual(timeline.position, 5)
        XCTAssertEqual(timeline.mode, .paused)
        timeline.advance(by: 500)
        XCTAssertEqual(timeline.position, 5)
        timeline.receive(frame(11))
        XCTAssertEqual(timeline.position, 5)
        XCTAssertEqual(timeline.head, 11)
    }

    func testForwardToOrPastHeadStaysPausedButReturnsLiveWhenPlaying() {
        for playing in [false, true] {
            for distance: TimeInterval in [10, 30] {
                var timeline = buffered()
                if playing { timeline.play() }
                timeline.seek(by: distance)
                XCTAssertEqual(timeline.mode, playing ? .live : .paused)
                XCTAssertEqual(timeline.position, timeline.head)
                let bytes = timeline.retainedBytes
                XCTAssertGreaterThan(bytes, 0)
                timeline.receive(frame(11))
                XCTAssertEqual(timeline.position, playing ? 11 : 10)
                XCTAssertEqual(timeline.retainedBytes, bytes + 5)
            }
        }
    }

    func testPlayingUsesElapsedTimeAndNeverPassesReceivedHead() {
        var timeline = buffered()
        timeline.seek(by: 3)
        timeline.play()
        timeline.advance(by: 0.5)
        XCTAssertEqual(timeline.position, 3.5)
        timeline.advance(by: 100)
        XCTAssertEqual(timeline.position, 10)
        XCTAssertEqual(timeline.mode, .playing)
        XCTAssertFalse(timeline.isLive)
        timeline.receive(frame(11))
        timeline.advance(by: 0.25)
        XCTAssertEqual(timeline.position, 10.25)
    }

    func testRewindBeyondInitialBufferDoesNotInventNVRHistory() {
        var timeline = configured()
        timeline.hasAvailableNVRHistory = true
        timeline.receive(frame(0))
        timeline.seek(by: -30)
        XCTAssertEqual(timeline.mode, .playing)
        XCTAssertEqual(timeline.entries.count, 1)
        guard case .black = timeline.presentation() else { return XCTFail() }
        timeline.receive(frame(1))
        XCTAssertEqual(timeline.tail, 0)
    }

    func testBufferOnlyRewindClampsToFirstDecodableFrameAndDisablesWhilePaused() {
        var timeline = buffered()
        timeline.seek(by: 5)
        XCTAssertTrue(timeline.canSeekBackward)
        timeline.seek(by: -30)
        XCTAssertEqual(timeline.position, timeline.tail)
        XCTAssertEqual(timeline.mode, .paused)
        XCTAssertFalse(timeline.canSeekBackward)
        guard case .frames(let frames, let reset) = timeline.presentation() else {
            return XCTFail("A buffer-only rewind must display the oldest picture, not black")
        }
        XCTAssertTrue(reset)
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames[0].flags.contains(.keyFrame))
        timeline.receive(frame(11))
        XCTAssertFalse(timeline.canSeekBackward, "Receiving more video must not move a paused cursor")
        timeline.play()
        timeline.advance(by: 0.01)
        XCTAssertTrue(timeline.canSeekBackward)
        timeline.pause()
        XCTAssertTrue(timeline.canSeekBackward, "Even a short advance allows rewind")
        timeline.seek(by: -30)
        XCTAssertFalse(timeline.canSeekBackward)
    }

    func testBufferOnlyPlayingRewindClampsWithoutPausing() {
        var timeline = buffered()
        timeline.play()
        timeline.seek(by: -30)
        XCTAssertEqual(timeline.position, timeline.tail)
        XCTAssertEqual(timeline.mode, .playing)
        XCTAssertTrue(timeline.canSeekBackward)
    }

    func testBufferOnlyRewindFromLiveWaitsForFirstKeyframe() {
        var timeline = configured()
        timeline.receive(frame(0, key: false))
        timeline.seek(by: -30)
        XCTAssertEqual(timeline.position, 0)
        XCTAssertEqual(timeline.mode, .playing)
        XCTAssertTrue(timeline.entries.isEmpty)
        guard case .unchanged = timeline.presentation() else { return XCTFail() }
        timeline.receive(frame(1, key: false))
        timeline.advance(by: 0.1)
        timeline.receive(frame(2))
        timeline.advance(by: 0.1)
        XCTAssertEqual(timeline.position, 2)
        guard case .frames(let frames, _) = timeline.presentation() else { return XCTFail() }
        XCTAssertEqual(frames.map(\.sequence), [2])
    }

    func testBufferOnlyPauseWithoutFramesAndEvictionKeepBackAvailabilityAccurate() {
        var timeline = configured(duration: 3)
        timeline.receive(frame(0, key: false))
        timeline.pause()
        XCTAssertFalse(timeline.canSeekBackward)
        timeline.receive(frame(1))
        timeline.receive(frame(2))
        timeline.seek(by: -30)
        XCTAssertEqual(timeline.position, 1)
        for second in 3...10 { timeline.receive(frame(second)) }
        XCTAssertFalse(timeline.canSeekBackward)
        timeline.play()
        XCTAssertEqual(timeline.position, timeline.tail)
        timeline.discardBuffer()
        timeline.pause()
        XCTAssertFalse(timeline.canSeekBackward)
    }

    func testNVRHistoryLeavesOlderSeeksEnabledAndCanBecomeUnavailable() {
        var timeline = buffered()
        timeline.hasAvailableNVRHistory = true
        timeline.seek(by: -30)
        XCTAssertEqual(timeline.position, -30)
        XCTAssertTrue(timeline.canSeekBackward)
        timeline.hasAvailableNVRHistory = false
        XCTAssertFalse(timeline.canSeekBackward)
        timeline.play()
        XCTAssertEqual(timeline.position, timeline.tail)
        timeline.pause()
        timeline.hasAvailableNVRHistory = true
        XCTAssertTrue(timeline.canSeekBackward)
        timeline.seek(by: -30)
        XCTAssertLessThan(timeline.position!, timeline.tail!)
    }

    func testHistoryGateUsesReadableCameraAdvertisementNotRecordingControl() throws {
        XCTAssertFalse(CameraPlaybackHistoryAvailability.isAvailable(in: [:]))
        XCTAssertFalse(CameraPlaybackHistoryAvailability.isAvailable(in: ["NVR.recording": .bool(true)]))
        let available = HBCameraPlaybackMetadata(nvrInstanceID: UUID().uuidString,
            cameraID: UUID().uuidString, stores: [.init(id: UUID().uuidString, name: "Local")])
        let key = HBDeviceMetadataKeys.cameraPlayback
        var metadata = [key: try HBJSONValue(encoding: available)]
        XCTAssertTrue(CameraPlaybackHistoryAvailability.isAvailable(in: metadata))
        var unavailable = available
        unavailable.available = false
        metadata[key] = try HBJSONValue(encoding: unavailable)
        XCTAssertFalse(CameraPlaybackHistoryAvailability.isAvailable(in: metadata))
        var object = try XCTUnwrap(HBJSONValue(encoding: available).objectValue)
        for (field, value): (String, HBJSONValue) in [
            ("stores", .array([])), ("provider", .string("other")),
            ("cameraID", .string("bad-id")), ("mediaProtocolVersion", .integer(2))
        ] {
            var invalid = object
            invalid[field] = value
            XCTAssertFalse(CameraPlaybackHistoryAvailability.isAvailable(in: [key: .object(invalid)]))
        }
        object.removeValue(forKey: "available")
        XCTAssertFalse(CameraPlaybackHistoryAvailability.isAvailable(in: [key: .object(object)]))
    }

    func testForwardFromLiveIsNoOp() {
        var timeline = configured()
        timeline.receive(frame(0))
        timeline.seek(by: 30)
        XCTAssertTrue(timeline.isLive)
        XCTAssertEqual(timeline.position, timeline.head)
        XCTAssertEqual(timeline.entries.count, 1)
        guard case .unchanged = timeline.presentation() else { return XCTFail() }
    }

    func testSeekPrerollsFromPrecedingKeyframeAndContinuousPlayDoesNotReset() {
        var timeline = buffered()
        timeline.seek(by: 3)
        guard case .frames(let frames, let reset) = timeline.presentation() else {
            return XCTFail()
        }
        XCTAssertTrue(reset)
        XCTAssertEqual(frames.map(\.sequence), [2, 3])
        timeline.play()
        timeline.advance(by: 2)
        guard case .frames(let next, let resetsAgain) = timeline.presentation() else {
            return XCTFail()
        }
        XCTAssertFalse(resetsAgain)
        XCTAssertEqual(next.map(\.sequence), [4, 5])
        guard case .unchanged = timeline.presentation() else { return XCTFail() }
    }

    func testDurationEvictionUsesWholeGOPsAndLeavesPausedPositionAlone() {
        var timeline = configured(duration: 4)
        timeline.receive(frame(0))
        timeline.pause()
        for second in 1...10 {
            timeline.receive(frame(second, key: second % 2 == 0))
        }
        XCTAssertEqual(timeline.tail, 6)
        XCTAssertEqual(timeline.position, 0)
        XCTAssertTrue(timeline.entries.first!.frame.flags.contains(.keyFrame))
        guard case .black = timeline.presentation() else { return XCTFail() }
    }

    func testByteAndMetadataLimitsDropUndecodableGOPRatherThanGrowingForever() {
        var timeline = configured(bytes: 12)
        timeline.receive(frame(0))
        timeline.pause()
        timeline.receive(frame(1))
        timeline.receive(frame(2, key: false))
        XCTAssertEqual(timeline.retainedBytes, 10)
        timeline.receive(frame(3, key: false))
        XCTAssertEqual(timeline.retainedBytes, 0)
        timeline.receive(frame(4, key: false))
        XCTAssertEqual(timeline.retainedBytes, 0)
        timeline.receive(frame(5))
        XCTAssertEqual(timeline.tail, 5)

        var countLimited = CameraLivePlaybackTimeline(maximumFrames: 2)
        countLimited.configure(generation: 1, timeScale: 1)
        countLimited.receive(frame(0))
        countLimited.pause()
        for second in 1...10 {
            countLimited.receive(frame(second))
            XCTAssertLessThanOrEqual(countLimited.entries.count, 2)
        }
    }

    func testEvictionDuringPlaybackResynchronizesAtRetainedKeyframe() {
        var timeline = configured(duration: 3)
        timeline.receive(frame(0))
        timeline.pause()
        timeline.receive(frame(1))
        timeline.receive(frame(2))
        timeline.seek(by: 1)
        _ = timeline.presentation()
        for second in 3...10 { timeline.receive(frame(second)) }
        timeline.seek(by: 8)
        guard case .frames(let frames, let reset) = timeline.presentation() else {
            return XCTFail()
        }
        XCTAssertTrue(reset)
        XCTAssertTrue(frames[0].flags.contains(.keyFrame))
        XCTAssertEqual(frames.last?.sequence, 9)
    }

    func testNewGenerationAndBackwardsClockKeepDistinctDecodableHistory() {
        var timeline = buffered()
        let firstEpoch = timeline.sourceEpoch
        XCTAssertTrue(timeline.receive(frame(2)))
        XCTAssertEqual(timeline.mode, .paused)
        XCTAssertEqual(timeline.entries.count, 12)
        XCTAssertEqual(timeline.head, 11)
        XCTAssertNotEqual(timeline.sourceEpoch, firstEpoch)
        timeline.configure(generation: 2, timeScale: 1)
        timeline.receive(frame(50)) // old generation
        XCTAssertEqual(timeline.head, 11)
        var next = frame(0, key: false)
        next.generation = 2
        timeline.receive(next)
        XCTAssertEqual(timeline.head, 12)
        XCTAssertEqual(timeline.entries.count, 12, "A new epoch must wait for its own keyframe")
        next = frame(1)
        next.generation = 2
        timeline.receive(next)
        XCTAssertEqual(timeline.entries.count, 13)
        timeline.seek(by: 5)
        guard case .frames(let old, _) = timeline.presentation() else { return XCTFail() }
        XCTAssertEqual(timeline.presentationEpoch, firstEpoch)
        XCTAssertEqual(old.map(\.sequence), [4, 5])
        timeline.seek(by: 8)
        guard case .frames(let recent, let reset) = timeline.presentation() else { return XCTFail() }
        XCTAssertTrue(reset)
        XCTAssertEqual(timeline.presentationEpoch, timeline.sourceEpoch)
        XCTAssertEqual(recent.map(\.generation), [2])
    }

    func testFiveMinuteLimitAppliesWhileContinuouslyLive() {
        var timeline = configured()
        for second in 0...900 { timeline.receive(frame(second)) }
        XCTAssertTrue(timeline.isLive)
        XCTAssertEqual(timeline.head, 900)
        XCTAssertEqual(timeline.tail, 600)
        XCTAssertEqual(timeline.entries.count, 301)
        timeline.seek(by: -30)
        XCTAssertEqual(timeline.position, 870)
        guard case .frames(let frames, _) = timeline.presentation() else { return XCTFail() }
        XCTAssertEqual(frames.last?.sequence, 870)
    }

    func testReconnectGapUsesMonotonicArrivalClockAndRepeatedSequencesAreDistinct() {
        var now: TimeInterval = 10
        var timeline = CameraLivePlaybackTimeline(clock: { now })
        timeline.configure(generation: 1, timeScale: 1)
        timeline.receive(frame(0))
        now = 11
        timeline.receive(frame(1))
        let oldEpoch = timeline.sourceEpoch
        timeline.configure(generation: 1, timeScale: 1) // lease IDs may repeat
        now = 20
        timeline.receive(frame(0))
        XCTAssertEqual(timeline.head, 10)
        XCTAssertEqual(timeline.entries.map(\.time), [0, 1, 10])
        XCTAssertNotEqual(timeline.sourceEpoch, oldEpoch)
        timeline.pause()
        timeline.seek(by: -10)
        _ = timeline.presentation()
        XCTAssertEqual(timeline.presentationEpoch, oldEpoch)
        timeline.seek(by: 10)
        guard case .frames(_, let reset) = timeline.presentation() else { return XCTFail() }
        XCTAssertTrue(reset)
        XCTAssertEqual(timeline.presentationEpoch, timeline.sourceEpoch)
    }

    func testTimescaleUsesRelativeIntegersWithoutLosingLargeTimestampPrecision() {
        var timeline = configured()
        timeline.configure(generation: 1, timeScale: 90_000)
        let origin = UInt64.max - 1_000_000
        var first = frame(0)
        first.presentationTimestamp = origin
        timeline.receive(first)
        timeline.pause()
        var next = frame(1)
        next.presentationTimestamp = origin + 3_000
        timeline.receive(next)
        XCTAssertEqual(timeline.head!, 1.0 / 30, accuracy: 0.000_001)
    }

    func testMemoryPressureKeepsNewestGOPAndContinuesCollecting() {
        var timeline = buffered()
        timeline.trimForMemoryPressure()
        XCTAssertEqual(timeline.mode, .paused)
        XCTAssertEqual(timeline.position, 0)
        XCTAssertEqual(timeline.retainedBytes, 5)
        timeline.receive(frame(11, key: false))
        XCTAssertEqual(timeline.entries.count, 2)
        timeline.receive(frame(12))
        XCTAssertEqual(timeline.tail, 10)
        timeline.goLive()
        timeline.trimForMemoryPressure()
        timeline.receive(frame(13, key: false))
        XCTAssertEqual(timeline.tail, 12)
        XCTAssertEqual(timeline.entries.count, 2)
    }

    func testIdleControlsAndNonfiniteSeeksAreHarmless() {
        var timeline = configured()
        timeline.pause()
        timeline.play()
        timeline.seek(by: -30)
        XCTAssertTrue(timeline.isLive)
        timeline.receive(frame(0))
        timeline.seek(by: .nan)
        timeline.seek(by: .infinity)
        XCTAssertTrue(timeline.isLive)
    }

    func testControllerKeepsPhotosSamplesLiveOnlyAndIgnoresOldOwner() async throws {
        let fixture = try video()
        let controller = CameraLivePlaybackController()
        let owner = UUID()
        _ = try controller.configure(fixture.configuration, ownerID: owner)
        XCTAssertNotNil(try controller.receive(fixture.frames[0], ownerID: owner))
        XCTAssertGreaterThan(controller.timeline.retainedBytes, 0)
        XCTAssertTrue(controller.canSeekBackward)
        controller.togglePause()
        XCTAssertFalse(controller.canSeekBackward)
        for frame in fixture.frames.dropFirst() {
            XCTAssertNil(try controller.receive(frame, ownerID: owner))
        }
        XCTAssertTrue(controller.isPaused)
        XCTAssertGreaterThan(controller.timeline.retainedBytes, 0)
        controller.setNVRHistoryAvailable(true)
        XCTAssertTrue(controller.canSeekBackward)
        controller.setNVRHistoryAvailable(false)
        XCTAssertFalse(controller.canSeekBackward)
        controller.stop(ownerID: UUID())
        XCTAssertTrue(controller.isPaused)
        controller.seek(by: 2)
        XCTAssertTrue(controller.isPaused)
        XCTAssertTrue(controller.canSeekBackward)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(controller.errorMessage)
        XCTAssertNotEqual(controller.renderer.layer.sampleBufferRenderer.status, .failed)
        controller.seek(by: 30)
        XCTAssertTrue(controller.isPaused)
        XCTAssertEqual(controller.timeline.position, controller.timeline.head)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(controller.errorMessage)
        controller.goLive()
        XCTAssertTrue(controller.isLive)
        XCTAssertGreaterThan(controller.timeline.retainedBytes, 0)
        // A decoder reset must never resume on a dependent picture.
        XCTAssertNil(try controller.receive(fixture.frames.last!, ownerID: owner))
        controller.stop(ownerID: owner)
        XCTAssertGreaterThan(controller.timeline.retainedBytes, 0)
        controller.close()
        XCTAssertFalse(controller.canControlPlayback)
        XCTAssertFalse(controller.canSeekBackward)
        XCTAssertEqual(controller.timeline.retainedBytes, 0)
    }

    func testRendererMarksPrerollDecodeOnlyAndFlushRequiresKeyframe() async throws {
        let fixture = try video()
        let renderer = CameraH264Renderer()
        _ = try renderer.configure(fixture.configuration)
        let hidden = try XCTUnwrap(renderer.enqueue(fixture.frames[0], display: false))
        let visible = try XCTUnwrap(renderer.enqueue(fixture.frames[1]))
        func hiddenFlag(_ sample: CMSampleBuffer) -> Bool? {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample, createIfNecessary: false
            ) as? [[String: Any]]
            return attachments?.first?[kCMSampleAttachmentKey_DoNotDisplay as String] as? Bool
        }
        XCTAssertEqual(hiddenFlag(hidden), true)
        XCTAssertEqual(hiddenFlag(visible), false)
        renderer.reset()
        XCTAssertNil(try renderer.enqueue(fixture.frames[1]))
        XCTAssertNotNil(try renderer.enqueue(fixture.frames[15]))
        // Complete asynchronous renderer work before releasing the renderer;
        // run in a Swift task, as the application's media consumer does.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            renderer.layer.sampleBufferRenderer.flush(removingDisplayedImage: true) {
                continuation.resume()
            }
        }
    }

    func testControllerKeepsHistoryAcrossLeasesAndReplaysWithOriginalConfiguration() async throws {
        let oldVideo = try video()
        let newVideo = try video(width: 128, generation: 2)
        let controller = CameraLivePlaybackController()
        let oldOwner = UUID(), newOwner = UUID()
        _ = try controller.configure(oldVideo.configuration, ownerID: oldOwner)
        for frame in oldVideo.frames { _ = try controller.receive(frame, ownerID: oldOwner) }
        let oldEpoch = controller.timeline.sourceEpoch
        let oldBytes = controller.timeline.retainedBytes
        controller.stop(ownerID: oldOwner)
        XCTAssertEqual(controller.timeline.retainedBytes, oldBytes)
        _ = try controller.configure(newVideo.configuration, ownerID: newOwner)
        for frame in newVideo.frames { _ = try controller.receive(frame, ownerID: newOwner) }
        controller.stop(ownerID: oldOwner) // delayed cleanup from the previous lease
        XCTAssertTrue(controller.isLive)
        XCTAssertGreaterThan(controller.timeline.retainedBytes, oldBytes)
        controller.togglePause()
        controller.seek(by: 2 - controller.timeline.position!)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(controller.timeline.presentationEpoch, oldEpoch)
        XCTAssertNil(controller.errorMessage)
        XCTAssertNotEqual(controller.renderer.layer.sampleBufferRenderer.status, .failed)
        let retained = controller.timeline.retainedBytes
        controller.goLive()
        XCTAssertEqual(controller.timeline.retainedBytes, retained)
        var next = newVideo.frames[0]
        next.presentationTimestamp = newVideo.frames.last!.presentationTimestamp + 6_000
        next.sequence = 45
        let sample = try XCTUnwrap(controller.receive(next, ownerID: newOwner))
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(format).width, 128)
        controller.close()
        XCTAssertEqual(controller.timeline.retainedBytes, 0)
        XCTAssertFalse(controller.canControlPlayback)
        XCTAssertNil(try controller.receive(next, ownerID: newOwner))
        XCTAssertThrowsError(try controller.configure(newVideo.configuration, ownerID: UUID()))
    }

    private func configured(duration: Double = 300, bytes: Int = 64 * 1024 * 1024)
        -> CameraLivePlaybackTimeline {
        var timeline = CameraLivePlaybackTimeline(maximumDuration: duration, maximumBytes: bytes, clock: { 0 })
        timeline.configure(generation: 1, timeScale: 1)
        return timeline
    }

    private func buffered() -> CameraLivePlaybackTimeline {
        var timeline = configured()
        timeline.receive(frame(0))
        timeline.pause()
        for second in 1...10 { timeline.receive(frame(second, key: second % 2 == 0)) }
        return timeline
    }

    private func frame(_ second: Int, key: Bool = true) -> HBMediaFrame {
        HBMediaFrame(type: .videoAccessUnit, flags: key ? [.keyFrame] : [],
                     sequence: UInt64(second), presentationTimestamp: UInt64(second),
                     generation: 1, payload: Data([0, 0, 0, 1, key ? 0x65 : 0x41]))
    }

    /// Real synthetic H.264; no camera, network, media files, or Photos writes.
    private func video(width: Int32 = 64, generation: UInt32 = 1) throws -> (configuration: HBMediaStreamConfiguration, frames: [HBMediaFrame]) {
        let sink = PlaybackSampleSink()
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: 64, codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { context, _, status, _, sample in
                guard status == noErr, let context, let sample else { return }
                Unmanaged<PlaybackSampleSink>.fromOpaque(context).takeUnretainedValue().append(sample)
            }, refcon: Unmanaged.passUnretained(sink).toOpaque(), compressionSessionOut: &session
        )
        XCTAssertEqual(status, noErr)
        let encoder = try XCTUnwrap(session)
        defer { VTCompressionSessionInvalidate(encoder) }
        XCTAssertEqual(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering,
                                           value: kCFBooleanFalse), noErr)
        XCTAssertEqual(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                                           value: 15 as CFNumber), noErr)
        for index in 0..<45 {
            var pixel: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, Int(width), 64, kCVPixelFormatType_32BGRA, nil, &pixel), noErr)
            let buffer = try XCTUnwrap(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(index * 5), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertEqual(VTCompressionSessionEncodeFrame(
                encoder, imageBuffer: buffer, presentationTimeStamp: CMTime(value: Int64(index), timescale: 15),
                duration: CMTime(value: 1, timescale: 15), frameProperties: nil,
                sourceFrameRefcon: nil, infoFlagsOut: nil
            ), noErr)
        }
        XCTAssertEqual(VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid), noErr)
        let samples = sink.snapshot()
        XCTAssertEqual(samples.count, 45)
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(try XCTUnwrap(samples.first)))
        var sets: [Data] = []
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            XCTAssertEqual(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ), noErr)
            sets.append(Data(bytes: try XCTUnwrap(pointer), count: size))
        }
        let configuration = HBMediaStreamConfiguration(
            generation: generation, quality: .low, width: Int(width), height: 64, frameRate: 15,
            sequenceParameterSet: sets[0].base64EncodedString(), pictureParameterSet: sets[1].base64EncodedString()
        )
        let frames = try samples.enumerated().map { index, sample in
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var data = Data(count: CMBlockBufferGetDataLength(block))
            XCTAssertEqual(data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }, noErr)
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
            let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false)
            let time = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), timescale: 90_000, method: .default)
            return HBMediaFrame(type: .videoAccessUnit, flags: key ? [.keyFrame] : [], sequence: UInt64(index),
                                presentationTimestamp: UInt64(time.value), generation: generation, payload: data)
        }
        return (configuration, frames)
    }
}

private nonisolated final class PlaybackSampleSink: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [CMSampleBuffer] = []
    func append(_ sample: CMSampleBuffer) { lock.withLock { samples.append(sample) } }
    func snapshot() -> [CMSampleBuffer] { lock.withLock { samples } }
}
