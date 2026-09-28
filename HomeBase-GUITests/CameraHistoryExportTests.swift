import AVFoundation
import HomeBaseProtocol
import SwiftUI
import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraHistoryExportTests: XCTestCase {
    func testDraftPreservesExactPlayheadAndValidatesBothEndModes() {
        let date = Date(timeIntervalSince1970: 1000.375)
        var draft = CameraHistoryExportDraft(start: date)
        XCTAssertEqual(draft.range, .init(start: 1000.375, end: 1060.375))
        draft.hours = 2; draft.minutes = 30
        XCTAssertEqual(draft.range.duration, 9000)
        draft.endSelection = .date
        draft.end = date.addingTimeInterval(30)
        XCTAssertEqual(draft.range.duration, 30)
        XCTAssertNil(draft.validationMessage)
        draft.end = date
        XCTAssertNotNil(draft.validationMessage)
        draft.end = date.addingTimeInterval(86401)
        XCTAssertNotNil(draft.validationMessage)
        draft.endSelection = .duration; draft.hours = 24; draft.minutes = 0
        XCTAssertNil(draft.validationMessage)
        draft.minutes = 1
        XCTAssertNotNil(draft.validationMessage)
    }

    func testPopoverUsesFrozenDepartureRatherThanMovingPlayhead() async {
        let controller = CameraHistoryExportController()
        var position = CameraSwitchPosition.canonical(1000.125, paused: false)
        controller.prepare(position: position, targets: []) { snapshot in
            await Task.yield()
            return snapshot
        }
        position = .canonical(1005, paused: false)
        await controller.waitForWork()
        XCTAssertEqual(controller.draft?.start.timeIntervalSince1970, 1000.125)
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(position, .canonical(1005, paused: false))
    }

    func testCancelledResolutionCannotReopenDraft() async {
        let controller = CameraHistoryExportController()
        controller.prepare(position: .canonical(1000, paused: true), targets: []) { position in
            await Task.yield()
            return position
        }
        controller.cancel()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(controller.draft)
        XCTAssertNil(controller.error)
        XCTAssertFalse(controller.isBusy)
    }

    func testH264ExportUsesPreviousKeyframeClipsEndAndDeduplicatesBatchPreroll() async throws {
        try await proveExport(codec: kCMVideoCodecType_H264)
    }

    func testHEVCExportUsesPreviousKeyframeClipsEndAndDeduplicatesBatchPreroll() async throws {
        try await proveExport(codec: kCMVideoCodecType_HEVC)
    }

    private func proveExport(codec: CMVideoCodecType) async throws {
        let fixture = try await S3MediaFixture.make(codec: codec, count: 30)
        let pieces = [try historyPiece(fixture)]
        let source = ExportFixtureSource(pieces: pieces)
        let result = try await CameraHistoryExporter.export(cameraID: UUID().uuidString, name: "Front/door",
            range: .init(start: 1000.4, end: 1001.75), source: source, windowDuration: 0.3)
        defer { result.recordings.forEach { CameraLocalRecordingController.removeRecordingFile(at: $0.fileURL) } }
        XCTAssertEqual(result.recordings.count, 1)
        let movie = try XCTUnwrap(result.recordings.first)
        XCTAssertEqual(movie.creationDate.timeIntervalSince1970, 1000, accuracy: 0.00001)
        XCTAssertTrue(movie.filename.hasPrefix("Front-door"))
        let read = try await readMovie(movie.fileURL)
        XCTAssertEqual(read.duration, 1.75, accuracy: 0.002)
        XCTAssertEqual(read.samples.count, 27)
        XCTAssertEqual(read.samples.map(S3MediaFixture.payload), fixture.samples.prefix(27).map(S3MediaFixture.payload))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(read.samples[0]).seconds, 0, accuracy: 0.00001)
        let closed = await source.closed
        let requests = await source.requests
        XCTAssertTrue(closed)
        XCTAssertEqual(requests.count, 5)
        XCTAssertTrue(requests.allSatisfy { $0.relativeTo == nil && $0.operation == "frames" })
    }

    func testContiguousShardsRebaseTheirOwnTickOriginsIntoOneMovie() async throws {
        let fixture = try await S3MediaFixture.make(count: 15)
        let pieces = [try historyPiece(fixture)]
        let original = try XCTUnwrap(pieces.first)
        let second = shifted(original, by: 1)
        let source = ExportFixtureSource(pieces: [original, second])
        let result = try await CameraHistoryExporter.export(cameraID: "camera", name: "Camera",
            range: .init(start: 1000, end: 1002), source: source)
        defer { result.recordings.forEach { CameraLocalRecordingController.removeRecordingFile(at: $0.fileURL) } }
        XCTAssertEqual(result.recordings.count, 1)
        let movie = try await readMovie(try XCTUnwrap(result.recordings.first).fileURL)
        XCTAssertEqual(movie.samples.count, 30)
        XCTAssertEqual(movie.duration, 2, accuracy: 0.002)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(movie.samples[15]).seconds, 1, accuracy: 0.00001)
    }

    func testGapsAndChangedClockEpochsConcatenateIntoOneDecodableMovie() async throws {
        let fixture = try await S3MediaFixture.make(count: 15)
        let pieces = [try historyPiece(fixture)]
        let original = try XCTUnwrap(pieces.first)
        for second in [shifted(original, by: 2), shifted(original, by: 1, epoch: "new-epoch"),
                       shifted(original, by: 0.5, epoch: "overlapping-clock-epoch")] {
            let source = ExportFixtureSource(pieces: [original, second], gaps: [.init(start: 1001, end: 1002)])
            let result = try await CameraHistoryExporter.export(cameraID: "camera", name: "Camera",
                range: .init(start: 1000, end: 1003), source: source)
            defer { result.recordings.forEach { CameraLocalRecordingController.removeRecordingFile(at: $0.fileURL) } }
            XCTAssertEqual(result.recordings.count, 1)
            XCTAssertTrue(result.hasGaps)
            for recording in result.recordings {
                let movie = try await readMovie(recording.fileURL)
                XCTAssertEqual(movie.samples.count, 30)
                XCTAssertEqual(movie.duration, 2, accuracy: 0.002, "The recording gap is removed from the movie timeline")
                XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(movie.samples[15]).seconds, 1, accuracy: 0.00001)
            }
        }
    }

    func testOneFrameDiscontinuityAtRepeatedGOPBoundaryDoesNotSplitOrReplayPreroll() async throws {
        let fixture = try await S3MediaFixture.make(count: 30)
        var piece = try historyPiece(fixture)
        // The first 0.6s request ends on frame 8. Its reported duration is one
        // frame short of the next PTS; the next request repeats the entire GOP.
        piece.samples[8] = withDuration(piece.samples[8], ticks: 3000)
        let result = try await CameraHistoryExporter.export(cameraID: "camera", name: "Camera",
            range: .init(start: 1000, end: 1002), source: ExportFixtureSource(pieces: [piece]), windowDuration: 0.6)
        defer { result.recordings.forEach { CameraLocalRecordingController.removeRecordingFile(at: $0.fileURL) } }
        XCTAssertEqual(result.recordings.count, 1)
        let movie = try await readMovie(try XCTUnwrap(result.recordings.first).fileURL)
        XCTAssertEqual(movie.samples.map(S3MediaFixture.payload), fixture.samples.map(S3MediaFixture.payload))
        XCTAssertEqual(movie.duration, 2 - 1.0 / 30, accuracy: 0.002)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(movie.samples[9]).seconds, 0.6 - 1.0 / 30, accuracy: 0.00001)
    }

    func testOverlappingGOPWithNewEpochAndRoundedClockDoesNotReplay() async throws {
        let fixture = try await S3MediaFixture.make(count: 30)
        let piece = try historyPiece(fixture)
        let movies = CameraHistoryMovieWriter(name: "Camera", range: .init(start: 1000, end: 1002.01))
        defer { movies.discard() }
        let prefix = CameraHistoryPiece(id: UUID(), segment: piece.segment, samples: Array(piece.samples.prefix(9)))
        try await movies.append(prefix, window: .init(start: 1000, end: 1000.6))
        // One source tick of anchor rounding is still the same compressed GOP.
        let changed = shifted(piece, by: 1.0 / 90_000, epoch: "updated-clock-epoch")
        try await movies.append(changed, window: .init(start: 1000.6, end: 1002.01))
        try await movies.finish()
        XCTAssertEqual(movies.recordings.count, 1)
        let movie = try await readMovie(try XCTUnwrap(movies.recordings.first).fileURL)
        XCTAssertEqual(movie.samples.map(S3MediaFixture.payload), fixture.samples.map(S3MediaFixture.payload))
        XCTAssertEqual(movie.duration, 2, accuracy: 0.002)
    }

    func testThreeHourExportWith1080DiscontinuitiesStillProducesOneFile() async throws {
        let fixture = try await S3MediaFixture.make(count: 1)
        let original = try historyPiece(fixture)
        let sample = withDuration(try XCTUnwrap(original.samples.first), ticks: 899_100) // 9.99 seconds
        let pieces = (0..<1080).map { index in
            let shifted = shifted(original, by: Double(index) * 10, epoch: "epoch-\(index)")
            let old = shifted.segment
            let segment = CameraHistorySegment(number: index,
                range: .init(start: old.range.start, end: old.range.start + 9.99), time: old.time,
                timescale: old.timescale, codec: old.codec, parameterSets: old.parameterSets,
                nalUnitLengthBytes: old.nalUnitLengthBytes)
            return CameraHistoryPiece(id: UUID(), segment: segment, samples: [sample])
        }
        let source = ExportFixtureSource(pieces: pieces)
        let result = try await CameraHistoryExporter.export(cameraID: "camera", name: "Camera",
            range: .init(start: 1000, end: 1000 + 3 * 3600), source: source)
        defer { result.recordings.forEach { CameraLocalRecordingController.removeRecordingFile(at: $0.fileURL) } }
        XCTAssertEqual(result.recordings.count, 1)
        let movie = try await readMovie(try XCTUnwrap(result.recordings.first).fileURL)
        XCTAssertEqual(movie.samples.count, 1080)
        XCTAssertEqual(movie.duration, 1080 * 9.99, accuracy: 0.002, "Movie timing must not drift over an hours-long export")
        let requests = await source.requests
        XCTAssertEqual(requests.count, 1080)
    }

    func testGenuineCodecChangeStillCreatesSeparateDecodableMovies() async throws {
        let h264 = try historyPiece(try await S3MediaFixture.make(count: 15))
        let hevc = try historyPiece(try await S3MediaFixture.make(codec: kCMVideoCodecType_HEVC, count: 15))
        let result = try await CameraHistoryExporter.export(cameraID: "camera", name: "Camera",
            range: .init(start: 1000, end: 1002), source: ExportFixtureSource(pieces: [h264, shifted(hevc, by: 1)]))
        defer { result.recordings.forEach { CameraLocalRecordingController.removeRecordingFile(at: $0.fileURL) } }
        XCTAssertEqual(result.recordings.count, 2)
        for recording in result.recordings {
            let movie = try await readMovie(recording.fileURL)
            XCTAssertEqual(movie.samples.count, 15)
            XCTAssertEqual(movie.duration, 1, accuracy: 0.002)
        }
    }

    func testFailedOrUnresolvedReadRemovesAllTemporaryMoviesAndClosesSource() async throws {
        let fixture = try await S3MediaFixture.make(count: 30)
        let pieces = [try historyPiece(fixture)]
        for unresolved in [false, true] {
            let before = try temporaryMovies()
            let source = ExportFixtureSource(pieces: pieces, failAt: 2, unresolved: unresolved)
            do {
                _ = try await CameraHistoryExporter.export(cameraID: "camera", name: "Camera",
                    range: .init(start: 1000, end: 1002), source: source, windowDuration: 0.5)
                XCTFail("Incomplete retrieval must not return a successful truncated export")
            } catch {}
            let closed = await source.closed
            XCTAssertTrue(closed)
            XCTAssertEqual(try temporaryMovies(), before)
        }
    }

    func testCancellationClosesSourceAndRemovesTemporaryMovies() async throws {
        let fixture = try await S3MediaFixture.make(count: 30)
        let pieces = [try historyPiece(fixture)]
        let source = ExportFixtureSource(pieces: pieces, stallAt: 2)
        let before = try temporaryMovies()
        let task = Task {
            try await CameraHistoryExporter.export(cameraID: "camera", name: "Camera",
                range: .init(start: 1000, end: 1002), source: source, windowDuration: 0.5)
        }
        while await source.requests.count < 2 { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled export must not return movies") }
        catch { XCTAssertTrue(error is CancellationError) }
        let closed = await source.closed
        XCTAssertTrue(closed)
        XCTAssertEqual(try temporaryMovies(), before)
    }

    func testControllerUsesSameSaveFlowAndReportsMissingCamerasWithoutRequestingPhotos() async throws {
        let fixture = try await S3MediaFixture.make(count: 15)
        let piece = try historyPiece(fixture)
        let destination = ExportDestination()
        let controller = CameraHistoryExportController()
        let metadata = HBCameraPlaybackMetadata(nvrInstanceID: "nvr", cameraID: UUID().uuidString,
            stores: [.init(id: "local", name: "Local")])
        controller.prepare(position: .canonical(1000.3, paused: true), targets: [
            .init(name: "Front", metadata: metadata), .init(name: "Unavailable", metadata: nil)
        ]) { $0 }
        await controller.waitForWork()
        controller.draft?.endSelection = .date
        controller.draft?.end = Date(timeIntervalSince1970: 1001)
        controller.start(destination: destination) { _ in ExportFixtureSource(pieces: [piece]) }
        await controller.waitForWork()
        XCTAssertNil(controller.error)
        XCTAssertNil(controller.draft)
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(controller.recordings.count, 1)
        XCTAssertEqual(controller.notices, ["Unavailable: recorded history is unavailable."])
        XCTAssertEqual(destination.preparations, 0)
        let pending = try XCTUnwrap(controller.recordings.first)
        let file = try XCTUnwrap(pending.pendingRecording?.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let saved = await pending.savePendingRecordingToPhotos()
        XCTAssertTrue(saved)
        XCTAssertEqual(destination.preparations, 1)
        XCTAssertEqual(destination.saved, [file])
        XCTAssertNil(pending.pendingRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testNoVideoRemainsAnErrorNotAnEmptySavePopover() async {
        let controller = CameraHistoryExportController()
        controller.prepare(position: .canonical(1000, paused: true), targets: [.init(name: "Missing", metadata: nil)]) { $0 }
        await controller.waitForWork()
        controller.start(destination: ExportDestination()) { _ in ExportFixtureSource(pieces: []) }
        await controller.waitForWork()
        XCTAssertEqual(controller.error, CameraHistoryExportError.noVideo.localizedDescription)
        XCTAssertTrue(controller.recordings.isEmpty)
        XCTAssertNotNil(controller.draft, "The user can adjust the interval and retry")
    }

#if os(iOS)
    func testNativeRangePopoverLayouts() async throws {
        let controller = CameraHistoryExportController()
        controller.prepare(position: .canonical(1790439635.125, paused: true), targets: []) { $0 }
        await controller.waitForWork()
        let host = UIHostingController(rootView: CameraHistoryExportPopover(export: controller,
            timeZone: TimeZone(identifier: "America/New_York")!, start: {}, cancel: {}))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for mode in CameraHistoryExportDraft.EndSelection.allCases {
            controller.draft?.endSelection = mode
            try await Task.sleep(for: .milliseconds(100))
            let size = host.sizeThatFits(in: CGSize(width: 350, height: 800))
            XCTAssertGreaterThan(size.height, 300)
            XCTAssertLessThan(size.height, 800)
            let landscape = host.sizeThatFits(in: CGSize(width: 350, height: 300))
            XCTAssertLessThanOrEqual(landscape.height, 300, "The range form must scroll in a short landscape popover")
            host.view.bounds = CGRect(origin: .zero, size: size)
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "History export — \(mode.rawValue)"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        window.rootViewController = nil
        try await Task.sleep(for: .milliseconds(100))
    }
#endif

    private func shifted(_ piece: CameraHistoryPiece, by offset: Double, epoch: String? = nil) -> CameraHistoryPiece {
        let old = piece.segment
        let segment = CameraHistorySegment(number: old.number + 1,
            range: .init(start: old.range.start + offset, end: old.range.end + offset),
            time: .init(canonicalUTC: old.time.canonicalUTC + offset, receivedUTC: old.time.receivedUTC + offset,
                        cameraUTC: nil, canonicalSource: old.time.canonicalSource, epochID: epoch ?? old.time.epochID),
            timescale: old.timescale, codec: old.codec, parameterSets: old.parameterSets, nalUnitLengthBytes: old.nalUnitLengthBytes)
        return .init(id: UUID(), segment: segment, samples: piece.samples)
    }

    private func withDuration(_ sample: CameraHistorySample, ticks: Int64) -> CameraHistorySample {
        let frame = sample.frame
        return .init(frame: .init(segment: frame.segment, presentationTicks: frame.presentationTicks,
            decodeTicks: frame.decodeTicks, durationTicks: ticks, keyFrame: frame.keyFrame,
            preroll: frame.preroll, byteCount: frame.byteCount), data: sample.data)
    }

    // Exercise the export writer independently of the S3 container demuxer.
    // These are real encoded samples in the same vocabulary as an NVR response.
    private func historyPiece(_ fixture: S3MediaFixture) throws -> CameraHistoryPiece {
        let format = try XCTUnwrap(fixture.samples.first.flatMap(CMSampleBufferGetFormatDescription))
        let hevc = CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC
        var sets: [Data] = [], length: Int32 = 0
        for index in 0..<(hevc ? 3 : 2) {
            var pointer: UnsafePointer<UInt8>?, size = 0, count = 0
            let status = hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: &length)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: &length)
            XCTAssertEqual(status, noErr)
            sets.append(Data(bytes: try XCTUnwrap(pointer), count: size))
        }
        let segment = CameraHistorySegment(number: 0,
            range: .init(start: 1000, end: 1000 + Double(fixture.samples.count) / 15),
            time: fixture.expected.timing.time, timescale: 90_000, codec: hevc ? "H265" : "H264",
            parameterSets: sets, nalUnitLengthBytes: Int(length))
        let samples = fixture.samples.enumerated().map { index, sample in
            let bytes = S3MediaFixture.payload(sample)
            return CameraHistorySample(frame: .init(segment: 0, presentationTicks: Int64(index) * 6000,
                decodeTicks: nil, durationTicks: 6000, keyFrame: index % 15 == 0,
                preroll: false, byteCount: bytes.count), data: bytes)
        }
        return .init(id: UUID(), segment: segment, samples: samples)
    }

    private func temporaryMovies() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("HomeBase-Camera-") })
    }

    private func readMovie(_ url: URL) async throws -> (samples: [CMSampleBuffer], duration: Double) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [CMSampleBuffer] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { samples.append(sample) }
        }
        XCTAssertEqual(reader.status, .completed)
        // Also exercise decoding, not merely parsing the MOV sample table.
        let decoder = try AVAssetReader(asset: asset)
        let pixels = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        decoder.add(pixels)
        XCTAssertTrue(decoder.startReading())
        var count = 0
        while pixels.copyNextSampleBuffer() != nil { count += 1 }
        XCTAssertEqual(decoder.status, .completed)
        XCTAssertEqual(count, samples.count)
        return (samples, duration)
    }
}

