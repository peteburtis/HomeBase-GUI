import AVFoundation
import Combine
import Foundation
import HomeBaseProtocol

struct CameraHistoryExportDraft {
    enum EndSelection: String, CaseIterable { case duration = "Duration", date = "End time" }
    static let maximumDuration: TimeInterval = 24 * 60 * 60
    var start: Date
    var end: Date
    var endSelection: EndSelection = .duration
    var hours = 0
    var minutes = 1

    init(start: Date) { self.start = start; end = start.addingTimeInterval(60) }

    var range: CameraHistoryRange {
        .init(start: start.timeIntervalSince1970, end: endSelection == .date
            ? end.timeIntervalSince1970
            : start.timeIntervalSince1970 + Double(hours * 3600 + minutes * 60))
    }
    var validationMessage: String? {
        guard range.isValid else { return "Choose an end time after the start time." }
        guard range.duration <= Self.maximumDuration else { return "Export up to 24 hours at a time." }
        return nil
    }
}

enum CameraHistoryExportError: LocalizedError {
    case noVideo, invalidRange, incomplete(String), writing
    var errorDescription: String? {
        switch self {
        case .noVideo: "No recorded video is available in this interval."
        case .invalidRange: "Choose an export interval between zero and 24 hours."
        case .incomplete(let message): "The complete interval could not be read. \(message)"
        case .writing: "The history video could not be written to a movie."
        }
    }
}

/// Independent of the playback reader and live recorder. One small request is
/// retained at a time, even for an hours-long export. Errors never masquerade as
/// recording gaps or produce a silently truncated successful export.
@MainActor
enum CameraHistoryExporter {
    struct Result {
        let recordings: [CameraLocalRecording]
        let hasGaps: Bool
    }

    static func export(cameraID: String, name: String, range: CameraHistoryRange,
                       source: any CameraHistoryFetching,
                       windowDuration: Double = 10,
                       progress: (Double) -> Void = { _ in }) async throws -> Result {
        let movies = CameraHistoryMovieWriter(name: name, range: range)
        do {
            guard range.isValid, range.duration <= CameraHistoryExportDraft.maximumDuration,
                  windowDuration > 0, windowDuration <= 120 else { throw CameraHistoryExportError.invalidRange }
            var cursor = range.start
            var hasGaps = false
            while cursor < range.end {
                try Task.checkCancellation()
                let end = min(range.end, cursor + windowDuration)
                let batch = try await source.fetch(.init(requestID: UUID().uuidString, operation: "frames",
                    cameraID: cameraID, timeline: "canonical", range: .init(start: cursor, end: end)))
                try Task.checkCancellation()
                guard batch.unresolved.isEmpty else {
                    throw CameraHistoryExportError.incomplete(batch.sourceWarning ?? "Some footage could not be retrieved.")
                }
                hasGaps = hasGaps || !batch.gaps.isEmpty
                for piece in batch.pieces.sorted(by: { $0.segment.range.start < $1.segment.range.start }) {
                    try await movies.append(piece, window: .init(start: cursor, end: end))
                }
                cursor = end
                progress((cursor - range.start) / range.duration)
                await Task.yield()
            }
            try await movies.finish()
            try Task.checkCancellation()
            await source.close()
            try Task.checkCancellation()
            return Result(recordings: movies.recordings, hasGaps: hasGaps)
        } catch {
            movies.discard()
            await source.close()
            throw error
        }
    }
}

/// Pass-through H.264/HEVC. Compatible chunks are concatenated on a movie-local
/// clock, irrespective of gaps, timestamp rounding or recording-clock epochs.
/// Only a decoder-format change requires a separate movie. New decoding chains
/// retain their preceding keyframe; known repeated GOP preroll is omitted.
@MainActor
final class CameraHistoryMovieWriter {
    private let name: String
    private let range: CameraHistoryRange
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var url: URL?
    private var format: CMVideoFormatDescription?
    private var segment: CameraHistorySegment?
    private var lastSample: CameraHistorySample?
    private var lastTime: Double?
    private var outputEnd: CMTime = .zero
    private var creationTime: Double = 0
    private(set) var recordings: [CameraLocalRecording] = []

    init(name: String, range: CameraHistoryRange) { self.name = name; self.range = range }

