import CryptoKit
import Foundation
import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraS3HistoryTests: XCTestCase {
    let camera = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    let store = HBCameraPlaybackMetadata.S3Store(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", name: "Archive",
        bucket: "example-recordings", region: "us-west-2", prefix: "test/", playbackManifestVersion: 1)
    let now = 1_790_000_000.0

    func request(_ range: CameraHistoryRange, operation: String = "frames", relative: String? = nil) -> HBNVRMediaRequest {
        .init(requestID: UUID().uuidString, operation: operation, cameraID: camera,
              timeline: "canonical", range: .init(start: range.start, end: range.end), relativeTo: relative)
    }
    func piece(_ range: CameraHistoryRange) -> CameraHistoryPiece {
        let segment = CameraHistorySegment(number: 0, range: range,
            time: .init(canonicalUTC: range.start, receivedUTC: range.start, cameraUTC: nil,
                        canonicalSource: "received", epochID: UUID().uuidString),
            timescale: 1000, codec: "H264", parameterSets: [Data([7]), Data([8])], nalUnitLengthBytes: 4)
        return .init(id: UUID(), segment: segment, samples: [.init(frame: .init(segment: 0,
            presentationTicks: 0, decodeTicks: nil, durationTicks: Int64(range.duration * 1000),
            keyFrame: true, preroll: false, byteCount: 5), data: Data([0, 0, 0, 1, 5]))])
    }
    func testNoCredentialsAndCompleteLocalResponseNeverContactCloud() async throws {
        let range = CameraHistoryRange(start: 100, end: 130), p = piece(.init(start: 100, end: 130))
        let local = S3HistoryStub(batch: .init(id: UUID(), range: range, anchor: nil, pieces: [p], gaps: []))
        let remote = S3HistoryStub(error: .unavailable)
        let all = CameraHistoryFallback(local: local, remote: remote)
        let result = try await all.fetch(request(range))
        XCTAssertEqual(result.frameCount, 1)
        let calls = await remote.requests
        XCTAssertTrue(calls.isEmpty)
        let noKeys = CameraHistoryFallback(local: local, remote: nil)
        let noKeysResult = try await noKeys.fetch(request(range))
        XCTAssertEqual(noKeysResult.frameCount, 1)
    }
    func testCloudFillsOnlyLocalGapsAndPreservesRelativeAnchor() async throws {
        let full = CameraHistoryRange(start: 100, end: 160), gap = CameraHistoryRange(start: 130, end: 160)
        let local = S3HistoryStub(batch: .init(id: UUID(), range: full, anchor: 160,
            pieces: [piece(.init(start: 100, end: 130))], gaps: [gap]))
        let remote = S3HistoryStub(batch: .init(id: UUID(), range: gap, anchor: nil, pieces: [piece(gap)], gaps: []))
        let fallback = CameraHistoryFallback(local: local, remote: remote)
        let result = try await fallback.fetch(request(.init(start: -60, end: 0), relative: "live"))
        XCTAssertEqual(result.anchor, 160); XCTAssertEqual(result.pieces.count, 2); XCTAssertTrue(result.gaps.isEmpty)
        let calls = await remote.requests
        XCTAssertEqual(calls.count, 1); XCTAssertNil(calls.first?.relativeTo)
        XCTAssertEqual(calls.first?.range.start, 130); XCTAssertEqual(calls.first?.range.end, 160)
    }
    func testReadErrorFallsBackButUnresolvedRelativeClockDoesNot() async throws {
        let range = CameraHistoryRange(start: 100, end: 130)
        let local = S3HistoryStub(error: .unavailable)
        let remote = S3HistoryStub(batch: .init(id: UUID(), range: range, anchor: nil, pieces: [piece(range)], gaps: []))
        let fallback = CameraHistoryFallback(local: local, remote: remote)
        let result = try await fallback.fetch(request(range))
        XCTAssertEqual(result.frameCount, 1)
        do { _ = try await fallback.fetch(request(.init(start: -30, end: 0), relative: "live")); XCTFail() }
        catch { XCTAssertEqual(error as? CameraHistoryError, .unavailable) }
        let calls = await remote.requests; XCTAssertEqual(calls.count, 1)
    }
    func testPartialLocalVideoSurvivesCloudFailureWithoutInventingGap() async throws {
        let range = CameraHistoryRange(start: 100, end: 160), gap = CameraHistoryRange(start: 130, end: 160)
        let local = S3HistoryStub(batch: .init(id: UUID(), range: range, anchor: nil,
            pieces: [piece(.init(start: 100, end: 130))], gaps: [gap]))
        let fallback = CameraHistoryFallback(local: local, remote: S3HistoryStub(error: .unavailable))
        let result = try await fallback.fetch(request(range))
        XCTAssertEqual(result.frameCount, 1); XCTAssertTrue(result.gaps.isEmpty)
        XCTAssertEqual(result.unresolved, [gap]); XCTAssertNotNil(result.sourceWarning)
        var buffer = CameraHistoryBuffer(); buffer.insert(result, at: 0, around: 120)
        XCTAssertNotNil(buffer.location(at: 120)); XCTAssertFalse(buffer.isKnown(140, now: 0, liveEdge: 200))
    }
    func testClosedFallbackDoesNotReadEitherSource() async throws {
        let local = S3HistoryStub(error: .unavailable), remote = S3HistoryStub(error: .unavailable)
        let fallback = CameraHistoryFallback(local: local, remote: remote)
        await fallback.close()
        do { _ = try await fallback.fetch(request(.init(start: 100, end: 110))); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        let localCalls = await local.requests, cloudCalls = await remote.requests
        XCTAssertTrue(localCalls.isEmpty); XCTAssertTrue(cloudCalls.isEmpty)
    }

    func fixture(start: Double) throws -> (CameraS3ManifestShard, [String: Data]) {
        let bytes = Data("test MP4 substitute".utf8), id = UUID().uuidString
        let entry = CameraS3ManifestShard(id: id, key: store.prefix + "camera/" + id + ".mp4", size: Int64(bytes.count),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), encryption: nil,
            timing: .init(format: "com.graygoolabs.hbnvr.timing", schemaVersion: 1, storeID: store.id,
                cameraID: camera, shardID: id, time: .init(canonicalUTC: start, receivedUTC: start, cameraUTC: nil,
                    canonicalSource: "received", epochID: UUID().uuidString), firstFrameReceivedUTC: start,
                timescale: 1000, rtpTimestamp: 0, ssrc: nil), endTicks: 60_000)
        let day = CameraS3ManifestLayout.day(start), month = String(day.prefix(7))
        let encoder = JSONEncoder(), root = CameraS3ManifestLayout.root(prefix: store.prefix, cameraID: camera)
        let catalog = CameraS3Catalog(format: "hbnvr-s3-playback", schemaVersion: 1, storeID: store.id,
            cameraID: camera, generatedAt: now, days: [.init(day: day, start: start, end: start + 60)])
        func manifest(_ period: String) -> CameraS3Manifest {
            .init(format: "hbnvr-s3-playback", schemaVersion: 1, storeID: store.id,
                cameraID: camera, generatedAt: now, period: period, shards: [entry])
        }
        return (entry, [root + "catalog.json": try encoder.encode(catalog), root + "days/" + day + ".json": try encoder.encode(manifest(day)),
                       root + "months/" + month + ".json": try encoder.encode(manifest(month)), entry.key: bytes])
    }
    func testTodayUsesDailyOlderFootageUsesMonthlyAndSameBufferSamples() async throws {
        for start in [now - 60, now - 3 * 86_400] {
            let (entry, files) = try fixture(start: start)
            let objects = S3ObjectStub(files: files), p = piece(entry.range), frozenNow = now
            let reader = CameraS3HistoryReader(store: store, cameraID: camera, password: nil, objects: objects,
                now: { frozenNow }, decode: { data, expected, range in
                    XCTAssertEqual(expected.id, entry.id); XCTAssertEqual(data, files[entry.key]); return [p]
                })
            let result = try await reader.fetch(request(entry.range))
            XCTAssertEqual(result.frameCount, 1); XCTAssertTrue(result.gaps.isEmpty)
            let paths = await objects.requests
            XCTAssertEqual(paths.count, 3)
            XCTAssertTrue(paths[1].contains(start == now - 60 ? "/days/" : "/months/"))
            XCTAssertFalse(paths.contains { $0.contains("list") })
            await reader.close()
        }
    }
    func testIndexAbsentOrAccessDeniedIsErrorNotKnownEmptyFootage() async throws {
        let objects = S3ObjectStub(files: [:]), frozenNow = now
        let reader = CameraS3HistoryReader(store: store, cameraID: camera, password: nil, objects: objects, now: { frozenNow })
        do { _ = try await reader.fetch(request(.init(start: now - 60, end: now))); XCTFail() }
        catch { XCTAssertEqual(error as? CameraHistoryError, .unavailable) }
    }
    func testCorruptObjectNeverReachesDecoder() async throws {
        let (entry, original) = try fixture(start: now - 60)
        var files = original; files[entry.key] = Data(repeating: 0, count: Int(entry.size))
        let objects = S3ObjectStub(files: files), frozenNow = now
        let reader = CameraS3HistoryReader(store: store, cameraID: camera, password: nil, objects: objects,
            now: { frozenNow }, decode: { _, _, _ in XCTFail("Hash must be checked first"); return [] })
        do { _ = try await reader.fetch(request(entry.range)); XCTFail() }
        catch { XCTAssertEqual(error as? CameraS3HistoryError, .hashMismatch) }
    }
    func testKnownCatalogGapDoesNotFetchNonexistentObject() async throws {
        let (_, files) = try fixture(start: now - 60), frozenNow = now
        let objects = S3ObjectStub(files: files)
        let reader = CameraS3HistoryReader(store: store, cameraID: camera, password: nil, objects: objects, now: { frozenNow })
        let range = CameraHistoryRange(start: now - 3600, end: now - 3540)
        let batch = try await reader.fetch(request(range))
        XCTAssertEqual(batch.gaps, [range]); XCTAssertEqual(batch.frameCount, 0)
        let calls = await objects.requests; XCTAssertEqual(calls.count, 1)
    }
}

private actor S3ObjectStub: CameraS3ObjectReading {
    let files: [String: Data]
    private(set) var requests: [String] = []
    init(files: [String: Data]) { self.files = files }
    func read(key: String, maximumBytes: Int) throws -> Data {
        requests.append(key)
        guard let data = files[key] else { throw CameraHistoryError.unavailable }
        guard data.count <= maximumBytes else { throw CameraHistoryError.tooLarge }
        return data
    }
    func close() {}
}
private actor S3HistoryStub: CameraHistoryFetching {
    let batch: CameraHistoryBatch?
    let error: CameraHistoryError?
    private(set) var requests: [HBNVRMediaRequest] = []
    init(batch: CameraHistoryBatch? = nil, error: CameraHistoryError? = nil) { self.batch = batch; self.error = error }
    func start() {}
    func close() {}
    func fetch(_ request: HBNVRMediaRequest, onBegin: CameraHistoryBeginHandler?) throws -> CameraHistoryBatch {
        requests.append(request)
        if let error { throw error }; return batch!
    }
}
