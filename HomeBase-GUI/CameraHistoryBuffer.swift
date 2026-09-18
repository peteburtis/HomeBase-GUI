import Foundation

/// Compressed, request-scoped media only. Segment numbers are not global frame
/// identities; each response gets independent decoder epochs and preroll.
nonisolated struct CameraHistoryBuffer {
    struct Stored { let batch: CameraHistoryBatch; let received: Double }
    struct Location {
        let piece: CameraHistoryPiece
        let index: Int
    }
    private(set) var batches: [Stored] = []
    let maximumBytes: Int
    let maximumDuration: Double
    let maximumFrames: Int
    init(maximumBytes: Int = 64 * 1024 * 1024, maximumDuration: Double = 300, maximumFrames: Int = 30_000) {
        self.maximumBytes = maximumBytes; self.maximumDuration = maximumDuration; self.maximumFrames = maximumFrames
    }
    var bytes: Int { batches.reduce(0) { $0 + $1.batch.bytes } }
    var frameCount: Int { batches.reduce(0) { $0 + $1.batch.frameCount } }

    mutating func insert(_ batch: CameraHistoryBatch, at now: Double, around cursor: Double) {
        // Replacement coverage supersedes an older response only when it covers
        // that entire response. Partial overlaps retain each source's decoder GOP.
        batches.removeAll { batch.range.start <= $0.batch.range.start && batch.range.end >= $0.batch.range.end }
        batches.append(Stored(batch: batch, received: now))
        trim(around: cursor)
    }
    mutating func trim(around cursor: Double) {
        func distance(_ value: Stored) -> Double {
            if value.batch.range.contains(cursor) { return 0 }
            return min(abs(value.batch.range.start - cursor), abs(value.batch.range.end - cursor))
        }
        while !batches.isEmpty {
            let start = batches.map(\.batch.range.start).min()!, end = batches.map(\.batch.range.end).max()!
            guard bytes > maximumBytes || frameCount > maximumFrames || end - start > maximumDuration || batches.count > 64 else { break }
            let index = batches.indices.max { distance(batches[$0]) < distance(batches[$1]) }!
            batches.remove(at: index)
        }
    }
    mutating func removeAll() { batches.removeAll() }

    /// Near-edge gaps are provisional: a file fragment can become readable on
    /// the next flush. Older gaps are also revisited, but less aggressively.
    func knowledge(now: Double, liveEdge: Double) -> [CameraHistoryRange] {
        CameraHistoryRange.merged(batches.flatMap { value in
            let expired = value.batch.gaps.filter { gap in
                now - value.received >= (gap.end >= liveEdge - 60 ? 5 : 60)
            }
            return value.batch.range.subtracting(expired)
        })
    }
    func missing(_ range: CameraHistoryRange, now: Double, liveEdge: Double) -> [CameraHistoryRange] {
        range.subtracting(knowledge(now: now, liveEdge: liveEdge))
    }
    func knownEnd(from position: Double, now: Double, liveEdge: Double) -> Double {
        knowledge(now: now, liveEdge: liveEdge).first { $0.contains(position) }?.end ?? position
    }
    func isKnown(_ position: Double, now: Double, liveEdge: Double) -> Bool {
        knowledge(now: now, liveEdge: liveEdge).contains { $0.contains(position) }
    }
    func location(at position: Double, preferredPiece: UUID? = nil) -> Location? {
        var candidates: [Location] = []
        for value in batches.reversed() where value.batch.range.contains(position) {
            guard !value.batch.gaps.contains(where: { $0.contains(position) }) else { continue }
            for piece in value.batch.pieces where piece.segment.range.contains(position) {
                guard let index = piece.samples.lastIndex(where: { $0.time(in: piece.segment) <= position + 0.000_001 }),
                      piece.samples[index].end(in: piece.segment) > position - 0.000_001 else { continue }
                let location = Location(piece: piece, index: index)
                if piece.id == preferredPiece { return location }
                candidates.append(location)
            }
        }
        return candidates.first
    }
}

nonisolated enum CameraHistoryPolicy {
    static func initialWindow(at position: Double, liveEdge: Double) -> CameraHistoryRange {
        CameraHistoryRange(start: position - 30, end: min(liveEdge, position + 30))
    }
    static func refill(at position: Double, knownEnd: Double, liveEdge: Double,
                       speed: CameraPlaybackSpeed = .normal) -> CameraHistoryRange? {
        // Preserve roughly 20/30 seconds of real viewing runway at each speed.
        // The transport still splits goals into bounded, sequential requests.
        guard knownEnd - position < 20 * speed.multiplier, knownEnd < liveEdge - 0.001 else { return nil }
        return CameraHistoryRange(start: knownEnd, end: min(liveEdge, knownEnd + 30 * speed.multiplier))
    }
}
