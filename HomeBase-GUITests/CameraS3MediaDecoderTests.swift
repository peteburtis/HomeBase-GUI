import AVFoundation
import CoreMedia
import CryptoKit
import UniformTypeIdentifiers
import VideoToolbox
import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraS3MediaDecoderTests: XCTestCase {
    func testRAMOnlyH264FullAndShortShardsPreserveSamplesAndTiming() async throws {
        try await roundTrip(codec: kCMVideoCodecType_H264)
    }
    func testRAMOnlyHEVCFullAndShortShardsPreserveSamplesAndTiming() async throws {
        try await roundTrip(codec: kCMVideoCodecType_HEVC)
    }
    private func roundTrip(codec: CMVideoCodecType) async throws {
        for count in [1, 30] {
            let fixture = try await S3MediaFixture.make(codec: codec, count: count)
            let pieces = try await CameraS3MediaDecoder.decode(data: fixture.data, expected: fixture.expected,
                range: .init(start: 1000, end: 1003))
            let piece = try XCTUnwrap(pieces.first)
            XCTAssertEqual(pieces.count, 1)
            XCTAssertEqual(piece.samples.count, count)
            XCTAssertEqual(piece.segment.time, fixture.expected.timing.time)
            XCTAssertEqual(piece.segment.timescale, 90_000)
            XCTAssertEqual(piece.segment.codec, codec == kCMVideoCodecType_H264 ? "H264" : "H265")
            XCTAssertEqual(piece.samples.map(\.data), fixture.samples.map { S3MediaFixture.payload($0) })
            XCTAssertEqual(piece.samples.map { $0.frame.presentationTicks }, (0..<count).map { Int64($0) * 6000 })
            XCTAssertEqual(piece.samples.map { $0.frame.durationTicks }, Array(repeating: 6000, count: count))
            XCTAssertTrue(piece.samples.first?.frame.keyFrame == true)
            XCTAssertTrue(piece.samples.allSatisfy { !$0.frame.preroll })
            try proveDecodable(piece)
        }
    }
    func testSeekUsesNearestPrecedingKeyframeAndReturnsOnlyRequestedEnd() async throws {
        let fixture = try await S3MediaFixture.make(count: 30)
        let pieces = try await CameraS3MediaDecoder.decode(data: fixture.data, expected: fixture.expected,
            range: .init(start: 1001.2, end: 1001.8))
        let piece = try XCTUnwrap(pieces.first)
        XCTAssertEqual(piece.samples.first?.frame.presentationTicks, 90_000)
        XCTAssertEqual(piece.samples.first?.frame.keyFrame, true)
        XCTAssertEqual(piece.samples.first?.frame.preroll, true)
        XCTAssertEqual(piece.segment.range.start, 1001)
        XCTAssertEqual(piece.segment.range.end, 1001.8)
        XCTAssertTrue(piece.samples.allSatisfy { $0.time(in: piece.segment) < 1001.8 })
        XCTAssertEqual(piece.samples.last?.frame.presentationTicks, 26 * 6000)
        XCTAssertEqual(piece.samples.map(\.data), Array(fixture.samples[15...26]).map { S3MediaFixture.payload($0) })
        try proveDecodable(piece)
    }
    func testNoOverlapReturnsNoMediaAndDoesNotParseUnneededObject() async throws {
        let fixture = try await S3MediaFixture.make(count: 1)
        let pieces = try await CameraS3MediaDecoder.decode(data: Data([1]), expected: fixture.expected,
            range: .init(start: 2000, end: 2001))
        XCTAssertTrue(pieces.isEmpty)
    }
    func testMissingAndMismatchedTimingAreRejected() async throws {
        for metadata in [nil, "{\"format\":\"not-hbnvr\"}"] as [String?] {
            let fixture = try await S3MediaFixture.make(count: 1, overrideMetadata: true, metadata: metadata)
            do {
                _ = try await CameraS3MediaDecoder.decode(data: fixture.data, expected: fixture.expected,
                    range: .init(start: 1000, end: 1001))
                XCTFail("An unindexed or foreign MP4 must not be assigned manifest times")
            } catch { XCTAssertEqual(error as? CameraHistoryError, .invalidResponse) }
        }
        let fixture = try await S3MediaFixture.make(count: 1)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.expected)) as? [String: Any])
        var timing = try XCTUnwrap(object["timing"] as? [String: Any])
        timing["firstFrameReceivedUTC"] = 1000.25
        object["timing"] = timing
        let changed = try JSONDecoder().decode(CameraS3ManifestShard.self, from: JSONSerialization.data(withJSONObject: object))
        do {
            _ = try await CameraS3MediaDecoder.decode(data: fixture.data, expected: changed,
                range: .init(start: 1000, end: 1001))
            XCTFail("Embedded provenance must exactly match the manifest")
        } catch { XCTAssertEqual(error as? CameraHistoryError, .invalidResponse) }
    }
    func testMalformedMediaAndCancelledDecodeFailWithoutTemporaryFiles() async throws {
        let fixture = try await S3MediaFixture.make(count: 1)
        do {
            _ = try await CameraS3MediaDecoder.decode(data: Data(repeating: 0, count: 64), expected: fixture.expected,
                range: .init(start: 1000, end: 1001))
            XCTFail("Malformed MP4 must fail")
        } catch {}
        let task = Task {
            try Task.checkCancellation()
            return try await CameraS3MediaDecoder.decode(data: fixture.data, expected: fixture.expected,
                range: .init(start: 1000, end: 1001))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled decode must not return video") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testIndexedBoundaryAllowsOneContainerTickRoundingButNotExtraFootage() throws {
        XCTAssertEqual(try CameraS3MediaDecoder.boundedDuration(6010, presentation: 6000, end: 12_000,
            sourceScale: 600, outputScale: 90_000), 6000)
        XCTAssertThrowsError(try CameraS3MediaDecoder.boundedDuration(6151, presentation: 6000, end: 12_000,
            sourceScale: 600, outputScale: 90_000))
        XCTAssertThrowsError(try CameraS3MediaDecoder.boundedDuration(6000, presentation: 12_000, end: 12_000,
            sourceScale: 600, outputScale: 90_000))
    }

    private func proveDecodable(_ piece: CameraHistoryPiece) throws {
        let format = try CameraHistorySampleBuilder.format(piece.segment)
        let sink = S3DecodedFrameCount()
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { context, _, status, _, image, _, _ in
            if let context { Unmanaged<S3DecodedFrameCount>.fromOpaque(context).takeUnretainedValue().receive(status, image: image) }
        }, decompressionOutputRefCon: Unmanaged.passUnretained(sink).toOpaque())
        var optionalSession: VTDecompressionSession?
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: nil, outputCallback: &callback, decompressionSessionOut: &optionalSession), noErr)
        let session = try XCTUnwrap(optionalSession)
        defer { VTDecompressionSessionInvalidate(session) }
        for sample in piece.samples {
            let buffer = try CameraHistorySampleBuilder.sample(sample, segment: piece.segment,
                format: format, origin: 0, display: true)
            XCTAssertEqual(VTDecompressionSessionDecodeFrame(session, sampleBuffer: buffer,
                flags: [], frameRefcon: nil, infoFlagsOut: nil), noErr)
        }
        XCTAssertEqual(VTDecompressionSessionWaitForAsynchronousFrames(session), noErr)
        XCTAssertEqual(sink.count, piece.samples.count)
        XCTAssertTrue(sink.success)
    }
}

