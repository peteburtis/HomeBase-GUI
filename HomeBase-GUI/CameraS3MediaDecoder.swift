import AVFoundation
import CoreMedia
import Foundation

/// Demuxes an already authenticated/decrypted object without a temporary file or
/// transcoding. Its output is the same compressed sample vocabulary as local IPC.
nonisolated enum CameraS3MediaDecoder {
    static let maximumBytes = 64 * 1024 * 1024
    static let maximumSamples = 30_000
    static let maximumFrameBytes = 8 * 1024 * 1024

    @concurrent static func decode(data: Data, expected: CameraS3ManifestShard,
                                   range: CameraHistoryRange) async throws -> [CameraHistoryPiece] {
        try Task.checkCancellation()
        guard range.isValid, range.duration <= 120.001, !data.isEmpty,
              expected.endTicks > 0, expected.timing.timescale > 0,
              expected.timing.timescale <= Int32.max else { throw CameraHistoryError.invalidResponse }
        guard data.count <= 256 * 1024 * 1024 else { throw CameraHistoryError.tooLarge }
        let timing = expected.timing
        guard timing.format == "com.graygoolabs.hbnvr.timing", timing.schemaVersion == 1,
              timing.shardID == expected.id,
              [timing.storeID, timing.cameraID, timing.shardID, timing.time.epochID].allSatisfy({ UUID(uuidString: $0) != nil }),
              timing.firstFrameReceivedUTC.isFinite,
              timing.time.canonicalUTC == (timing.time.canonicalSource == "camera" ? timing.time.cameraUTC : timing.time.receivedUTC) else {
            throw CameraHistoryError.invalidResponse
        }
        let end = timing.time.canonicalUTC + Double(expected.endTicks) / Double(timing.timescale)
        guard end.isFinite, abs(end) < 1e11 else { throw CameraHistoryError.invalidResponse }
        let sourceRange = CameraHistoryRange(start: timing.time.canonicalUTC, end: end)
        guard let requested = sourceRange.intersection(range) else { return [] }
        let source = CameraS3MemoryAsset(data: data)
        return try await withTaskCancellationHandler {
            defer { source.cancel() }
            let track = try await inspect(source, expected: timing)
            return try read(source, track: track, expected: expected, requested: requested)
        } onCancel: { source.cancel() }
    }

    private static func inspect(_ source: CameraS3MemoryAsset, expected: CameraS3ShardTiming) async throws -> AVAssetTrack {
        // AVFoundation opening corrupt/unrecognized assets must not leave a seek
        // spinning indefinitely; cancellation also interrupts outstanding reads.
        try await withThrowingTaskGroup(of: AVAssetTrack.self) { group in
            group.addTask {
                let tracks = try await source.asset.loadTracks(withMediaType: .video)
                guard tracks.count == 1, let track = tracks.first else { throw CameraHistoryError.invalidResponse }
                var found = false
                let items = try await source.asset.load(.metadata)
                guard items.count <= 128 else { throw CameraHistoryError.invalidResponse }
                for item in items {
                    try Task.checkCancellation()
                    guard let string = try await item.load(.stringValue) else { continue }
                    guard string.utf8.count <= 65_536 else { throw CameraHistoryError.invalidResponse }
                    guard let value = try? JSONDecoder().decode(CameraS3ShardTiming.self, from: Data(string.utf8)),
                          value.format == "com.graygoolabs.hbnvr.timing" else { continue }
                    guard !found, value == expected else { throw CameraHistoryError.invalidResponse }
                    found = true
                }
                guard found else { throw CameraHistoryError.invalidResponse }
                return track
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                source.cancel()
                throw CameraHistoryError.remote(nil, "Timed out opening the S3 recording.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func read(_ source: CameraS3MemoryAsset, track: AVAssetTrack,
                             expected: CameraS3ManifestShard, requested: CameraHistoryRange) throws -> [CameraHistoryPiece] {
        let scale = Int32(expected.timing.timescale), anchor = expected.timing.time.canonicalUTC
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        func check() throws {
            try Task.checkCancellation()
            guard !source.isCancelled else { throw CancellationError() }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CameraHistoryError.remote(nil, "Timed out reading the S3 recording.")
            }
        }
        func reader(start: Int64 = 0) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
            let reader = try AVAssetReader(asset: source.asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw CameraHistoryError.invalidResponse }
            reader.add(output)
            reader.timeRange = CMTimeRange(start: CMTime(value: start, timescale: scale),
                end: CMTime(value: expected.endTicks, timescale: scale))
            guard reader.startReading() else { throw CameraHistoryError.invalidResponse }
            return (reader, output)
        }
        // Find the nearest preceding keyframe explicitly. This avoids relying on
        // undocumented AVAssetReader seek-preroll behavior and retains only one
        // scanned compressed sample at a time.
        let (scan, scanOutput) = try reader()
        var keyTicks: Int64?, scanned = 0
        defer { scan.cancelReading() }
        while let sample = scanOutput.copyNextSampleBuffer() {
            try check()
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            scanned += 1
            guard scanned < maximumSamples else { throw CameraHistoryError.tooLarge }
            let pts = try ticks(CMSampleBufferGetPresentationTimeStamp(sample), scale: scale)
            guard pts >= 0, pts < expected.endTicks else { throw CameraHistoryError.invalidResponse }
            let time = anchor + Double(pts) / Double(scale)
            if isKey(sample), time <= requested.start { keyTicks = pts }
            if time >= requested.start {
                if keyTicks == nil, isKey(sample), time < requested.end { keyTicks = pts }
                if keyTicks != nil || time >= requested.end { break }
            }
        }
        guard scan.status != .failed else { throw CameraHistoryError.invalidResponse }
        scan.cancelReading()
        guard let start = keyTicks else { return [] }
        let (video, output) = try reader(start: start)
        defer { video.cancelReading() }
        var samples: [CameraHistorySample] = [], bytes = 0
        var segment: CameraHistorySegment?, firstFormat: CMFormatDescription?, previous: Int64?
        while let sample = output.copyNextSampleBuffer() {
            try check()
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            let pts = try ticks(CMSampleBufferGetPresentationTimeStamp(sample), scale: scale)
            if pts < start { continue }
            let time = anchor + Double(pts) / Double(scale)
            if time >= requested.end { break }
            let rawDuration = CMSampleBufferGetDuration(sample)
            let duration = try boundedDuration(try ticks(rawDuration, scale: scale), presentation: pts,
                end: expected.endTicks, sourceScale: rawDuration.timescale, outputScale: scale)
            guard previous.map({ pts > $0 }) ?? true,
                  CMSampleBufferGetNumSamples(sample) == 1,
                  let format = CMSampleBufferGetFormatDescription(sample),
                  let block = CMSampleBufferGetDataBuffer(sample) else { throw CameraHistoryError.invalidResponse }
            if segment == nil {
                guard isKey(sample), pts == start else { throw CameraHistoryError.invalidResponse }
                let codec = try configuration(format)
                let value = CameraHistorySegment(number: 0, range: .init(start: time, end: requested.end),
                    time: expected.timing.time, timescale: UInt32(scale), codec: codec.name,
                    parameterSets: codec.sets, nalUnitLengthBytes: codec.length)
                try value.validate()
                segment = value; firstFormat = format
            } else if let firstFormat, !CMFormatDescriptionEqual(firstFormat, otherFormatDescription: format) {
                throw CameraHistoryError.invalidResponse
            }
            let decode = CMSampleBufferGetDecodeTimeStamp(sample)
            let dts = decode.isNumeric ? try ticks(decode, scale: scale) : nil
            // Same no-B-frame contract as local history and the NVR writer.
            guard dts == nil || dts == pts else { throw CameraHistoryError.invalidResponse }
            let size = CMBlockBufferGetDataLength(block)
            guard size > 0 else { throw CameraHistoryError.invalidResponse }
            guard size <= maximumFrameBytes, size <= maximumBytes - bytes,
                  samples.count < maximumSamples else { throw CameraHistoryError.tooLarge }
            var payload = Data(count: size)
            let copied = payload.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!)
            }
            guard copied == noErr,
                  CameraHistoryResponseParser.validAccessUnit(payload, lengthBytes: segment!.nalUnitLengthBytes) else {
                throw CameraHistoryError.invalidResponse
            }
            samples.append(.init(frame: .init(segment: 0, presentationTicks: pts, decodeTicks: dts,
                durationTicks: duration, keyFrame: isKey(sample), preroll: time < requested.start,
                byteCount: size), data: payload))
            bytes += size; previous = pts
        }
        try check()
        guard video.status != .failed else { throw CameraHistoryError.invalidResponse }
        guard let segment, !samples.isEmpty else { return [] }
        return [.init(id: UUID(), segment: segment, samples: samples)]
    }

    private static func ticks(_ time: CMTime, scale: Int32) throws -> Int64 {
        guard time.isNumeric, time.seconds.isFinite else { throw CameraHistoryError.invalidResponse }
        let converted = CMTimeConvertScale(time, timescale: scale, method: .default)
        guard converted.isNumeric else { throw CameraHistoryError.invalidResponse }
        return converted.value
    }
    private static func isKey(_ sample: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
        return !(attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false)
    }
    static func boundedDuration(_ duration: Int64, presentation: Int64, end: Int64,
                                sourceScale: Int32, outputScale: Int32) throws -> Int64 {
        guard presentation >= 0, presentation < end, duration > 0, sourceScale > 0, outputScale > 0 else {
            throw CameraHistoryError.invalidResponse
        }
        let remaining = end - presentation
        if duration <= remaining { return duration }
        // A container may use a coarser clock than the manifest's exact RTP clock.
        // Clip at the indexed frontier, accepting only one container tick of rounding.
        let rounding = (Int64(outputScale) + Int64(sourceScale) - 1) / Int64(sourceScale)
        guard duration - remaining <= rounding else { throw CameraHistoryError.invalidResponse }
        return remaining
    }
    private static func configuration(_ format: CMFormatDescription) throws -> (name: String, sets: [Data], length: Int) {
        let type = CMFormatDescriptionGetMediaSubType(format), hevc = type == kCMVideoCodecType_HEVC
        guard hevc || type == kCMVideoCodecType_H264 else { throw CameraHistoryError.invalidResponse }
        var sets: [Data] = [], count = 0, length: Int32 = 0
        for index in 0..<(hevc ? 3 : 2) {
            var pointer: UnsafePointer<UInt8>?, size = 0
            let status = hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: &length)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: &length)
            guard status == noErr, let pointer, size > 0, size <= 65_536 else { throw CameraHistoryError.invalidResponse }
            sets.append(Data(bytes: pointer, count: size))
        }
        guard [1, 2, 4].contains(length) else { throw CameraHistoryError.invalidResponse }
        return (hevc ? "H265" : "H264", sets, Int(length))
    }
}