@MainActor private final class ExportDestination: CameraRecordingDestination {
    var preparations = 0
    var saved: [URL] = []
    func prepare() async throws { preparations += 1 }
    func saveVideo(at fileURL: URL, creationDate: Date) async throws { saved.append(fileURL) }
}

private actor ExportFixtureSource: CameraHistoryFetching {
    let pieces: [CameraHistoryPiece]
    let gaps: [CameraHistoryRange]
    let failAt: Int?
    let unresolved: Bool
    let stallAt: Int?
    var requests: [HBNVRMediaRequest] = []
    var closed = false
    init(pieces: [CameraHistoryPiece], gaps: [CameraHistoryRange] = [], failAt: Int? = nil,
         unresolved: Bool = false, stallAt: Int? = nil) {
        self.pieces = pieces; self.gaps = gaps; self.failAt = failAt
        self.unresolved = unresolved; self.stallAt = stallAt
    }
    func start() {}
    func close() { closed = true }
    func fetch(_ request: HBNVRMediaRequest, onBegin: CameraHistoryBeginHandler?) async throws -> CameraHistoryBatch {
        requests.append(request)
        let range = CameraHistoryRange(start: request.range.start, end: request.range.end)
        if requests.count == stallAt { try await Task.sleep(for: .seconds(30)) }
        if requests.count == failAt {
            if unresolved {
                return .init(id: UUID(), range: range, anchor: nil, pieces: [], gaps: [],
                    unresolved: [range], sourceWarning: "Cloud read failed")
            }
            throw URLError(.networkConnectionLost)
        }
        let selected = pieces.compactMap { piece -> CameraHistoryPiece? in
            guard piece.segment.range.intersection(range) != nil else { return nil }
            let key = piece.samples.lastIndex { $0.frame.keyFrame && $0.time(in: piece.segment) <= range.start } ?? 0
            let samples = piece.samples[key...].filter { $0.time(in: piece.segment) < range.end }
            return .init(id: piece.id, segment: piece.segment, samples: samples)
        }
        return .init(id: UUID(), range: range, anchor: nil, pieces: selected,
            gaps: gaps.compactMap { $0.intersection(range) })
    }
}
