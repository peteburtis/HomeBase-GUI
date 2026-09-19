import Foundation
import HomeBaseProtocol
import ImageIO
import UniformTypeIdentifiers

nonisolated protocol CameraS3ThumbnailReading: Sendable {
    func thumbnail(_ request: HBNVRThumbnailRequest) async throws -> CameraThumbnail?
    func close() async
}

/// Fixed, UTC-aligned preview objects. No catalog/list request or video download
/// is necessary. Decryption and ImageIO work run off the main actor, in RAM.
actor CameraS3ThumbnailReader: CameraS3ThumbnailReading {
    private let store: HBCameraPlaybackMetadata.S3Store
    private let cameraID: String
    private let objects: any CameraS3ObjectReading
    private var password: String?
    private var closed = false
    init(store: HBCameraPlaybackMetadata.S3Store, cameraID: String, password: String?,
         objects: any CameraS3ObjectReading) {
        self.store = store; self.cameraID = cameraID; self.password = password; self.objects = objects
    }
    func close() async { closed = true; password = nil; await objects.close() }
    private func check() throws {
        try Task.checkCancellation()
        if closed { throw CancellationError() }
    }
    func thumbnail(_ request: HBNVRThumbnailRequest) async throws -> CameraThumbnail? {
        try request.validate(); try check()
        guard request.cameraID == cameraID, request.relativeTo == nil,
              request.timeline == nil || request.timeline == "canonical", request.timestamp >= 0 else {
            throw CameraHistoryError.invalidResponse
        }
        guard store.clientEncryptionFormat == nil || store.clientEncryptionFormat == "hbnvr-pbe-v1" else {
            throw CameraS3HistoryError.unsupported
        }
        let slot = CameraS3Thumbnail.slot(containing: request.timestamp)
        // A current, incomplete cell may ask for a point before its midpoint.
        // Don't fetch a preview from the future or turn the upload edge into Live.
        // The timeline caps requests at its NVR-resolved edge. Do not replace
        // that clock with the phone's wall clock when judging a partial cell.
        guard slot <= request.timestamp else { return nil }
        let encrypted = store.clientEncryptionFormat != nil
        var denial: Error?
        // An advertised encrypted store must never downgrade to an unauthenticated
        // plaintext preview. A currently plaintext store may still have old
        // encrypted previews, which remain protected by their original password.
        for isEncrypted in encrypted ? [true] : [false, true] {
            let key = CameraS3Thumbnail.key(prefix: store.prefix, cameraID: cameraID, slot: slot, encrypted: isEncrypted)
            let wire: Data
            do { wire = try await objects.read(key: key, maximumBytes: CameraS3Thumbnail.maximumBytes + 72) }
            catch CameraS3ReadError.missing { try check(); continue }
            catch CameraS3ReadError.accessDenied {
                // Without ListBucket S3 may return 403 for absent keys. Try the
                // allowed historical suffix too, but never call an all-403 result empty.
                try check(); denial = CameraS3ReadError.accessDenied; continue
            }
            try check()
            guard wire.count <= CameraS3Thumbnail.maximumBytes + 72 else { throw CameraHistoryError.tooLarge }
            if isEncrypted && !wire.starts(with: CameraS3Decryption.magic) { throw CameraS3Decryption.Failure.invalidEnvelope }
            let data = try CameraS3Decryption.decrypt(wire, password: password)
            let image = try CameraS3Thumbnail.decode(data, storeID: store.id, cameraID: cameraID, slot: slot, size: request.size)
            try check()
            return image
        }
        if let denial { throw denial }
        return nil
    }
}

nonisolated enum CameraS3Thumbnail {
    static let maximumBytes = 8 * 1024 * 1024
    static func slot(containing timestamp: Double) -> Double { floor(timestamp / 1200) * 1200 + 600 }
    static func key(prefix: String, cameraID: String, slot: Double, encrypted: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd/HH-mm"
        return CameraS3ManifestLayout.root(prefix: prefix, cameraID: cameraID) + "thumbnails/"
            + formatter.string(from: Date(timeIntervalSince1970: slot)) + (encrypted ? ".jpg.hbnvr" : ".jpg")
    }
    struct Caption: Codable {
        var format = "hbnvr-s3-thumbnail"
        var version = 1
        let storeID: String
        let cameraID: String
        let slot: Double
        let timestamp: Double
    }
    static func decode(_ data: Data, storeID: String, cameraID: String, slot: Double,
                       size: HBNVRThumbnailRequest.Size) throws -> CameraThumbnail {
        // ImageIO may accept truncated JPEGs as partial images even when its
        // non-incremental source reports complete. Recorder JPEGs end at EOI.
        guard data.count <= maximumBytes, data.starts(with: [0xFF, 0xD8]), data.suffix(2).elementsEqual([0xFF, 0xD9]),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, (1...1280).contains(width),
              let height = properties[kCGImagePropertyPixelHeight] as? Int, (1...720).contains(height),
              let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any],
              let text = iptc[kCGImagePropertyIPTCCaptionAbstract] as? String, text.utf8.count <= 4096,
              let caption = try? JSONDecoder().decode(Caption.self, from: Data(text.utf8)),
              caption.format == "hbnvr-s3-thumbnail", caption.version == 1,
              caption.storeID == storeID, caption.cameraID == cameraID, caption.slot == slot,
              caption.timestamp.isFinite, caption.timestamp >= 0, caption.timestamp <= slot,
              slot - caption.timestamp <= 120 else { throw CameraHistoryError.invalidResponse }
        let scale = min(1, min(Double(size.width) / Double(width), Double(size.height) / Double(height)))
        let maximum = max(1, Int(floor(Double(max(width, height)) * scale)))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary), image.width <= size.width, image.height <= size.height else { throw CameraHistoryError.invalidResponse }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CameraHistoryError.invalidResponse
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CameraHistoryError.invalidResponse }
        return .init(data: output as Data, width: image.width, height: image.height, timestamp: caption.timestamp)
    }
}

/// Availability/clock anchoring remains exclusively local. Only a missing or
/// failed thumbnail falls back; fetching never changes playback or its buffers.
actor CameraThumbnailFallback: CameraThumbnailFetching {
    private let local: any CameraThumbnailFetching
    private let remote: any CameraS3ThumbnailReading
    private var closed = false
    init(local: any CameraThumbnailFetching, remote: any CameraS3ThumbnailReading) { self.local = local; self.remote = remote }
    func start() async { await local.start() }
    func close() async { closed = true; await local.close(); await remote.close() }
    func fetch(_ request: HBNVRMediaRequest, onBegin: CameraHistoryBeginHandler?) async throws -> CameraHistoryBatch {
        try check()
        let result = try await local.fetch(request, onBegin: onBegin)
        try check(); return result
    }
    private func check() throws { try Task.checkCancellation(); if closed { throw CancellationError() } }
    func thumbnail(_ request: HBNVRThumbnailRequest) async throws -> CameraThumbnail? {
        try check()
        do {
            let result = try await local.thumbnail(request)
            try check()
            if let result { return result }
        } catch {
            try check()
            if error is CancellationError { throw error }
            // S3 previews are canonical absolute slots, not arbitrary timelines.
            guard request.relativeTo == nil, request.timeline == nil || request.timeline == "canonical" else { throw error }
        }
        guard request.relativeTo == nil, request.timeline == nil || request.timeline == "canonical" else { return nil }
        let result = try await remote.thumbnail(request)
        try check(); return result
    }
}