/// Custom-scheme resource loading keeps both asset inspection and compressed
/// reads in RAM; there is no file URL, cache directory, or temporary media file.
private nonisolated final class CameraS3MemoryAsset: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let asset: AVURLAsset
    private let data: Data
    private let queue = DispatchQueue(label: "HomeBase.camera.s3.memory-asset")
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    init(data: Data) {
        self.data = data
        asset = AVURLAsset(url: URL(string: "homebase-s3-media://recording/" + UUID().uuidString + ".mp4")!,
            options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock(); asset.cancelLoading() }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        do {
            guard !isCancelled else { throw CancellationError() }
            // A supplied movie may not turn its data-reference atoms into local
            // file reads or network requests, even within this custom scheme.
            guard request.request.url == asset.url else { throw CameraHistoryError.invalidResponse }
            if let information = request.contentInformationRequest {
                information.contentType = AVFileType.mp4.rawValue
                information.contentLength = Int64(data.count)
                information.isByteRangeAccessSupported = true
            }
            if let read = request.dataRequest {
                let size = Int64(data.count)
                var offset = max(read.requestedOffset, read.currentOffset)
                guard read.requestedOffset >= 0, offset >= 0, offset <= size, read.requestedLength >= 0,
                      read.requestedOffset <= Int64.max - Int64(read.requestedLength) else {
                    throw CameraHistoryError.invalidResponse
                }
                let end = read.requestsAllDataToEndOfResource ? size : min(size, read.requestedOffset + Int64(read.requestedLength))
                while offset < end, !request.isCancelled {
                    guard !isCancelled else { throw CancellationError() }
                    let next = min(end, offset + 1024 * 1024)
                    read.respond(with: data.subdata(in: Int(offset)..<Int(next)))
                    offset = next
                }
            }
            if !request.isCancelled { request.finishLoading() }
        } catch { request.finishLoading(with: NSError(domain: "HomeBaseS3Media", code: 1)) }
        return true
    }
}