private nonisolated final class S3DecodedFrameCount: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0, failed = false
    var count: Int { lock.lock(); defer { lock.unlock() }; return frames }
    var success: Bool { lock.lock(); defer { lock.unlock() }; return !failed }
    func receive(_ status: OSStatus, image: CVImageBuffer?) {
        lock.lock(); defer { lock.unlock() }
        if status == noErr, image != nil { frames += 1 } else { failed = true }
    }
}

/// Test fixtures use segment-output AVAssetWriter too: neither fixture creation
/// nor the decoder takes a filesystem URL or writes the clear-text recording.
@MainActor private struct S3MediaFixture {
    let data: Data
    let expected: CameraS3ManifestShard
    let samples: [CMSampleBuffer]

    static func make(codec: CMVideoCodecType = kCMVideoCodecType_H264, count: Int,
                     overrideMetadata: Bool = false, metadata: String? = nil) async throws -> Self {
        let samples = try encode(codec: codec, count: count)
        let id = UUID().uuidString
        let timing: [String: Any] = ["format": "com.graygoolabs.hbnvr.timing", "schemaVersion": 1,
            "storeID": UUID().uuidString, "cameraID": UUID().uuidString, "shardID": id,
            "time": ["canonicalUTC": 1000.0, "receivedUTC": 1000.0, "canonicalSource": "received", "epochID": UUID().uuidString],
            "firstFrameReceivedUTC": 1000.0, "timescale": 90_000, "rtpTimestamp": 42]
        let string = String(decoding: try JSONSerialization.data(withJSONObject: timing, options: [.sortedKeys]), as: UTF8.self)
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        let sink = S3MP4Segments()
        writer.delegate = sink
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = .indefinite
        writer.initialSegmentStartTime = .zero
        if let text = overrideMetadata ? metadata : string {
            let item = AVMutableMetadataItem()
            item.identifier = .iTunesMetadataDescription
            item.value = text as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            writer.metadata = [item]
        }
        let format = try XCTUnwrap(samples.first.flatMap(CMSampleBufferGetFormatDescription))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        XCTAssertTrue(writer.canAdd(input)); writer.add(input)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for sample in samples {
            let deadline = ContinuousClock.now + .seconds(10)
            while !input.isReadyForMoreMediaData, writer.status == .writing, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            XCTAssertTrue(input.append(sample), String(describing: writer.error))
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(count), timescale: 15))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
        let bytes = sink.data
        XCTAssertFalse(bytes.isEmpty)
        let manifest: [String: Any] = ["id": id, "key": "camera/recording.mp4", "size": bytes.count,
            "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "timing": timing, "endTicks": count * 6000]
        let expected = try JSONDecoder().decode(CameraS3ManifestShard.self, from: JSONSerialization.data(withJSONObject: manifest))
        return Self(data: bytes, expected: expected, samples: samples)
    }
    static func payload(_ sample: CMSampleBuffer) -> Data {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return Data() }
        var result = Data(count: CMBlockBufferGetDataLength(block))
        XCTAssertEqual(result.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }, noErr)
        return result
    }
    private static func encode(codec: CMVideoCodecType, count: Int) throws -> [CMSampleBuffer] {
        let sink = S3EncodedFrames()
        var optional: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: 64, height: 64, codecType: codec,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { context, _, status, _, sample in
                if status == noErr, let context, let sample {
                    Unmanaged<S3EncodedFrames>.fromOpaque(context).takeUnretainedValue().append(sample)
                }
            }, refcon: Unmanaged.passUnretained(sink).toOpaque(), compressionSessionOut: &optional)
        guard status == noErr, let encoder = optional else { throw XCTSkip("VideoToolbox encoder unavailable on this runner: \(status)") }
        defer { VTCompressionSessionInvalidate(encoder) }
        XCTAssertEqual(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse), noErr)
        XCTAssertEqual(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 15)), noErr)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel), noErr)
        let buffer = try XCTUnwrap(pixel)
        for index in 0..<count {
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(40 + index), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let properties = index % 15 == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            XCTAssertEqual(VTCompressionSessionEncodeFrame(encoder, imageBuffer: buffer,
                presentationTimeStamp: CMTime(value: Int64(index), timescale: 15), duration: CMTime(value: 1, timescale: 15),
                frameProperties: properties, sourceFrameRefcon: nil, infoFlagsOut: nil), noErr)
        }
        XCTAssertEqual(VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid), noErr)
        XCTAssertEqual(sink.samples.count, count)
        return sink.samples
    }
}

private nonisolated final class S3EncodedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CMSampleBuffer] = []
    var samples: [CMSampleBuffer] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ sample: CMSampleBuffer) { lock.lock(); values.append(sample); lock.unlock() }
}
private nonisolated final class S3MP4Segments: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [Data] = []
    var data: Data { lock.lock(); defer { lock.unlock() }; return segments.reduce(into: Data()) { $0.append($1) } }
    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType) {
        lock.lock(); segments.append(Data(segmentData)); lock.unlock()
    }
}