    func append(_ piece: CameraHistoryPiece, window: CameraHistoryRange) async throws {
        try Task.checkCancellation()
        let incoming = piece.segment
        guard let selected = incoming.range.intersection(window),
              let firstSelected = piece.samples.firstIndex(where: {
                  $0.time(in: incoming) < selected.end && $0.end(in: incoming) > selected.start
              }) else { return }
        let compatible = segment?.codec == incoming.codec
            && segment?.parameterSets == incoming.parameterSets
            && segment?.nalUnitLengthBytes == incoming.nalUnitLengthBytes
        // Repeated GOP preroll at request boundaries is not appended twice.
        // Match the actual last encoded frame, not its nominal end time: frame
        // durations and the next PTS need not line up, and epochs can change.
        let overlap = compatible ? piece.samples.lastIndex {
            guard let segment, let lastTime, let lastSample else { return false }
            let tolerance = max(1 / Double(incoming.timescale), 1 / Double(segment.timescale)) + 0.000_001
            return abs($0.time(in: incoming) - lastTime) <= tolerance && $0.data == lastSample.data
        } : nil
        let first: Int
        if let overlap {
            first = overlap + 1
            guard first < piece.samples.count else { return }
        } else {
            // Without an identified shared decoder prefix, concatenate the new
            // GOP from its keyframe. Do not drop dependent frames or feed them
            // to the previous GOP's decoder state just to trim a clock overlap.
            guard let key = piece.samples[...firstSelected].lastIndex(where: { $0.frame.keyFrame }) else {
                throw CameraHistoryError.invalidResponse
            }
            first = key
        }
        guard piece.samples[first].time(in: incoming) < min(range.end, selected.end) else { return }
        if !compatible {
            try await finish()
            try begin(segment: incoming, time: piece.samples[first].time(in: incoming))
        }
        guard let writer, let input, let format else { throw CameraHistoryExportError.writing }
        // Preserve timing within each chunk, but place its first new frame
        // directly after the preceding chunk. Never use a wall-clock delta as
        // the output gap or a reason to split/replay a GOP into another file.
        let chunkStart = outputEnd
        let firstPTS = CMTime(value: piece.samples[first].frame.presentationTicks, timescale: Int32(incoming.timescale))
        for index in first..<piece.samples.count {
            try Task.checkCancellation()
            let sample = piece.samples[index]
            let time = sample.time(in: incoming)
            guard time < min(range.end, selected.end) else { break }
            let raw = try CameraHistorySampleBuilder.sample(sample, segment: incoming, format: format, origin: 0, display: true)
            let scale = Int32(incoming.timescale)
            let pts = CMTimeAdd(chunkStart, CMTimeSubtract(CMTime(value: sample.frame.presentationTicks, timescale: scale), firstPTS))
            let duration = sample.end(in: incoming) > range.end
                ? CMTime(seconds: range.end - time, preferredTimescale: scale)
                : CMTime(value: sample.frame.durationTicks, timescale: scale)
            var timing = CMSampleTimingInfo(duration: duration,
                presentationTimeStamp: pts,
                decodeTimeStamp: sample.frame.decodeTicks.map {
                    CMTimeAdd(chunkStart, CMTimeSubtract(CMTime(value: $0, timescale: scale), firstPTS))
                } ?? .invalid)
            var adjusted: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: raw,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &adjusted) == noErr,
                  let adjusted else { throw CameraHistoryExportError.writing }
            let deadline = ContinuousClock.now + .seconds(15)
            while !input.isReadyForMoreMediaData, writer.status == .writing, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try Task.checkCancellation()
            guard writer.status == .writing, input.isReadyForMoreMediaData, input.append(adjusted) else {
                throw writer.error ?? CameraHistoryExportError.writing
            }
            segment = incoming; lastSample = sample; lastTime = time
            outputEnd = CMTimeAdd(pts, duration)
            if index % 32 == 0 { await Task.yield() }
        }
    }

    private func begin(segment: CameraHistorySegment, time: Double) throws {
        guard recordings.count < 1000 else { throw CameraHistoryError.tooLarge }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HomeBase-Camera-\(UUID().uuidString)")
        let filename = CameraLocalRecordingController.filename(cameraName: name, creationDate: Date(timeIntervalSince1970: time))
        // Part numbers also distinguish sub-second discontinuities when sharing
        // several clips with Files destinations that flatten their directories.
        let output = directory.appendingPathComponent(filename.replacingOccurrences(of: ".mov", with: " - \(recordings.count + 1).mov"))
        url = output
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let description = try CameraHistorySampleBuilder.format(segment)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        self.writer = writer
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: description)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw CameraHistoryExportError.writing }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CameraHistoryExportError.writing }
        writer.startSession(atSourceTime: .zero)
        self.input = input; format = description; creationTime = time
    }

    func finish() async throws {
        guard let writer, let input, let url else { return }
        writer.endSession(atSourceTime: outputEnd)
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CameraHistoryExportError.writing }
        recordings.append(.init(fileURL: url, creationDate: Date(timeIntervalSince1970: creationTime)))
        self.writer = nil; self.input = nil; self.url = nil; format = nil
        segment = nil; lastSample = nil; lastTime = nil; outputEnd = .zero
    }

    func discard() {
        writer?.cancelWriting()
        if let url { CameraLocalRecordingController.removeRecordingFile(at: url) }
        recordings.forEach { CameraLocalRecordingController.removeRecordingFile(at: $0.fileURL) }
        writer = nil; input = nil; url = nil; recordings = []
        segment = nil; lastSample = nil; lastTime = nil; outputEnd = .zero
    }
}

