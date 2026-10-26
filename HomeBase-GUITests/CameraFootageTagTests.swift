import Foundation
import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraFootageTagTests: XCTestCase {
    private let camera = UUID().uuidString
    private let instance = UUID().uuidString

    private func eventually(_ predicate: () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Condition did not settle")
    }
    private func change(_ revision: UInt64 = 1) -> HBNVRTagChange {
        .init(instanceID: instance, revision: revision, reset: false,
              ranges: [.init(cameraID: camera, epochID: "epoch", start: 0, end: 2000)])
    }
    private func source(_ raw: TagMediaSource, authority: TagAuthority,
                        stream: AsyncStream<HBNVRTagChange>) async -> CameraTaggedHistorySource {
        let source = CameraTaggedHistorySource(source: raw, updates: stream) { try await authority.read($0) }
        await source.setCamera(camera); await source.observe()
        return source
    }

    func testRefreshPreservesMediaAndAppliesExplicitClearOnlyToMatchingEpoch() throws {
        let batch = tagBatch(start: 100, end: 103, hidden: true)
        let snapshot = HBNVRTagSnapshot(instanceID: instance, revision: 4, cameraID: camera, spans: [
            .init(cameraID: camera, epochID: "epoch", start: 100, end: 101,
                tags: .init(values: [:], knownAbsent: [CameraVideoTags.hiddenKey], complete: false)),
            .init(cameraID: camera, epochID: "different", start: 101, end: 102,
                tags: .init(values: [:], knownAbsent: [], complete: true)),
            .init(cameraID: camera, epochID: "epoch", start: 102, end: 103,
                tags: .init(values: [:], knownAbsent: [], complete: false))])
        let result = CameraFootageTags.applying(snapshot, to: batch)
        XCTAssertEqual(result.id, batch.id)
        XCTAssertEqual(result.pieces.map(\.id), batch.pieces.map(\.id))
        XCTAssertEqual(result.pieces[0].samples.map(\.data), batch.pieces[0].samples.map(\.data))
        XCTAssertEqual(result.pieces[0].samples.map(\.isHidden), [false, true, true])
        var buffer = CameraHistoryBuffer()
        buffer.insert(batch, at: 42, around: 101); buffer.replaceTags(in: result)
        XCTAssertEqual(buffer.batches.first?.received, 42)
        XCTAssertEqual(buffer.bytes, batch.bytes)
    }

    func testDisjointBufferedChangesCoalesceToResetInsteadOfDroppingRange() async {
        let pair = AsyncStream<HBNVRTagChange>.makeStream(bufferingPolicy: .bufferingNewest(1))
        CameraFootageTags.yield(change(1), to: pair.continuation)
        CameraFootageTags.yield(change(2), to: pair.continuation)
        var iterator = pair.stream.makeAsyncIterator()
        let item = await iterator.next()
        XCTAssertTrue(item?.reset == true)
        XCTAssertEqual(item?.revision, 2)
        pair.continuation.finish()
    }

    func testStaleCloudBatchAndThumbnailReceiveAuthorityAtActualTimestamps() async throws {
        let raw = TagMediaSource(hidden: false)
        let authority = TagAuthority(instance: instance, hidden: true)
        let updates = AsyncStream<HBNVRTagChange>.makeStream()
        let source = await source(raw, authority: authority, stream: updates.stream)
        let result = try await source.fetch(.init(requestID: "test", operation: "frames", cameraID: camera,
            range: .init(start: 100, end: 103)))
        XCTAssertTrue(result.pieces[0].samples.allSatisfy(\.isHidden))
        let image = try await source.thumbnail(.init(requestID: "thumb", cameraID: camera, timestamp: 120,
            size: .init(width: 1, height: 1)))
        XCTAssertTrue(image?.isHidden == true)
        let queries = await authority.queries
        XCTAssertEqual(queries.last?.ranges.first?.start, 119.5, "Use the actual keyframe timestamp")
        XCTAssertEqual(queries.last?.ranges.first?.epochID, "epoch")
        await authority.setHidden(false)
        let cleared = try await source.refreshTags(result)
        XCTAssertFalse(cleared.pieces[0].samples.contains(where: \.isHidden))
        await source.close()
    }

    func testEventDuringSnapshotDiscardsStaleCompletionAndReadsOnceMore() async throws {
        let raw = TagMediaSource(hidden: false)
        let authority = TagAuthority(instance: instance, hidden: true, blockFirst: true)
        let updates = AsyncStream<HBNVRTagChange>.makeStream()
        let source = await source(raw, authority: authority, stream: updates.stream)
        var changes = await source.tagChanges().makeAsyncIterator()
        let task = Task { try await source.fetch(.init(requestID: "test", operation: "frames", cameraID: camera,
            range: .init(start: 100, end: 103))) }
        try await eventually { await authority.queries.count == 1 }
        await authority.setHidden(false)
        updates.continuation.yield(change())
        _ = await changes.next()
        await authority.release()
        let batch = try await task.value
        XCTAssertFalse(batch.pieces[0].samples.contains(where: \.isHidden))
        let count = await authority.queries.count
        XCTAssertEqual(count, 2)
        await source.close()
    }

    func testLoadedPausedHistoryRefreshesWithoutFetchingOrReplacingMedia() async throws {
        let raw = TagMediaSource(hidden: false)
        let authority = TagAuthority(instance: instance, hidden: false)
        let updates = AsyncStream<HBNVRTagChange>.makeStream()
        let source = await source(raw, authority: authority, stream: updates.stream)
        let history = CameraHistoryPlayback(clock: { 1 })
        history.configure(cameraID: camera, transport: source)
        history.enter(canonicalTime: 940, localHead: 1000, paused: true)
        try await eventually { history.buffer.frameCount > 0 && !history.fetching }
        let ids = history.buffer.batches.map(\.batch.id), bytes = history.buffer.bytes
        let frameReads = await raw.frameReads
        var presentationResets = 0
        history.resetPresentation = { presentationResets += 1 }
        await authority.setHidden(true)
        updates.continuation.yield(change())
        try await eventually { history.location(preferredPiece: nil)?.piece.samples.allSatisfy(\.isHidden) == true }
        XCTAssertTrue(history.isPaused); XCTAssertEqual(history.position, 940)
        XCTAssertEqual(history.buffer.batches.map(\.batch.id), ids)
        XCTAssertEqual(history.buffer.bytes, bytes)
        let after = await raw.frameReads
        XCTAssertEqual(after, frameReads)
        await authority.setHidden(false)
        updates.continuation.yield(change(2))
        try await eventually { history.location(preferredPiece: nil)?.piece.samples.contains(where: \.isHidden) == false }
        XCTAssertEqual(presentationResets, 2, "Both hiding and clearing a paused frame must re-present the retained GOP")
        history.disconnect()
    }

    func testRefreshBurstKeepsOneReadAndOneDirtyFlagAndDoesNotRetryFailure() async throws {
        let worker = CameraFootageRefreshTask()
        let gate = TagRefreshGate()
        var accepted: [Int] = []
        for value in 0..<1 {
            worker.schedule { token in await gate.read(); if worker.isCurrent(token) { accepted.append(value) } }
        }
        try await eventually { await gate.count == 1 }
        for value in 1...100 {
            worker.schedule { token in await gate.read(); if worker.isCurrent(token) { accepted.append(value) } }
        }
        let during = await gate.count
        XCTAssertEqual(during, 1)
        await gate.release()
        try await eventually { accepted == [100] }
        let calls = await gate.count
        XCTAssertEqual(calls, 2)
        worker.cancel()
    }

    func testExplicitOfflinePreservesDirectS3AndLastKnownTagsThenReconnectClears() async throws {
        let updates = AsyncStream<HBNVRTagChange>.makeStream()
        let authority = TagAuthority(instance: instance, hidden: true)
        let raw = TagMediaSource(hidden: false)
        let source = await source(raw, authority: authority, stream: updates.stream)
        let request = HBNVRMediaRequest(requestID: "cloud", operation: "frames", cameraID: camera,
            range: .init(start: 100, end: 103))
        let online = try await source.fetch(request)
        XCTAssertTrue(online.pieces[0].samples.allSatisfy(\.isHidden))
        await authority.setOffline(true)
        let offline = try await source.fetch(request)
        XCTAssertTrue(offline.pieces[0].samples.allSatisfy(\.isHidden), "Delayed clear cloud tags cannot undo known hidden footage")
        let freshSource = await self.source(raw, authority: authority, stream: AsyncStream { _ in })
        let freshOffline = try await freshSource.fetch(request)
        XCTAssertFalse(freshOffline.pieces[0].samples.contains(where: \.isHidden), "Fresh offline S3 keeps its existing tag behavior")
        await authority.setOffline(false); await authority.setHidden(false)
        let reconnect = try await source.refreshTags(offline)
        XCTAssertFalse(reconnect.pieces[0].samples.contains(where: \.isHidden))
        await source.close(); await freshSource.close()
    }

    func testDelayedOlderSnapshotCannotOverwriteNewerAcceptedCache() async throws {
        let authority = ReorderedTagAuthority(instance: instance)
        let raw = TagMediaSource(hidden: false)
        let source = CameraTaggedHistorySource(source: raw, updates: AsyncStream { _ in }) { await authority.read($0) }
        let request = HBNVRMediaRequest(requestID: "cloud", operation: "frames", cameraID: camera,
            range: .init(start: 100, end: 103))
        let old = Task { try await source.fetch(request) }
        try await eventually { await authority.count == 1 }
        let newer = try await source.fetch(request)
        XCTAssertTrue(newer.pieces[0].samples.allSatisfy(\.isHidden))
        await authority.release()
        let late = try await old.value
        XCTAssertTrue(late.pieces[0].samples.allSatisfy(\.isHidden))
        await source.close()
    }

    func testNavigationFindsVisibleFootageWithinTheRecordingContainingCursor() async throws {
        let raw = TagMediaSource(hidden: true)
        let updates = AsyncStream<HBNVRTagChange>.makeStream()
        let camera = self.camera, instance = self.instance
        let source = CameraTaggedHistorySource(source: raw, updates: updates.stream) { query in
            let spans: [HBNVRTagSpan] = query.ranges.flatMap { range in
                [(90.0, 100.0, false), (100.0, 200.0, true), (200.0, 210.0, false)].compactMap { start, end, hidden in
                    let low = max(start, range.start), high = min(end, range.end)
                    guard low < high else { return nil }
                    return HBNVRTagSpan(cameraID: camera, epochID: "epoch", start: low, end: high,
                        tags: .init(values: hidden ? [CameraVideoTags.hiddenKey: "1"] : [:], knownAbsent: [], complete: true))
                }
            }
            return HBNVRTagSnapshot(instanceID: instance, revision: 1, cameraID: camera, spans: spans)
        }
        let result = try await source.neighbors(.init(requestID: "navigation", operation: "neighbors", cameraID: camera,
            range: .init(start: 150, end: 151)), excludingHidden: true)
        XCTAssertEqual(result.neighbors?.previous, .init(start: 90, end: 100))
        XCTAssertEqual(result.neighbors?.next, .init(start: 200, end: 210))
        let mediaReads = await raw.frameReads
        XCTAssertEqual(mediaReads, 0)
        await source.close()
    }

    func testLegacyUnsupportedKeepsLegacyTagsButSnapshotFailuresPropagate() async throws {
        let updates = AsyncStream<HBNVRTagChange>.makeStream()
        let raw = TagMediaSource(hidden: true)
        let source = CameraTaggedHistorySource(source: raw, updates: updates.stream) { _ in nil }
        let request = HBNVRMediaRequest(requestID: "legacy", operation: "frames", cameraID: camera,
            range: .init(start: 100, end: 103))
        let batch = try await source.fetch(request)
        XCTAssertTrue(batch.pieces[0].samples.allSatisfy(\.isHidden))
        await source.close()
        let failed = CameraTaggedHistorySource(source: raw, updates: updates.stream) { _ in throw URLError(.timedOut) }
        do { _ = try await failed.fetch(request); XCTFail("Do not publish stale metadata after a timeout") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        await failed.close()
    }
}

private actor TagRefreshGate {
    var count = 0
    private var waiter: CheckedContinuation<Void, Never>?
    func read() async { count += 1; if count == 1 { await withCheckedContinuation { waiter = $0 } } }
    func release() { waiter?.resume(); waiter = nil }
}

actor TagAuthority {
    let instance: String
    var hidden: Bool
    private var offline = false
    let blockFirst: Bool
    var queries: [HBNVRTagQuery] = []
    private var waiter: CheckedContinuation<Void, Never>?
    init(instance: String, hidden: Bool, blockFirst: Bool = false) {
        self.instance = instance; self.hidden = hidden; self.blockFirst = blockFirst
    }
    func setHidden(_ value: Bool) { hidden = value }
    func setOffline(_ value: Bool) { offline = value }
    func release() { waiter?.resume(); waiter = nil }
    func read(_ query: HBNVRTagQuery) async throws -> HBNVRTagSnapshot {
        queries.append(query)
        if offline { throw HBProtocolError(code: "nvr_offline", message: "Fixture offline recorder") }
        let hidden = self.hidden
        if blockFirst && queries.count == 1 { await withCheckedContinuation { waiter = $0 } }
        return .init(instanceID: instance, revision: UInt64(queries.count), cameraID: query.cameraID,
            spans: query.ranges.map { range in
                .init(cameraID: query.cameraID, epochID: range.epochID ?? "epoch", start: range.start, end: range.end,
                    tags: .init(values: hidden ? [CameraVideoTags.hiddenKey: "1"] : [:],
                        knownAbsent: hidden ? [] : [CameraVideoTags.hiddenKey], complete: true))
            })
    }
}

private actor TagMediaSource: CameraThumbnailFetching {
    let hidden: Bool
    var frameReads = 0
    init(hidden: Bool) { self.hidden = hidden }
    func start() {}
    func close() {}
    func fetch(_ request: HBNVRMediaRequest, onBegin: CameraHistoryBeginHandler?) async throws -> CameraHistoryBatch {
        let anchor: Double? = request.relativeTo == nil ? nil : 1000
        let range = CameraHistoryRange(start: request.range.start + (anchor ?? 0), end: request.range.end + (anchor ?? 0))
        if request.operation == "availability" { return .init(id: UUID(), range: range, anchor: anchor, pieces: [], gaps: []) }
        frameReads += 1
        return tagBatch(start: range.start, end: range.end, hidden: hidden, anchor: anchor)
    }
    func neighbors(_ request: HBNVRMediaRequest, excludingHidden: Bool) async throws -> CameraHistoryBatch {
        .init(id: UUID(), range: .init(start: request.range.start, end: request.range.end), anchor: nil,
              pieces: [], gaps: [], neighbors: .init(previous: nil, next: nil))
    }
    func thumbnail(_ request: HBNVRThumbnailRequest) async throws -> CameraThumbnail? {
        .init(data: Data([1]), width: 1, height: 1, timestamp: request.timestamp - 0.5, isHidden: hidden, epochID: "epoch")
    }
}

private nonisolated func tagBatch(start: Double, end: Double, hidden: Bool, anchor: Double? = nil) -> CameraHistoryBatch {
    let zero = floor(start)
    let range = CameraHistoryRange(start: zero, end: end)
    let time = CameraHistorySegment.Time(canonicalUTC: zero, receivedUTC: zero, cameraUTC: nil,
        canonicalSource: "received", epochID: "epoch")
    let parameters: [Data] = [Data([UInt8(1)]), Data([UInt8(2)])]
    let segment = CameraHistorySegment(number: 0, range: range, time: time, timescale: 1,
        codec: "H264", parameterSets: parameters, nalUnitLengthBytes: 4)
    var samples: [CameraHistorySample] = []
    let count = Int(ceil(end - zero))
    for index in 0..<count {
        let frame = CameraHistoryFrame(segment: 0, presentationTicks: Int64(index), decodeTicks: nil,
            durationTicks: 1, keyFrame: index % 10 == 0, preroll: zero + Double(index) < start, byteCount: 5)
        samples.append(CameraHistorySample(frame: frame, data: Data([0, 0, 0, 1, 0x65]), isHidden: hidden))
    }
    let piece = CameraHistoryPiece(id: UUID(), segment: segment, samples: samples)
    return CameraHistoryBatch(id: UUID(), range: .init(start: start, end: end), anchor: anchor,
        pieces: [piece], gaps: [])
}

private actor ReorderedTagAuthority {
    let instance: String
    var count = 0
    private var waiter: CheckedContinuation<Void, Never>?
    init(instance: String) { self.instance = instance }
    func release() { waiter?.resume(); waiter = nil }
    func read(_ query: HBNVRTagQuery) async -> HBNVRTagSnapshot {
        count += 1
        let revision = UInt64(count)
        if revision == 1 { await withCheckedContinuation { waiter = $0 } }
        let spans = query.ranges.map { range in
            HBNVRTagSpan(cameraID: query.cameraID, epochID: range.epochID ?? "epoch", start: range.start, end: range.end,
                tags: .init(values: revision == 1 ? [:] : [CameraVideoTags.hiddenKey: "1"], knownAbsent: [], complete: true))
        }
        return .init(instanceID: instance, revision: revision, cameraID: query.cameraID, spans: spans)
    }
}
