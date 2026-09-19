import XCTest
import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import HomeBaseProtocol
@testable import HomeBase_GUI

@MainActor
final class CameraS3ThumbnailTests: XCTestCase {
    let camera = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    let storeID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    let slot = 1_789_732_800.0 + 600 // 2026-09-18 12:10 UTC
    func store(encrypted: Bool = false) -> HBCameraPlaybackMetadata.S3Store {
        .init(id: storeID, name: "Archive", bucket: "synthetic-bucket", region: "us-west-2", prefix: "Room + %20/",
              clientEncryptionFormat: encrypted ? "hbnvr-pbe-v1" : nil, playbackManifestVersion: 1)
    }
    func request(timestamp: Double? = nil) -> HBNVRThumbnailRequest {
        .init(requestID: UUID().uuidString, cameraID: camera, timeline: "canonical", timestamp: timestamp ?? slot, size: .init(width: 320, height: 180))
    }
    func jpeg(cameraID: String? = nil, time: Double? = nil, width: Int = 1280, height: Int = 720, caption: Bool = true) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData(), image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        let info = CameraS3Thumbnail.Caption(storeID: storeID, cameraID: cameraID ?? camera, slot: slot, timestamp: time ?? slot - 1)
        let text = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
        let properties: [CFString: Any] = caption ? [kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: text]] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return output as Data
    }
    func encrypted(_ data: Data) throws -> Data {
        let salt = Data(0..<32), nonce = Data(32..<44)
        let header = CameraS3Decryption.magic + Data([0, 9, 39, 192]) + salt + nonce
        let key = try CameraS3Decryption.deriveKey(password: "test password", salt: salt, rounds: 600_000)
        let box = try AES.GCM.seal(data, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: header)
        return header + box.ciphertext + box.tag
    }
    func testUTCKeyLayoutMatchesRecorderAndPreservesRawPrefix() {
        XCTAssertEqual(CameraS3Thumbnail.key(prefix: store().prefix, cameraID: camera, slot: slot, encrypted: true),
            "Room + %20/.hbnvr/playback/v1/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/thumbnails/2026-09-18/12-10.jpg.hbnvr")
        XCTAssertEqual(CameraS3Thumbnail.slot(containing: slot - 600), slot)
        XCTAssertEqual(CameraS3Thumbnail.slot(containing: slot + 599), slot)
        XCTAssertEqual(CameraS3Thumbnail.slot(containing: slot + 600), slot + 1200)
    }
    func testEncryptedAndPlainPreviewsAreReadDirectlyAndDownsampledInMemory() async throws {
        for encryption in [false, true] {
            let destination = store(encrypted: encryption), original = try jpeg()
            let bytes = encryption ? try encrypted(original) : original
            let key = CameraS3Thumbnail.key(prefix: destination.prefix, cameraID: camera, slot: slot, encrypted: encryption)
            let objects = ThumbnailObjects(files: [key: bytes])
            let reader = CameraS3ThumbnailReader(store: destination, cameraID: camera, password: "test password", objects: objects)
            let response = try await reader.thumbnail(request())
            let result = try XCTUnwrap(response)
            XCTAssertEqual(result.width, 320); XCTAssertEqual(result.height, 180); XCTAssertEqual(result.timestamp, slot - 1)
            XCTAssertLessThan(result.data.count, original.count)
            let reads = await objects.requests; XCTAssertEqual(reads, [key])
            await reader.close()
            do { _ = try await reader.thumbnail(request()); XCTFail("Closed reader") } catch { XCTAssertTrue(error is CancellationError) }
            let closed = await objects.closed; XCTAssertTrue(closed)
        }
    }
    func testJPEGRejectsWrongIdentityTimingMissingCaptionAndOversizedDimensions() throws {
        let full = try jpeg(), truncated = Data(full.prefix(full.count / 2))
        for bytes in [try jpeg(cameraID: UUID().uuidString), try jpeg(time: slot + 1), try jpeg(time: slot - 121),
                      try jpeg(caption: false), try jpeg(width: 1281), truncated, Data("not a JPEG".utf8)] {
            XCTAssertThrowsError(try CameraS3Thumbnail.decode(bytes, storeID: storeID, cameraID: camera, slot: slot, size: request().size))
        }
        let portrait = try CameraS3Thumbnail.decode(jpeg(width: 360, height: 720), storeID: storeID, cameraID: camera, slot: slot, size: request().size)
        XCTAssertEqual(portrait.width, 90); XCTAssertEqual(portrait.height, 180)
    }
    func testHistoricalSuffixFallbackAndMissingVersusDenied() async throws {
        let destination = store()
        let oldKey = CameraS3Thumbnail.key(prefix: destination.prefix, cameraID: camera, slot: slot, encrypted: true)
        let objects = ThumbnailObjects(files: [oldKey: try encrypted(jpeg())], missing: .accessDenied)
        let reader = CameraS3ThumbnailReader(store: destination, cameraID: camera, password: "test password", objects: objects)
        let found = try await reader.thumbnail(request()); XCTAssertNotNil(found)
        let reads = await objects.requests; XCTAssertEqual(reads.count, 2); XCTAssertEqual(reads.last, oldKey)
        for failure in [CameraS3ReadError.missing, .accessDenied] {
            let empty = CameraS3ThumbnailReader(store: destination, cameraID: camera, password: nil,
                objects: ThumbnailObjects(files: [:], missing: failure))
            do { let result = try await empty.thumbnail(request()); XCTAssertNil(result); XCTAssertEqual(failure, .missing) }
            catch { XCTAssertEqual(error as? CameraS3ReadError, .accessDenied); XCTAssertEqual(failure, .accessDenied) }
        }
    }
    func testEncryptedStoreNeverDowngradesToPlaintextPreview() async throws {
        let destination = store(encrypted: true)
        let plainKey = CameraS3Thumbnail.key(prefix: destination.prefix, cameraID: camera, slot: slot, encrypted: false)
        let encryptedKey = plainKey + ".hbnvr", plain = try jpeg()
        for files in [[plainKey: plain], [encryptedKey: plain]] {
            let objects = ThumbnailObjects(files: files)
            let reader = CameraS3ThumbnailReader(store: destination, cameraID: camera, password: "test password", objects: objects)
            do { let result = try await reader.thumbnail(request()); XCTAssertNil(result); XCTAssertNil(files[encryptedKey]) }
            catch { XCTAssertEqual(error as? CameraS3Decryption.Failure, .invalidEnvelope); XCTAssertNotNil(files[encryptedKey]) }
            let reads = await objects.requests; XCTAssertEqual(reads, [encryptedKey])
        }
    }
    func testBadPasswordNeverFallsBackToPlaintextAndFutureSlotDoesNotFetch() async throws {
        let destination = store(encrypted: true)
        let key = CameraS3Thumbnail.key(prefix: destination.prefix, cameraID: camera, slot: slot, encrypted: true)
        let objects = ThumbnailObjects(files: [key: try encrypted(jpeg())])
        let reader = CameraS3ThumbnailReader(store: destination, cameraID: camera, password: "wrong", objects: objects)
        do { _ = try await reader.thumbnail(request()); XCTFail("Password") }
        catch { XCTAssertEqual(error as? CameraS3Decryption.Failure, .authenticationFailed) }
        let future = try await reader.thumbnail(request(timestamp: slot + 600)); XCTAssertNil(future)
        let reads = await objects.requests; XCTAssertEqual(reads.count, 1)
        var relative = request(); relative.relativeTo = "live"
        do { _ = try await reader.thumbnail(relative); XCTFail("Relative request") } catch {}
        let stillReads = await objects.requests; XCTAssertEqual(stillReads.count, 1)
    }
    func testFallbackPrefersLocalAndUsesCloudForMissErrorOrUnsupported() async throws {
        let image = CameraThumbnail(data: Data([1]), width: 1, height: 1, timestamp: slot)
        for mode in [ThumbnailLocal.Mode.image, .missing, .failure, .unsupported, .cancelled] {
            let local = ThumbnailLocal(mode: mode, image: image), remote = ThumbnailRemote(image: image)
            let fallback = CameraThumbnailFallback(local: local, remote: remote)
            do { let result = try await fallback.thumbnail(request()); XCTAssertNotNil(result); XCTAssertNotEqual(mode, .cancelled) }
            catch { XCTAssertTrue(error is CancellationError); XCTAssertEqual(mode, .cancelled) }
            let calls = await remote.calls; XCTAssertEqual(calls, mode == .image || mode == .cancelled ? 0 : 1)
            await fallback.close()
            do { _ = try await fallback.thumbnail(request()); XCTFail("Closed fallback") } catch { XCTAssertTrue(error is CancellationError) }
            let closed = await remote.closed; XCTAssertTrue(closed)
        }
    }
    func testTimelineUsesCloudPreviewAndClearsItOnClose() async throws {
        let destination = store(), current = slot + 1
        let key = CameraS3Thumbnail.key(prefix: destination.prefix, cameraID: camera, slot: slot, encrypted: false)
        let objects = ThumbnailObjects(files: [key: try jpeg()])
        let remote = CameraS3ThumbnailReader(store: destination, cameraID: camera, password: nil, objects: objects)
        let local = ThumbnailLocal(mode: .missing, image: .init(data: Data(), width: 1, height: 1, timestamp: current))
        let fallback = CameraThumbnailFallback(local: local, remote: remote)
        let model = CameraTimelineModel()
        await model.open(cameraID: camera, transport: fallback)
        defer { model.close() }
        let tile = Int(floor(slot / 1200))
        for _ in 0..<200 {
            if model.previews[tile] != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .image(let image) = model.previews[tile]?.preview else { return XCTFail("Cloud preview did not reach the timeline") }
        XCTAssertEqual(image.width, 320); XCTAssertEqual(image.height, 180)
        model.close()
        XCTAssertTrue(model.previews.isEmpty)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(model.previews.isEmpty, "Obsolete requests must not repopulate a closed timeline")
        let closed = await objects.closed; XCTAssertTrue(closed)
    }
}

