import CryptoKit
import Foundation
import HomeBaseProtocol

/// One camera/session cache. All cloud requests are read-only; nothing is
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
    private struct Inventory {
        let keys: Set<String>
        let expires: Double
        let bytes: Int
    }
    private var inventories: [String: Inventory] = [:]
    private var listingDisabled = false
    private var listingRetryAt: Double = 0

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
        inventories.removeAll()
        await objects.close()
    }

    func fetch(_ request: HBNVRMediaRequest, onBegin: CameraHistoryBeginHandler?) async throws -> CameraHistoryBatch {
        try await fetch(request, excludingHidden: false, onBegin: onBegin)
    }

    func neighbors(_ request: HBNVRMediaRequest, excludingHidden: Bool) async throws -> CameraHistoryBatch {
        guard request.operation == "neighbors" else { throw CameraHistoryError.invalidResponse }
        return try await fetch(request, excludingHidden: excludingHidden, onBegin: nil)
    }

    private func fetch(_ request: HBNVRMediaRequest, excludingHidden: Bool,
                       onBegin: CameraHistoryBeginHandler?) async throws -> CameraHistoryBatch {
        try request.validate(); try check()
        guard request.cameraID == cameraID, request.relativeTo == nil,
              request.timeline == nil || request.timeline == "canonical",
              request.operation == "neighbors" || request.range.end - request.range.start <= 120.001 else {
            throw CameraHistoryError.invalidResponse
        }
        let range = CameraHistoryRange(start: request.range.start, end: request.range.end)
        await onBegin?(range, nil)
        let catalog = try await catalog()
        try check()
        if request.operation == "neighbors" {
            if excludingHidden { return try await visibleNeighbors(range, catalog: catalog) }
            return try await neighbors(range, catalog: catalog)
        }
        let indexed = try await entries(days: catalog.days.filter { $0.range.intersection(range) != nil }, catalog: catalog)
            .filter { $0.range.intersection(range) != nil }
        let shards = try await existing(indexed)
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
                let wire: Data
                do { wire = try await objects.read(key: shard.key, maximumBytes: Int(shard.size)) }
                catch {
                    try check()
                    // A listing can race lifecycle deletion. Refresh once, and
                    // turn only confirmed absence into a gap. GET-only readers
                    // and genuine access/network failures keep their old error.
                    if let failure = error as? CameraS3ReadError, failure == .missing || failure == .accessDenied,
                       let keys = try await listedKeys(prefix: mediaPrefix(shard, monthly: false), refresh: true),
                       !keys.contains(shard.key) {
                        invalidateInventories(containing: [shard.key], except: mediaPrefix(shard, monthly: false))
                        continue
                    }
                    throw error
                }
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
            let tags = try shard.tagMetadata?.thaw(password: password)
            var decoded = try await decode(data, shard, range)
            for piece in decoded.indices {
                for sample in decoded[piece].samples.indices {
                    let value = decoded[piece].samples[sample]
                    decoded[piece].samples[sample].isHidden = tags?.hidden(ticks: value.frame.presentationTicks, frame: value.sourceFrame) ?? false
                }
            }
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

    /// A thumbnail's JPEG is immutable; historical edits live in its manifest.
    /// Nil means a legacy shard has no tag timeline, so its caption is usable.
    func hidden(at timestamp: Double) async throws -> Bool? {
        try check()
        let catalog = try await catalog()
        let shards = try await entries(days: catalog.days.filter { $0.range.contains(timestamp) }, catalog: catalog)
        guard let shard = shards.first(where: { $0.range.contains(timestamp) }) else { return nil }
        let ticks = Int64(((timestamp - shard.timing.time.canonicalUTC) * Double(shard.timing.timescale)).rounded())
        let tags = try shard.tagMetadata?.thaw(password: password)
        try check()
        return tags?.hidden(ticks: ticks, frame: nil)
    }

    private func check() throws {
        try Task.checkCancellation()
        if closed { throw CancellationError() }
    }

    /// Only a complete, validated listing proves absence. Partial, denied,
    /// oversized and failed inventories fall back to ordinary manifest/GET
    /// playback. Denial is remembered for this session, not saved credentials.
    private func listedKeys(prefix: String, refresh: Bool = false) async throws -> Set<String>? {
        try check()
        guard !listingDisabled else { return nil }
        if refresh { inventories[prefix] = nil }
        if let cached = inventories[prefix], now() < cached.expires { return cached.keys }
        guard now() >= listingRetryAt else { return nil }
        inventories[prefix] = nil
        do {
            var keys: Set<String> = [], tokens: Set<String> = []
            var token: String?, bytes = 0
            // 100 pages/100,000 keys/8 MiB per inventory; never retain a partial
            // snapshot or let optional listing grow without bound.
            for _ in 0..<100 {
                guard let page = try await objects.list(prefix: prefix, continuationToken: token) else {
                    listingDisabled = true; inventories.removeAll(); return nil
                }
                try check()
                guard page.keys.count <= 1000 else { throw CameraS3ReadError.tooLarge }
                for key in page.keys {
                    try CameraS3ReadScope.validate(key: key, prefix: prefix)
                    if keys.insert(key).inserted { bytes += key.utf8.count }
                }
                guard bytes <= 8 * 1024 * 1024, keys.count <= 100_000 else { throw CameraS3ReadError.tooLarge }
                if let next = page.next {
                    guard !next.isEmpty, next.utf8.count <= 16384, tokens.insert(next).inserted else {
                        throw CameraS3ReadError.network
                    }
                    token = next
                } else {
                    // Daily/recent results can change quickly as uploads finish.
                    let recent = prefix.contains(CameraS3ManifestLayout.day(now()))
                        || prefix.hasSuffix(CameraS3ManifestLayout.month(now()))
                        || prefix.hasSuffix("/days/") || prefix.hasSuffix("/months/")
                    inventories[prefix] = Inventory(keys: keys, expires: now() + (recent ? 5 : 60), bytes: bytes)
                    while inventories.count > 8 || inventories.values.reduce(0, { $0 + $1.bytes }) > 16 * 1024 * 1024 {
                        guard let oldest = inventories.min(by: { $0.value.expires < $1.value.expires })?.key else { break }
                        inventories[oldest] = nil
                    }
                    return keys
                }
            }
            throw CameraS3ReadError.tooLarge
        } catch {
            try check()
            if error is CancellationError { throw error }
            if (error as? CameraS3ReadError) == .accessDenied {
                listingDisabled = true; inventories.removeAll()
            } else { listingRetryAt = now() + 5 }
            return nil
        }
    }

    private func mediaPrefix(_ shard: CameraS3ManifestShard, monthly: Bool) -> String {
        let parent = shard.key.lastIndex(of: "/").map { String(shard.key[...$0]) } ?? ""
        let leaf = String(shard.key.dropFirst(parent.count))
        // Use the recorder's filename only to narrow membership queries. Exact
        // timing still comes exclusively from the manifest, including clock
        // corrections and shards crossing day/month boundaries. Other layouts
        // remain supported through their containing prefix.
        if leaf.count > 10, CameraS3ManifestLayout.validDay(String(leaf.prefix(10))),
           leaf.dropFirst(10).first == "T" {
            return parent + leaf.prefix(monthly ? 7 : 10)
        }
        return parent
    }

    private func existing(_ shards: [CameraS3ManifestShard], monthly: Bool = false) async throws -> [CameraS3ManifestShard] {
        var result: [CameraS3ManifestShard] = []
        let groups = Dictionary(grouping: shards, by: { mediaPrefix($0, monthly: monthly) })
        for prefix in groups.keys.sorted() {
            let keys = try await listedKeys(prefix: prefix)
            if let keys {
                let absent = Set(groups[prefix]!.map(\.key)).subtracting(keys)
                invalidateInventories(containing: absent, except: prefix)
            }
            result += groups[prefix]!.filter { keys?.contains($0.key) ?? true }
        }
        return result.sorted { ($0.range.start, $0.id) < ($1.range.start, $1.id) }
    }

    private func invalidateInventories(containing absent: Set<String>, except prefix: String) {
        inventories = inventories.filter { $0.key == prefix || $0.value.keys.isDisjoint(with: absent) }
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
            let indexPrefix = CameraS3ManifestLayout.root(prefix: store.prefix, cameraID: cameraID)
                + (daily ? "days/" : "months/")
            if let keys = try await listedKeys(prefix: indexPrefix), !keys.contains(key) { continue }
            let manifest: CameraS3Manifest
            if let cache = manifestCache, cache.key == key, now() < cache.expires {
                manifest = cache.value
            } else {
                let data: Data
                do { data = try await json(key, maximum: 64 * 1024 * 1024) }
                catch {
                    try check()
                    if let failure = error as? CameraS3ReadError, failure == .missing || failure == .accessDenied,
                       let keys = try await listedKeys(prefix: indexPrefix, refresh: true), !keys.contains(key) { continue }
                    throw error
                }
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

    private struct NavigationShard {
        let id: String
        let range: CameraHistoryRange
        let timescale: UInt32
        let endTicks: Int64
        let tags: CameraStoredVideoTags?
    }

    private func visibleNeighbors(_ range: CameraHistoryRange, catalog: CameraS3Catalog) async throws -> CameraHistoryBatch {
        let today = CameraS3ManifestLayout.day(now())
        let publishedDay = CameraS3ManifestLayout.day(catalog.generatedAt)
        let periods = Dictionary(grouping: catalog.days) { day in
            day.day == today || day.day == publishedDay ? day.day : String(day.day.prefix(7))
        }.map { period, days in
            (id: period, days: days, bounds: CameraHistoryRange(start: days.map(\.start).min()!, end: days.map(\.end).max()!))
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var loaded: Set<String> = [], shards: [NavigationShard] = []
        var identities: [String: SHA256.Digest] = [:]
        var visibleCache: [String: [CameraHistoryRange]] = [:]
        var intervalCount = 0, metadataBytes = 0
        func checkSearch() throws {
            try check()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CameraHistoryError.remote(nil, "Timed out finding available S3 video.")
            }
        }
        func nearest(previous: Bool) throws -> CameraHistoryRange? {
            var coveredEnd = -Double.infinity
            var selectable: [(shard: NavigationShard, start: Double)] = []
            // Match the reader's source order: an earlier shard owns overlaps,
            // including its hidden spans. Later public copies cannot unveil it.
            for shard in shards.sorted(by: { ($0.range.start, $0.id) < ($1.range.start, $1.id) }) {
                let selectableStart = max(shard.range.start, coveredEnd)
                coveredEnd = max(coveredEnd, shard.range.end)
                if selectableStart < shard.range.end, previous ? selectableStart < range.start : shard.range.end > range.end {
                    selectable.append((shard, selectableStart))
                }
            }
            let ordered = selectable.sorted {
                previous ? min($0.shard.range.end, range.start) > min($1.shard.range.end, range.start)
                    : max($0.start, range.end) < max($1.start, range.end)
            }
            var best: CameraHistoryRange?
            for value in ordered {
                try checkSearch()
                let shard = value.shard
                let bound = previous ? min(shard.range.end, range.start) : max(value.start, range.end)
                if let best, previous ? bound <= best.end : bound >= best.start { break }
                let visible: [CameraHistoryRange]
                if let cached = visibleCache[shard.id] { visible = cached }
                else {
                    let tags = try shard.tags?.thaw(password: password)
                    visible = tags?.approximateVisibleRanges(endTicks: shard.endTicks).map { ticks in
                        CameraHistoryRange(start: shard.range.start + Double(ticks.lowerBound) / Double(shard.timescale),
                            end: shard.range.start + Double(ticks.upperBound) / Double(shard.timescale))
                    } ?? [shard.range]
                    intervalCount += visible.count
                    guard intervalCount <= 100_000 else { throw CameraHistoryError.tooLarge }
                    visibleCache[shard.id] = visible
                }
                for span in visible {
                    let start = max(span.start, value.start, previous ? span.start : range.end)
                    let end = min(span.end, previous ? range.start : span.end)
                    guard start < end else { continue }
                    let candidate = CameraHistoryRange(start: start, end: end)
                    if previous ? end > (best?.end ?? -.infinity) : start < (best?.start ?? .infinity) { best = candidate }
                }
            }
            return best
        }
        for backward in [true, false] {
            let ordered = periods.filter { backward ? $0.bounds.start < range.start : $0.bounds.end > range.end }
                .sorted { backward ? $0.bounds.end > $1.bounds.end : $0.bounds.start < $1.bounds.start }
            var best = try nearest(previous: backward)
            for period in ordered {
                try checkSearch()
                // Include all periods that can overlap the returned interval so
                // source precedence is resolved before publishing a destination.
                if let best, backward ? period.bounds.end <= best.start : period.bounds.start >= best.end { break }
                guard loaded.insert(period.id).inserted else { continue }
                let indexed = try await entries(days: period.days, catalog: catalog)
                let existing = try await existing(indexed, monthly: true)
                try checkSearch()
                for shard in existing {
                    let encoded = try encoder.encode(shard), identity = SHA256.hash(data: encoded)
                    if let previous = identities[shard.id] {
                        guard previous == identity else { throw CameraS3HistoryError.invalidManifest }
                        continue
                    }
                    guard shards.count < 100_000 else { throw CameraHistoryError.tooLarge }
                    metadataBytes += encoded.count
                    guard metadataBytes <= 64 * 1024 * 1024 else { throw CameraHistoryError.tooLarge }
                    identities[shard.id] = identity
                    shards.append(.init(id: shard.id, range: shard.range, timescale: shard.timing.timescale,
                        endTicks: shard.endTicks, tags: shard.tagMetadata))
                    try checkSearch()
                }
                best = try nearest(previous: backward)
            }
        }
        // The second direction can load an overlapping earlier source.
        let previous = try nearest(previous: true), next = try nearest(previous: false)
        return .init(id: UUID(), range: range, anchor: nil, pieces: [], gaps: [], neighbors: .init(previous: previous, next: next))
    }
    private func neighbors(_ range: CameraHistoryRange, catalog: CameraS3Catalog) async throws -> CameraHistoryBatch {
        // Catalog bounds narrow the search; exact neighbors come from entries,
        // never a day's bounding interval (which may include recording gaps).
        var previous: CameraHistoryRange?, next: CameraHistoryRange?
        for day in catalog.days.filter({ $0.start < range.start }).sorted(by: { $0.day > $1.day }) {
            let indexed = try await entries(days: [day], catalog: catalog).filter { $0.range.end <= range.start }
            let values = try await existing(indexed, monthly: true).map(\.range)
            try check()
            if let found = values.max(by: { $0.end < $1.end }) { previous = found; break }
        }
        for day in catalog.days.filter({ $0.end > range.end }).sorted(by: { $0.day < $1.day }) {
            let indexed = try await entries(days: [day], catalog: catalog).filter { $0.range.start >= range.end }
            let values = try await existing(indexed, monthly: true).map(\.range)
            try check()
            if let found = values.min(by: { $0.start < $1.start }) { next = found; break }
        }
        return .init(id: UUID(), range: range, anchor: nil, pieces: [], gaps: [],
                     neighbors: .init(previous: previous, next: next))
    }
}
