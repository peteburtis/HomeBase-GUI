import AVFoundation
import Foundation
import HomeBaseProtocol
import VideoToolbox
import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraS3PlaybackIntegrationTests: XCTestCase {
    private let cameraID = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"

    func testAbsoluteArchiveSeekWorksWhenLocalLiveAnchorIsOffline() async throws {
        for paused in [true, false] {
            let local = S3PlaybackSource(offline: true)
            let cloud = S3PlaybackSource()
            let fallback = CameraHistoryFallback(local: local, remote: cloud)
            let history = CameraHistoryPlayback(clock: { 0 })
            defer { history.close() }
            history.configure(cameraID: cameraID, transport: fallback)
            history.enter(canonicalTime: 940.125, localHead: 14, paused: paused)
            try await settled(history)
            XCTAssertEqual(history.state, .ready)
            XCTAssertEqual(history.position, 940.125, "Fallback must preserve the exact absolute selection")
            XCTAssertEqual(history.isPaused, paused)
            XCTAssertNotNil(history.buffer.location(at: 940.125))
            let localCalls = await local.requests, cloudCalls = await cloud.requests
            XCTAssertEqual(localCalls.first?.operation, "availability")
            XCTAssertEqual(localCalls.first?.relativeTo, "live")
            XCTAssertTrue(localCalls.contains { $0.operation == "frames" && $0.relativeTo == nil })
            XCTAssertEqual(cloudCalls.count, 1)
            XCTAssertNil(cloudCalls.first?.relativeTo)
            XCTAssertEqual(cloudCalls.first?.range.start, 910.125)
            XCTAssertEqual(cloudCalls.first?.range.end, 970.125)
        }
    }

    func testOfflineRelativeSeekDoesNotInventAnS3LiveAnchor() async throws {
        let local = S3PlaybackSource(offline: true), cloud = S3PlaybackSource()
        let history = CameraHistoryPlayback(clock: { 0 })
        defer { history.close() }
        history.configure(cameraID: cameraID, transport: CameraHistoryFallback(local: local, remote: cloud))
        history.enter(localPosition: 15, localHead: 45, paused: true)
        try await settled(history)
        guard case .failed = history.state else { return XCTFail("Unknown camera clock must stay unresolved") }
        XCTAssertNil(history.canonicalOffset)
        XCTAssertTrue(history.buffer.batches.isEmpty)
        let calls = await cloud.requests
        XCTAssertTrue(calls.isEmpty)
    }

    func testReplacingLocalGapsWithAuthenticatedSourcePreservesCursorAndPause() async throws {
        for paused in [true, false] {
            let local = S3PlaybackSource(gaps: true), cloud = S3PlaybackSource()
            let history = CameraHistoryPlayback(clock: { 0 })
            defer { history.close() }
            history.configure(cameraID: cameraID, transport: local)
            history.enter(canonicalTime: 940.125, localHead: 0, paused: paused)
            try await settled(history)
            XCTAssertEqual(history.state, .gap)
            XCTAssertTrue(history.buffer.isKnown(940.125, now: 0, liveEdge: 1000))
            XCTAssertFalse(history.buffer.batches.isEmpty)
            let cursor = history.position
            history.replaceSource(cameraID: cameraID, transport: cloud)
            XCTAssertTrue(history.buffer.batches.isEmpty, "Known local gaps must not suppress S3 reads after credential repair")
            XCTAssertEqual(history.position, cursor)
            XCTAssertEqual(history.isPaused, paused)
            try await settled(history)
            XCTAssertEqual(history.state, .ready)
            XCTAssertEqual(history.position, cursor)
            XCTAssertEqual(history.isPaused, paused)
            XCTAssertNotNil(history.buffer.location(at: 940.125))
            let oldClosed = await local.closeCount, newRequests = await cloud.requests
            XCTAssertGreaterThan(oldClosed, 0)
            XCTAssertEqual(newRequests.first?.operation, "frames")
            XCTAssertNil(newRequests.first?.relativeTo)
            XCTAssertEqual(newRequests.first?.range.start, 910.125)
            XCTAssertEqual(newRequests.first?.range.end, 970.125)
        }
    }

    func testRevocationDropsCloudAndLiveBuffersResetsRendererAndPreservesPausedCursor() async throws {
        let fixture = try S3PlaybackPicture.make()
        let source = S3PlaybackSource(picture: fixture)
        let controller = CameraLivePlaybackController(clock: { 0 })
        defer { controller.close() }
        let owner = UUID()
        _ = try controller.configure(fixture.configuration, ownerID: owner)
        _ = try controller.receive(fixture.liveFrame(sequence: 0), ownerID: owner)
        XCTAssertFalse(controller.timeline.entries.isEmpty)
        controller.setNVRHistoryAvailable(true)
        controller.history.configure(cameraID: cameraID, transport: source)
        controller.seek(to: Date(timeIntervalSince1970: 940), paused: false)
        try await settled(controller.history)
        XCTAssertGreaterThan(controller.history.buffer.bytes, 0)
        let location = try XCTUnwrap(controller.history.buffer.location(at: 940))
        try controller.renderer.configureHistory(location.piece.segment)
        XCTAssertNotNil(try controller.renderer.enqueueHistory(location.piece.samples[0], segment: location.piece.segment, display: true))
        let cursor = controller.history.position

        controller.revokeCameraAccess()
        XCTAssertTrue(controller.isPaused)
        XCTAssertTrue(controller.isUsingHistory)
        XCTAssertEqual(controller.history.position, cursor)
        XCTAssertEqual(controller.history.buffer.bytes, 0)
        XCTAssertTrue(controller.history.buffer.batches.isEmpty)
        XCTAssertEqual(controller.timeline.retainedBytes, 0)
        XCTAssertTrue(controller.timeline.entries.isEmpty)
        // Reset restores keyframe gating and flushes the display. It cannot
        // continue rendering dependent samples from the prior authenticated GOP.
        let old = location.piece.samples[0]
        let dependent = CameraHistorySample(frame: .init(segment: old.frame.segment,
            presentationTicks: old.frame.presentationTicks + old.frame.durationTicks,
            decodeTicks: nil, durationTicks: old.frame.durationTicks, keyFrame: false,
            preroll: false, byteCount: old.data.count), data: old.data)
        XCTAssertNil(try controller.renderer.enqueueHistory(dependent, segment: location.piece.segment, display: true))
        XCTAssertNil(try controller.receive(fixture.liveFrame(sequence: 1), ownerID: owner), "An old live callback cannot repopulate the locked page")
        XCTAssertTrue(controller.timeline.entries.isEmpty)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(controller.renderer.layer.sampleBufferRenderer.displayedPixelBuffer())
        let closed = await source.closeCount
        XCTAssertGreaterThan(closed, 0)
    }

    func testRevocationRejectsLateCloudCompletionAndUnlockCanRefillSamePausedCursor() async throws {
        let controller = CameraLivePlaybackController(clock: { 0 })
        defer { controller.close() }
        let source = S3PlaybackSource(holdFrames: true)
        controller.setNVRHistoryAvailable(true)
        controller.history.configure(cameraID: cameraID, transport: source)
        controller.seek(to: Date(timeIntervalSince1970: 940), paused: false)
        for _ in 0..<100 {
            if await source.hasHeldFrame { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let held = await source.hasHeldFrame
        XCTAssertTrue(held)
        controller.revokeCameraAccess()
        await source.releaseFrames() // Deliberately ignores transport cancellation.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(controller.history.buffer.batches.isEmpty)
        XCTAssertEqual(controller.history.position, 940)
        XCTAssertTrue(controller.isPaused)
        controller.resume()
        controller.history.replaceSource(cameraID: cameraID, transport: S3PlaybackSource())
        try await settled(controller.history)
        XCTAssertEqual(controller.history.position, 940)
        XCTAssertTrue(controller.isPaused)
        XCTAssertGreaterThan(controller.history.buffer.bytes, 0)
    }

    private func settled(_ history: CameraHistoryPlayback) async throws {
        for _ in 0..<200 {
            if !history.fetching, history.state != .loading { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("History did not settle: \(history.state)")
    }
}

private actor S3PlaybackSource: CameraHistoryFetching {
    let offline: Bool, gaps: Bool, holdFrames: Bool
    let picture: S3PlaybackPicture?
    private(set) var requests: [HBNVRMediaRequest] = []
    private(set) var closeCount = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    var hasHeldFrame: Bool { !held.isEmpty }
    init(offline: Bool = false, gaps: Bool = false, holdFrames: Bool = false, picture: S3PlaybackPicture? = nil) {
        self.offline = offline; self.gaps = gaps; self.holdFrames = holdFrames; self.picture = picture
    }
    func start() {}
    func close() { closeCount += 1 }
    func releaseFrames() { let waiting = held; held = []; waiting.forEach { $0.resume() } }
    func fetch(_ request: HBNVRMediaRequest, onBegin: CameraHistoryBeginHandler?) async throws -> CameraHistoryBatch {
        requests.append(request)
        if offline { throw CameraHistoryError.unavailable }
        let anchor: Double? = request.relativeTo == nil ? nil : 1000
        let range = CameraHistoryRange(start: request.range.start + (anchor ?? 0), end: request.range.end + (anchor ?? 0))
        await onBegin?(range, anchor)
        if request.operation == "neighbors" {
            return .init(id: UUID(), range: range, anchor: anchor, pieces: [], gaps: [], neighbors: .init(previous: nil, next: nil))
        }
        if request.operation == "availability" || gaps {
            return .init(id: UUID(), range: range, anchor: anchor, pieces: [], gaps: [range])
        }
        if holdFrames { await withCheckedContinuation { held.append($0) } }
        let segment = CameraHistorySegment(number: 0, range: range,
            time: .init(canonicalUTC: range.start, receivedUTC: range.start, cameraUTC: nil,
                canonicalSource: "received", epochID: UUID().uuidString), timescale: 90_000, codec: "H264",
            parameterSets: picture?.sets ?? [Data([1]), Data([2])], nalUnitLengthBytes: 4)
        let bytes = picture?.data ?? Data([0, 0, 0, 1, 0x65])
        let samples: [CameraHistorySample] = (0..<Int(ceil(range.duration))).map { index in
            .init(frame: .init(segment: 0, presentationTicks: Int64(index * 90_000), decodeTicks: nil,
                durationTicks: 90_000, keyFrame: true, preroll: false, byteCount: bytes.count), data: bytes)
        }
        return .init(id: UUID(), range: range, anchor: anchor,
            pieces: [.init(id: UUID(), segment: segment, samples: samples)], gaps: [])
    }
}

private nonisolated struct S3PlaybackPicture: Sendable {
    let sets: [Data]
    let data: Data
    var configuration: HBMediaStreamConfiguration {
        .init(generation: 1, quality: .low, width: 64, height: 64, frameRate: 15,
            sequenceParameterSet: sets[0].base64EncodedString(), pictureParameterSet: sets[1].base64EncodedString())
    }
    func liveFrame(sequence: UInt64) -> HBMediaFrame {
        .init(type: .videoAccessUnit, flags: [.keyFrame], sequence: sequence,
            presentationTimestamp: sequence * 6000, generation: 1, payload: data)
    }
    @MainActor static func make() throws -> Self {
        let sink = S3PlaybackEncodedPicture()
        var optional: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: 64, height: 64, codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { context, _, status, _, sample in
                if status == noErr, let context, let sample {
                    Unmanaged<S3PlaybackEncodedPicture>.fromOpaque(context).takeUnretainedValue().set(sample)
                }
            }, refcon: Unmanaged.passUnretained(sink).toOpaque(), compressionSessionOut: &optional)
        guard status == noErr, let encoder = optional else { throw XCTSkip("Synthetic H.264 encoding unavailable: \(status)") }
        defer { VTCompressionSessionInvalidate(encoder) }
        XCTAssertEqual(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse), noErr)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel), noErr)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 80, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertEqual(VTCompressionSessionEncodeFrame(encoder, imageBuffer: buffer, presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 15), frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil), noErr)
        XCTAssertEqual(VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid), noErr)
        let sample = try XCTUnwrap(sink.get()), format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        var sets: [Data] = []
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?, count = 0
            XCTAssertEqual(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &count, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil), noErr)
            sets.append(Data(bytes: try XCTUnwrap(pointer), count: count))
        }
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        var data = Data(count: CMBlockBufferGetDataLength(block))
        XCTAssertEqual(data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }, noErr)
        return Self(sets: sets, data: data)
    }
}

private nonisolated final class S3PlaybackEncodedPicture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CMSampleBuffer?
    func set(_ sample: CMSampleBuffer) { lock.lock(); value = sample; lock.unlock() }
    func get() -> CMSampleBuffer? { lock.lock(); defer { lock.unlock() }; return value }
}
