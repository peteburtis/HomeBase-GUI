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

    func fixture(start: Double, tags: CameraStoredVideoTags? = nil) throws -> (CameraS3ManifestShard, [String: Data]) {
        let bytes = Data("test MP4 substitute".utf8), id = UUID().uuidString
        let entry = CameraS3ManifestShard(id: id, key: store.prefix + "camera/" + id + ".mp4", size: Int64(bytes.count),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), encryption: nil,
            timing: .init(format: "com.graygoolabs.hbnvr.timing", schemaVersion: 1, storeID: store.id,
                cameraID: camera, shardID: id, time: .init(canonicalUTC: start, receivedUTC: start, cameraUTC: nil,
                    canonicalSource: "received", epochID: UUID().uuidString), firstFrameReceivedUTC: start,
                timescale: 1000, rtpTimestamp: 0, ssrc: nil), endTicks: 60_000, tagMetadata: tags)
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
    func testPlainAndEncryptedManifestTagsOverrideDecodedOriginalMetadata() async throws {
        for encrypted in [false, true] {
            let timeline = CameraVideoTagTimeline(version: 2, changes: [.init(ticks: 0, frame: 0, tags: ["homebase.hidden": "true"])],
                overrides: [.init(start: 0, end: 1000, key: "homebase.hidden", value: nil)])
            let tags = try encrypted
                ? CameraStoredVideoTags(timeline: nil, encrypted: CameraS3ThumbnailTests().encrypted(JSONEncoder().encode(timeline)))
                : CameraStoredVideoTags(timeline: timeline, encrypted: nil)
            let (entry, files) = try fixture(start: now - 60, tags: tags), frozenNow = now
            var original = piece(entry.range)
            original.samples[0].isHidden = true
            let decoded = original
            let objects = S3ObjectStub(files: files)
            let reader = CameraS3HistoryReader(store: store, cameraID: camera, password: "test password", objects: objects,
                now: { frozenNow }, decode: { _, _, _ in [decoded] })
            let result = try await reader.fetch(request(entry.range))
            XCTAssertFalse(try XCTUnwrap(result.pieces.first?.samples.first).isHidden)
            let removed = try await reader.hidden(at: entry.range.start)
            let retained = try await reader.hidden(at: entry.range.start + 2)
            XCTAssertEqual(removed, false); XCTAssertEqual(retained, true)
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

    func indexedFiles(_ entries: [CameraS3ManifestShard]) throws -> [String: Data] {
        let encoder = JSONEncoder(), root = CameraS3ManifestLayout.root(prefix: store.prefix, cameraID: camera)
        let groups = Dictionary(grouping: entries, by: { CameraS3ManifestLayout.day($0.range.start) })
        let days = groups.keys.sorted().map { day in
            CameraS3Catalog.Day(day: day, start: groups[day]!.map(\.range.start).min()!, end: groups[day]!.map(\.range.end).max()!)
        }
        var files = [root + "catalog.json": try encoder.encode(CameraS3Catalog(format: "hbnvr-s3-playback",
            schemaVersion: 1, storeID: store.id, cameraID: camera, generatedAt: now, days: days))]
        for day in groups.keys {
            files[root + "days/" + day + ".json"] = try encoder.encode(CameraS3Manifest(format: "hbnvr-s3-playback",
                schemaVersion: 1, storeID: store.id, cameraID: camera, generatedAt: now, period: day, shards: groups[day]!))
        }
        for (month, shards) in Dictionary(grouping: entries, by: { CameraS3ManifestLayout.month($0.range.start) }) {
            files[root + "months/" + month + ".json"] = try encoder.encode(CameraS3Manifest(format: "hbnvr-s3-playback",
                schemaVersion: 1, storeID: store.id, cameraID: camera, generatedAt: now, period: month, shards: shards))
        }
        return files
    }

    private func reader(_ objects: ListingS3ObjectStub) -> CameraS3HistoryReader {
        let frozenNow = now
        return CameraS3HistoryReader(store: store, cameraID: camera, password: nil, objects: objects,
            now: { frozenNow }, decode: { _, shard, requested in
                guard let range = shard.range.intersection(requested) else { return [] }
                return [await self.piece(range)]
            })
    }

    func testDeletedVideoBecomesGapAndAvailabilityUsesSameInventory() async throws {
        let (entry, original) = try fixture(start: now - 60)
        var files = original; files[entry.key] = nil
        let objects = ListingS3ObjectStub(files: files), reader = reader(objects)
        for operation in ["frames", "availability"] {
            let result = try await reader.fetch(request(entry.range, operation: operation))
            XCTAssertEqual(result.gaps, [entry.range]); XCTAssertTrue(result.pieces.isEmpty)
        }
        let calls = await objects.requests, listings = await objects.listings
        XCTAssertFalse(calls.contains(entry.key), "Do not try downloading known deleted footage")
        XCTAssertEqual(listings.filter { $0.0 == "test/camera/" }.count, 1, "Cache successful inventory")
        await reader.close()
    }

    func testNeighborsSkipManyExpiredEntriesWithoutMediaReads() async throws {
        let old = try (1...120).map { try fixture(start: now - Double($0) * 86400).0 }
        let (retained, media) = try fixture(start: now - 60)
        var files = try indexedFiles(old + [retained]); files[retained.key] = media[retained.key]
        let objects = ListingS3ObjectStub(files: files), reader = reader(objects)
        let cursor = now - 121 * 86400
        let result = try await reader.fetch(request(.init(start: cursor, end: cursor + 0.00001), operation: "neighbors"))
        XCTAssertNil(result.neighbors?.previous); XCTAssertEqual(result.neighbors?.next, retained.range)
        let calls = await objects.requests, listings = await objects.listings
        XCTAssertFalse(calls.contains { $0.hasSuffix(".mp4") })
        XCTAssertEqual(listings.filter { $0.0 == "test/camera/" }.count, 1)
        await reader.close()
    }

    func testDeletedPeriodManifestIsSkippedWithListingButStillErrorsWithoutIt() async throws {
        let (old, _) = try fixture(start: now - 90 * 86400)
        let (retained, media) = try fixture(start: now - 60)
        var files = try indexedFiles([old, retained]); files[retained.key] = media[retained.key]
        let oldKey = CameraS3ManifestLayout.root(prefix: store.prefix, cameraID: camera)
            + "months/" + CameraS3ManifestLayout.month(old.range.start) + ".json"
        files[oldKey] = nil
        let objects = ListingS3ObjectStub(files: files), reader = reader(objects)
        let result = try await reader.fetch(request(old.range))
        XCTAssertEqual(result.gaps, [old.range])
        let nearby = try await reader.fetch(request(old.range, operation: "neighbors"))
        XCTAssertNil(nearby.neighbors?.previous); XCTAssertEqual(nearby.neighbors?.next, retained.range)
        let calls = await objects.requests; XCTAssertFalse(calls.contains(oldKey))
        let legacy = self.reader(ListingS3ObjectStub(files: files, listError: .accessDenied))
        do { _ = try await legacy.fetch(request(old.range)); XCTFail("GET-only manifest error must remain") }
        catch { XCTAssertEqual(error as? CameraS3ReadError, .accessDenied) }
        await reader.close(); await legacy.close()
    }

    func testDeniedListingPreservesPlaybackAndMissingObjectErrorsForWholeSession() async throws {
        for failure in [CameraS3ReadError.missing, .accessDenied] {
            let (entry, files) = try fixture(start: now - 60)
            let objects = ListingS3ObjectStub(files: files, listError: .accessDenied)
            let reader = reader(objects)
            let available = try await reader.fetch(request(entry.range, operation: "availability"))
            XCTAssertTrue(available.gaps.isEmpty)
            let result = try await reader.fetch(request(entry.range))
            XCTAssertEqual(result.frameCount, 1)
            await objects.remove(entry.key, error: failure)
            // A fresh reader has no decoded media cache, as when reopening History.
            let reopened = self.reader(objects)
            do { _ = try await reopened.fetch(request(entry.range)); XCTFail("Legacy read failure must remain") }
            catch { XCTAssertEqual(error as? CameraS3ReadError, failure) }
            let listings = await objects.listings
            XCTAssertEqual(listings.count, 2, "One denied attempt per reader/session")
            await reader.close(); await reopened.close()
        }
    }

    func testTransientOrIncompleteListingDoesNotInventAbsenceOrBlockGet() async throws {
        for mode in [ListingS3ObjectStub.Mode.transient, .partialFailure, .repeatedToken, .pageLimit] {
            let (entry, files) = try fixture(start: now - 60)
            let objects = ListingS3ObjectStub(files: files, mode: mode), reader = reader(objects)
            let result = try await reader.fetch(request(entry.range))
            XCTAssertEqual(result.frameCount, 1); XCTAssertTrue(result.gaps.isEmpty)
            await objects.remove(entry.key, error: .accessDenied)
            let missing = self.reader(objects)
            do { _ = try await missing.fetch(request(entry.range)); XCTFail("Incomplete listing must preserve GET error") }
            catch { XCTAssertEqual(error as? CameraS3ReadError, .accessDenied) }
            await reader.close()
            await missing.close()
        }
    }

    func testPaginationFindsVideoOnLaterPageBeforeDeclaringGap() async throws {
        let (entry, files) = try fixture(start: now - 60)
        let objects = ListingS3ObjectStub(files: files, mode: .paginate), reader = reader(objects)
        let result = try await reader.fetch(request(entry.range))
        XCTAssertEqual(result.frameCount, 1); XCTAssertTrue(result.gaps.isEmpty)
        let listings = await objects.listings
        XCTAssertTrue(listings.contains { $0.1 == "second" })
        await reader.close()
    }

    func testDeletionAfterListingRefreshesOnceAndRemovesStaleNeighbor() async throws {
        let (entry, files) = try fixture(start: now - 60)
        let objects = ListingS3ObjectStub(files: files, mode: .deleteDuringRead), reader = reader(objects)
        let before = try await reader.fetch(request(.init(start: now - 120, end: now - 119), operation: "neighbors"))
        XCTAssertEqual(before.neighbors?.next, entry.range)
        let result = try await reader.fetch(request(entry.range))
        XCTAssertEqual(result.gaps, [entry.range])
        let after = try await reader.fetch(request(.init(start: now - 120, end: now - 119), operation: "neighbors"))
        XCTAssertNil(after.neighbors?.next)
        let calls = await objects.requests
        XCTAssertEqual(calls.filter { $0 == entry.key }.count, 1)
        await reader.close()
    }

    func testListedObjectWithReadAccessDeniedStaysAnError() async throws {
        let (entry, files) = try fixture(start: now - 60)
        let objects = ListingS3ObjectStub(files: files, mode: .readDenied), reader = reader(objects)
        do { _ = try await reader.fetch(request(entry.range)); XCTFail("Existing inaccessible object is not a gap") }
        catch { XCTAssertEqual(error as? CameraS3ReadError, .accessDenied) }
        await reader.close()
    }

    func testStandardMediaPrefixesUseObjectDateWhilePlaybackUsesCanonicalTiming() async throws {
        let (entry, media) = try fixture(start: now - 180)
        let captureDay = CameraS3ManifestLayout.day(now - 10 * 86400)
        let directory = "test/Renamed camera--" + camera.lowercased() + "/"
        let key = directory + captureDay + "T10-00-00.000Z_" + entry.id.lowercased() + ".mp4"
        let renamed = CameraS3ManifestShard(id: entry.id, key: key, size: entry.size, sha256: entry.sha256,
            encryption: entry.encryption, timing: entry.timing, endTicks: entry.endTicks)
        var files = try indexedFiles([renamed]); files[key] = media[entry.key]
        let objects = ListingS3ObjectStub(files: files), reader = reader(objects)
        let frames = try await reader.fetch(request(renamed.range))
        XCTAssertEqual(frames.pieces.first?.segment.range, renamed.range)
        let neighbors = try await reader.fetch(request(.init(start: now - 300, end: now - 299), operation: "neighbors"))
        XCTAssertEqual(neighbors.neighbors?.next, renamed.range)
        let listings = await objects.listings
        XCTAssertTrue(listings.contains { $0.0 == directory + captureDay })
        XCTAssertTrue(listings.contains { $0.0 == directory + captureDay.prefix(7) })
        XCTAssertFalse(listings.contains { $0.0 == store.prefix }, "Do not enumerate the whole store")
        await reader.close()
    }

    func testRecentEmptyInventoryExpiresAndDiscoversLateUpload() async throws {
        let (entry, original) = try fixture(start: now - 60)
        let day = CameraS3ManifestLayout.day(now)
        let key = "test/camera/" + day + "T10-00-00.000Z_" + entry.id.lowercased() + ".mp4"
        let renamed = CameraS3ManifestShard(id: entry.id, key: key, size: entry.size, sha256: entry.sha256,
            encryption: entry.encryption, timing: entry.timing, endTicks: entry.endTicks)
        let objects = ListingS3ObjectStub(files: try indexedFiles([renamed]))
        let clock = S3InventoryTestClock(now)
        let picture = piece(renamed.range)
        let reader = CameraS3HistoryReader(store: store, cameraID: camera, password: nil, objects: objects,
            now: { clock.read() }, decode: { _, _, _ in [picture] })
        let first = try await reader.fetch(request(renamed.range))
        XCTAssertEqual(first.gaps, [renamed.range])
        await objects.add(key, data: original[entry.key]!)
        let cached = try await reader.fetch(request(renamed.range))
        XCTAssertEqual(cached.gaps, [renamed.range])
        clock.advance(6)
        let refreshed = try await reader.fetch(request(renamed.range))
        XCTAssertEqual(refreshed.frameCount, 1); XCTAssertTrue(refreshed.gaps.isEmpty)
        await reader.close()
    }

    func testExpiredFootageEntersExistingGapNavigationAndPausedForwardJump() async throws {
        let (old, _) = try fixture(start: now - 3600)
        let (retained, media) = try fixture(start: now - 60)
        var files = try indexedFiles([old, retained]); files[retained.key] = media[retained.key]
        let objects = ListingS3ObjectStub(files: files)
        let history = CameraHistoryPlayback(clock: { 0 })
        defer { history.close() }
        history.configure(cameraID: camera, transport: CameraHistoryFallback(local: S3HistoryStub(error: .unavailable), remote: reader(objects)))
        history.enter(canonicalTime: old.range.start + 1, localHead: 0, paused: true)
        for _ in 0..<200 {
            if !history.fetching, case .ready = history.navigation { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(history.state, .gap)
        XCTAssertNil(history.adjacentRecording(previous: true))
        let next = try XCTUnwrap(history.adjacentRecording(previous: false))
        XCTAssertEqual(next.timeIntervalSince1970, retained.range.start)
        history.enter(canonicalTime: next.timeIntervalSince1970, localHead: 0, paused: true)
        for _ in 0..<200 {
            if !history.fetching, history.state == .ready { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(history.state, .ready); XCTAssertTrue(history.isPaused)
        XCTAssertEqual(history.position, retained.range.start)
    }
}

private actor ListingS3ObjectStub: CameraS3ObjectReading {
    enum Mode: Sendable { case normal, transient, partialFailure, repeatedToken, pageLimit, paginate, deleteDuringRead, readDenied }
    private var files: [String: Data]
    private let listError: CameraS3ReadError?
    private let mode: Mode
    private var missingError = CameraS3ReadError.accessDenied
    private(set) var requests: [String] = []
    private(set) var listings: [(String, String?)] = []
    init(files: [String: Data], listError: CameraS3ReadError? = nil, mode: Mode = .normal) {
        self.files = files; self.listError = listError; self.mode = mode
    }
    func read(key: String, maximumBytes: Int) throws -> Data {
        requests.append(key)
        if key.hasSuffix(".mp4") {
            if mode == .readDenied { throw CameraS3ReadError.accessDenied }
            if mode == .deleteDuringRead { files[key] = nil }
        }
        guard let data = files[key] else { throw missingError }
        return data
    }
    func list(prefix: String, continuationToken: String?) throws -> CameraS3ObjectPage? {
        listings.append((prefix, continuationToken))
        if let listError { throw listError }
        if mode == .transient { throw CameraS3ReadError.timeout }
        if mode == .partialFailure {
            if continuationToken == nil { return .init(keys: [], next: "second") }
            throw CameraS3ReadError.network
        }
        if mode == .repeatedToken { return .init(keys: [], next: "repeated") }
        if mode == .pageLimit { return .init(keys: [], next: String(listings.count)) }
        if mode == .paginate, continuationToken == nil { return .init(keys: [], next: "second") }
        return .init(keys: files.keys.filter { $0.hasPrefix(prefix) }.sorted(), next: nil)
    }
    func remove(_ key: String, error: CameraS3ReadError) { files[key] = nil; missingError = error }
    func add(_ key: String, data: Data) { files[key] = data }
    func close() {}
}

private nonisolated final class S3InventoryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double
    init(_ seconds: Double) { self.seconds = seconds }
    func read() -> Double { lock.lock(); defer { lock.unlock() }; return seconds }
    func advance(_ delta: Double) { lock.lock(); defer { lock.unlock() }; seconds += delta }
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