private actor ThumbnailObjects: CameraS3ObjectReading {
    let files: [String: Data]
    let missing: CameraS3ReadError
    var requests: [String] = []
    var closed = false
    init(files: [String: Data], missing: CameraS3ReadError = .missing) { self.files = files; self.missing = missing }
    func read(key: String, maximumBytes: Int) throws -> Data {
        requests.append(key)
        guard let data = files[key] else { throw missing }
        guard data.count <= maximumBytes else { throw CameraS3ReadError.tooLarge }
        return data
    }
    func close() { closed = true }
}
private actor ThumbnailLocal: CameraThumbnailFetching {
    enum Mode { case image, missing, failure, unsupported, cancelled }
    let mode: Mode
    let image: CameraThumbnail
    init(mode: Mode, image: CameraThumbnail) { self.mode = mode; self.image = image }
    func start() {}
    func close() {}
    func fetch(_ request: HBNVRMediaRequest, onBegin: CameraHistoryBeginHandler?) throws -> CameraHistoryBatch {
        .init(id: UUID(), range: .init(start: image.timestamp + request.range.start, end: image.timestamp + request.range.end),
              anchor: image.timestamp, pieces: [], gaps: [])
    }
    func thumbnail(_ request: HBNVRThumbnailRequest) throws -> CameraThumbnail? {
        switch mode {
        case .image: image
        case .missing: nil
        case .failure: throw CameraHistoryError.unavailable
        case .unsupported: throw CameraThumbnailError.unsupported
        case .cancelled: throw CancellationError()
        }
    }
}
private actor ThumbnailRemote: CameraS3ThumbnailReading {
    let image: CameraThumbnail
    var calls = 0
    var closed = false
    init(image: CameraThumbnail) { self.image = image }
    func thumbnail(_ request: HBNVRThumbnailRequest) -> CameraThumbnail? { calls += 1; return image }
    func close() { closed = true }
}