@MainActor
final class CameraHistoryExportController: ObservableObject {
    struct Target {
        let name: String
        let metadata: HBCameraPlaybackMetadata?
    }
    @Published var draft: CameraHistoryExportDraft?
    @Published private(set) var isPreparing = false
    @Published private(set) var isExporting = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var notices: [String] = []
    @Published private(set) var recordings: [CameraLocalRecordingController] = []
    private var observations: Set<AnyCancellable> = []
    private var targets: [Target] = []
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var isBusy: Bool { isPreparing || isExporting }

    func prepare(position: CameraSwitchPosition, targets: [Target],
                 resolve: @escaping (CameraSwitchPosition) async throws -> CameraSwitchPosition) {
        guard !isBusy else { return }
        cancel()
        self.targets = targets; isPreparing = true; status = "Reading playhead time…"
        let id = generation
        task = Task { [self] in
            defer { if generation == id { isPreparing = false; task = nil } }
            do {
                let resolved = try await resolve(position)
                try Task.checkCancellation()
                guard generation == id else { return }
                guard case .canonical(let time, _) = resolved else { throw CameraHistoryError.unavailable }
                draft = .init(start: Date(timeIntervalSince1970: time))
            } catch {
                if generation == id, !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func start(destination: any CameraRecordingDestination,
               makeSource: @escaping (HBCameraPlaybackMetadata) async -> any CameraHistoryFetching) {
        guard !isBusy, let draft, draft.validationMessage == nil, !targets.isEmpty else { return }
        isExporting = true; error = nil; notices = []; progress = 0
        let id = generation, targets = targets, range = draft.range
        task = Task { [self] in
            var completed: [CameraLocalRecording] = []
            defer { if generation == id { isExporting = false; task = nil } }
            do {
                var warnings: [String] = []
                for (index, target) in targets.enumerated() {
                    try Task.checkCancellation()
                    guard let metadata = target.metadata else {
                        warnings.append("\(target.name): recorded history is unavailable."); continue
                    }
                    status = "Exporting \(target.name)…"
                    let source = await makeSource(metadata)
                    let result = try await CameraHistoryExporter.export(cameraID: metadata.cameraID,
                        name: target.name, range: range, source: source) { fraction in
                            if self.generation == id { self.progress = (Double(index) + fraction) / Double(targets.count) }
                        }
                    completed += result.recordings
                    if result.recordings.isEmpty { warnings.append("\(target.name): no video in this interval.") }
                    else if result.hasGaps { warnings.append("\(target.name): some of the requested interval was not recorded.") }
                }
                try Task.checkCancellation()
                guard generation == id else { throw CancellationError() }
                guard !completed.isEmpty else { throw CameraHistoryExportError.noVideo }
                recordings = completed.map { .init(destination: destination, pendingRecording: $0) }
                observations = Set(recordings.map { recording in
                    recording.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
                })
                notices = warnings; self.draft = nil; progress = 1
            } catch {
                completed.forEach { CameraLocalRecordingController.removeRecordingFile(at: $0.fileURL) }
                if generation == id, !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        isPreparing = false; isExporting = false; draft = nil; error = nil
    }

    func waitForWork() async { await task?.value }
}
