import CryptoKit
import Foundation
import HomeBaseProtocol

/// One camera/session cache. All cloud requests are GETs; nothing is enumerated,
/// decrypted to disk, or sent back through Homebase. Close drops keys and caches.
actor CameraS3HistoryReader: CameraHistoryFetching {
    typealias Decode = @Sendable (Data, CameraS3ManifestShard, CameraHistoryRange) async throws -> [CameraHistoryPiece]
    private let store: HBCameraPlaybackMetadata.S3Store
    private let cameraID: String
    private var password: String?
    private let objects: any CameraS3ObjectReading
    private let decode: Decode
    private let now: @Sendable () -> Double
    private var closed = false
    private var catalogCache: (CameraS3Catalog, Double)?
    private var manifestCache: (key: String, value: CameraS3Manifest, expires: Double)?
    private var mediaCache: (key: String, hash: String, data: Data)?

    init(store: HBCameraPlaybackMetadata.S3Store, cameraID: String, password: String?,
         objects: any CameraS3ObjectReading,
         now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
         decode: @escaping Decode = { try await CameraS3MediaDecoder.decode(data: $0, expected: $1, range: $2) }) {
        self.store = store; self.cameraID = cameraID; self.password = password
        self.objects = objects; self.now = now; self.decode = decode
    }
    func start() {} // No AWS reads until a local miss actually needs fallback.
    func close() async {
        closed = true; password = nil; catalogCache = nil; manifestCache = nil; mediaCache = nil
        await objects.close()
    }

    func fetch(_ request: HBNVRMediaRequest, onBegin: CameraHistoryBeginHandler?) async throws -> CameraHistoryBatch {
        try request.validate(); try check()
        guard request.cameraID == cameraID, request.relativeTo == nil,
              request.timeline == nil || request.timeline == "canonical",
              request.range.end - request.range.start <= 120.001 else { throw CameraHistoryError.invalidResponse }
        let range = CameraHistoryRange(start: request.range.start, end: request.range.end)
        await onBegin?(range, nil)
        let catalog = try await catalog()
        try check()
        if request.operation == "neighbors" {
            return try await neighbors(range, catalog: catalog)
        }
        let shards = try await entries(days: catalog.days.filter { $0.range.intersection(range) != nil }, catalog: catalog)
            .filter { $0.range.intersection(range) != nil }
        try check()
        if request.operation == "availability" {
            return .init(id: UUID(), range: range, anchor: nil, pieces: [],
                gaps: range.subtracting(shards.map(\.range)))
        }
        var pieces: [CameraHistoryPiece] = []
        var bytes = 0, frames = 0
        for shard in shards {
            try check()
            guard shard.size <= 256 * 1024 * 1024 else { throw CameraHistoryError.tooLarge }
            let data: Data
            if let cache = mediaCache, cache.key == shard.key, cache.hash == shard.sha256 { data = cache.data }
            else {
                let wire = try await objects.read(key: shard.key, maximumBytes: Int(shard.size))
                try check()
                guard wire.count == shard.size,
                      SHA256.hash(data: wire).map({ String(format: "%02x", $0) }).joined() == shard.sha256.lowercased() else {
                    throw CameraS3HistoryError.hashMismatch
                }
                guard shard.encryption != "hbnvr-pbe-v1" || wire.starts(with: CameraS3Decryption.magic) else {
                    throw CameraS3Decryption.Failure.invalidEnvelope
                }
                data = try CameraS3Decryption.decrypt(wire, password: password)
                // The existing history buffer retains samples. Cache only one
                // small shard to avoid re-downloading it across 30s refills.
                mediaCache = data.count <= 16 * 1024 * 1024 ? (shard.key, shard.sha256, data) : nil
            }
            let decoded = try await decode(data, shard, range)
            try check()
            bytes += decoded.reduce(0) { $0 + $1.samples.reduce(0) { $0 + $1.data.count } }
            frames += decoded.reduce(0) { $0 + $1.samples.count }
            guard bytes <= 64 * 1024 * 1024, frames <= 30_000 else { throw CameraHistoryError.tooLarge }
            pieces += decoded
        }
        let coverage = pieces.flatMap { piece in
            piece.samples.compactMap { sample in
                CameraHistoryRange(start: sample.time(in: piece.segment), end: sample.end(in: piece.segment)).intersection(range)
            }
        }
        return .init(id: UUID(), range: range, anchor: nil, pieces: pieces, gaps: range.subtracting(coverage))
    }

    private func check() throws {
        try Task.checkCancellation()
        if closed { throw CancellationError() }
    }
    private func validIdentity(format: String, schema: Int, storeID: String, cameraID: String, generated: Double) -> Bool {
        format == "hbnvr-s3-playback" && schema == 1 && storeID == store.id && cameraID == self.cameraID
            && generated.isFinite && generated >= 0 && generated < 253_402_300_799
    }
    private func json(_ key: String, maximum: Int) async throws -> Data {
        let wire = try await objects.read(key: key, maximumBytes: maximum)
        try check()
        guard store.clientEncryptionFormat == nil || store.clientEncryptionFormat == "hbnvr-pbe-v1" else {
            throw CameraS3HistoryError.unsupported
        }
        guard store.clientEncryptionFormat != "hbnvr-pbe-v1" || wire.starts(with: CameraS3Decryption.magic) else {
            throw CameraS3Decryption.Failure.invalidEnvelope
        }
        return try CameraS3Decryption.decrypt(wire, password: password)
    }
    private func catalog() async throws -> CameraS3Catalog {
        if let (catalog, expiry) = catalogCache, now() < expiry { return catalog }
        let key = CameraS3ManifestLayout.root(prefix: store.prefix, cameraID: cameraID) + "catalog.json"
        let data = try await json(key, maximum: 4 * 1024 * 1024)
        try check()
        let value: CameraS3Catalog
        do { value = try JSONDecoder().decode(CameraS3Catalog.self, from: data) }
        catch { throw CameraS3HistoryError.invalidManifest }
        guard validIdentity(format: value.format, schema: value.schemaVersion, storeID: value.storeID,
                            cameraID: value.cameraID, generated: value.generatedAt), value.days.count <= 36_625,
              Set(value.days.map(\.day)).count == value.days.count,
              value.days.allSatisfy({ CameraS3ManifestLayout.validDay($0.day) && $0.range.isValid }) else {
            throw CameraS3HistoryError.invalidManifest
        }
        catalogCache = (value, now() + 5)
        return value
    }
    private func entries(days: [CameraS3Catalog.Day], catalog: CameraS3Catalog) async throws -> [CameraS3ManifestShard] {
        let today = CameraS3ManifestLayout.day(now())
        var result: [String: CameraS3ManifestShard] = [:]
        var loaded: Set<String> = []
        for day in days.sorted(by: { $0.day < $1.day }) {
            // At UTC rollover the last published catalog may still describe
            // yesterday as its open daily. It remains valid until closeout.
            let daily = day.day == today || day.day == CameraS3ManifestLayout.day(catalog.generatedAt)
            let period = daily ? day.day : String(day.day.prefix(7))
            let key = CameraS3ManifestLayout.root(prefix: store.prefix, cameraID: cameraID)
                + (daily ? "days/" : "months/") + period + ".json"
            guard loaded.insert(key).inserted else { continue }
            let manifest: CameraS3Manifest
            if let cache = manifestCache, cache.key == key, now() < cache.expires {
                manifest = cache.value
            } else {
                let data = try await json(key, maximum: 64 * 1024 * 1024)
                try check()
                do { manifest = try JSONDecoder().decode(CameraS3Manifest.self, from: data) }
                catch { throw CameraS3HistoryError.invalidManifest }
                guard validIdentity(format: manifest.format, schema: manifest.schemaVersion, storeID: manifest.storeID,
                    cameraID: manifest.cameraID, generated: manifest.generatedAt), manifest.period == period,
                    manifest.shards.count <= 100_000 else { throw CameraS3HistoryError.invalidManifest }
                for entry in manifest.shards { try entry.validate(store: store, cameraID: cameraID) }
                manifestCache = (key, manifest, now() + (daily ? 5 : 60))
            }
            for shard in manifest.shards {
                if let previous = result[shard.id], previous != shard { throw CameraS3HistoryError.invalidManifest }
                result[shard.id] = shard
            }
        }
        return result.values.sorted { ($0.range.start, $0.id) < ($1.range.start, $1.id) }
    }
    private func neighbors(_ range: CameraHistoryRange, catalog: CameraS3Catalog) async throws -> CameraHistoryBatch {
        // Catalog bounds narrow the search; exact neighbors come from entries,
        // never a day's bounding interval (which may include recording gaps).
        var previous: CameraHistoryRange?, next: CameraHistoryRange?
        for day in catalog.days.filter({ $0.start < range.start }).sorted(by: { $0.day > $1.day }) {
            let values = try await entries(days: [day], catalog: catalog).map(\.range).filter { $0.end <= range.start }
            try check()
            if let found = values.max(by: { $0.end < $1.end }) { previous = found; break }
        }
        for day in catalog.days.filter({ $0.end > range.end }).sorted(by: { $0.day < $1.day }) {
            let values = try await entries(days: [day], catalog: catalog).map(\.range).filter { $0.start >= range.end }
            try check()
            if let found = values.min(by: { $0.start < $1.start }) { next = found; break }
        }
        return .init(id: UUID(), range: range, anchor: nil, pieces: [], gaps: [],
                     neighbors: .init(previous: previous, next: next))
    }
}
