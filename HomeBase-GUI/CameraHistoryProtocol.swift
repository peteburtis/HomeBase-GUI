import Foundation
import HomeBaseProtocol

nonisolated struct CameraHistoryRange: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
    var isValid: Bool { start.isFinite && end.isFinite && start < end && abs(start) < 1e11 && abs(end) < 1e11 }
    var duration: Double { end - start }
    func contains(_ time: Double) -> Bool { time >= start && time < end }
    func intersection(_ other: Self) -> Self? {
        let value = Self(start: max(start, other.start), end: min(end, other.end))
        return value.end > value.start ? value : nil
    }
    static func merged(_ ranges: [Self]) -> [Self] {
        var result: [Self] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) where range.isValid {
            if let last = result.last, range.start <= last.end + 0.000_001 {
                result[result.count - 1] = Self(start: last.start, end: max(last.end, range.end))
            } else { result.append(range) }
        }
        return result
    }
    func subtracting(_ ranges: [Self]) -> [Self] {
        var result: [Self] = [], cursor = start
        for range in Self.merged(ranges) where range.end > cursor && range.start < end {
            if range.start > cursor { result.append(Self(start: cursor, end: min(end, range.start))) }
            cursor = max(cursor, range.end)
        }
        if cursor < end - 0.000_001 { result.append(Self(start: cursor, end: end)) }
        return result
    }
}

nonisolated struct CameraHistorySegment: Codable, Equatable, Sendable {
    struct Time: Codable, Equatable, Sendable {
        let canonicalUTC: Double
        let receivedUTC: Double
        let cameraUTC: Double?
        let canonicalSource: String
        let epochID: String
    }
    let number: Int
    let range: CameraHistoryRange
    let time: Time
    let timescale: UInt32
    let codec: String
    let parameterSets: [Data]
    let nalUnitLengthBytes: Int

    func validate() throws {
        guard number >= 0, range.isValid, timescale > 0, timescale <= Int32.max,
              ["H264", "H265"].contains(codec), [1, 2, 4].contains(nalUnitLengthBytes),
              parameterSets.count == (codec == "H264" ? 2 : 3),
              parameterSets.allSatisfy({ !$0.isEmpty && $0.count <= 65_536 }),
              time.canonicalUTC.isFinite, abs(time.canonicalUTC) < 1e11,
              time.receivedUTC.isFinite, abs(time.receivedUTC) < 1e11,
              time.cameraUTC.map({ $0.isFinite && abs($0) < 1e11 }) ?? true,
              ["camera", "received"].contains(time.canonicalSource),
              !time.epochID.isEmpty, time.epochID.utf8.count <= 128 else {
            throw CameraHistoryError.invalidResponse
        }
    }
}

nonisolated struct CameraHistoryFrame: Codable, Equatable, Sendable {
    let segment: Int
    let presentationTicks: Int64
    let decodeTicks: Int64?
    let durationTicks: Int64
    let keyFrame: Bool
    let preroll: Bool
    let byteCount: Int
}

nonisolated struct CameraHistorySample: Sendable {
    let frame: CameraHistoryFrame
    let data: Data
    func time(in segment: CameraHistorySegment) -> Double {
        segment.time.canonicalUTC + Double(frame.presentationTicks) / Double(segment.timescale)
    }
    func end(in segment: CameraHistorySegment) -> Double {
        time(in: segment) + Double(frame.durationTicks) / Double(segment.timescale)
    }
}

nonisolated struct CameraHistoryPiece: Sendable {
    let id: UUID
    let segment: CameraHistorySegment
    var samples: [CameraHistorySample]
}

nonisolated struct CameraHistoryBatch: Sendable {
    let id: UUID
    let range: CameraHistoryRange
    let anchor: Double?
    let pieces: [CameraHistoryPiece]
    let gaps: [CameraHistoryRange]
    var neighbors: CameraHistoryNeighbors? = nil
    /// Failed fallback is unknown coverage, not a confirmed recording gap.
    var unresolved: [CameraHistoryRange] = []
    var sourceWarning: String? = nil
    var bytes: Int { pieces.reduce(0) { $0 + $1.samples.reduce(0) { $0 + $1.data.count } } }
    var frameCount: Int { pieces.reduce(0) { $0 + $1.samples.count } }
}

nonisolated struct CameraHistoryNeighbors: Codable, Equatable, Sendable {
    let previous: CameraHistoryRange?
    let next: CameraHistoryRange?
}

nonisolated enum CameraHistoryNavigationState: Equatable {
    case idle, loading, ready(CameraHistoryNeighbors), failed(String), unsupported
}

nonisolated enum CameraHistoryError: LocalizedError, Equatable {
    case invalidResponse
    case tooLarge
    case unavailable
    case neighborsUnsupported
    case remote(Int?, String)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The NVR returned an invalid or incomplete media response."
        case .tooLarge: "This history request exceeds the playback memory limit."
        case .unavailable: "NVR history is currently unavailable."
        case .neighborsUnsupported: "Update HBNVR and Homebase to find adjacent recordings."
        case .remote(_, let message): message
        }
    }
}

/// Preserve the server's resolved time even when a rotating shard interrupts a
/// response. Retrying must not re-anchor a relative seek to a later instant.
nonisolated struct CameraHistoryFetchFailure: LocalizedError {
    let underlying: Error
    let range: CameraHistoryRange
    let anchor: Double?
    var errorDescription: String? { underlying.localizedDescription }
}

/// A bounded, strict text/binary parser. A batch is usable only after a normal
/// End record; EOF, a partial sample, and request errors never imply coverage.
nonisolated struct CameraHistoryResponseParser {
    private struct Record: Decodable {
        let type: String
        let requestID: String
        let cameraID: String?
        let timeline: String?
        let range: CameraHistoryRange?
        let anchor: Double?
        let segment: CameraHistorySegment?
        let frame: CameraHistoryFrame?
        let outcome: String?
        let frames: Int?
        let code: Int?
        let error: String?
        let neighbors: CameraHistoryNeighbors?
    }
    let request: HBNVRMediaRequest
    let maximumBytes: Int
    private(set) var result: CameraHistoryBatch?
    private(set) var range: CameraHistoryRange?
    private(set) var anchor: Double?
    private var pieces: [CameraHistoryPiece] = []
    private var gaps: [CameraHistoryRange] = []
    private var available: [CameraHistoryRange] = []
    private var neighbors: CameraHistoryNeighbors?
    private var pending: CameraHistoryFrame?
    private var payload = Data()
    private var receivedBytes = 0
    private var frameCount = 0
    private var recordCount = 0

    init(request: HBNVRMediaRequest, maximumBytes: Int = 64 * 1024 * 1024) {
        self.request = request
        self.maximumBytes = maximumBytes
    }

    mutating func text(_ data: Data) throws {
        guard result == nil, pending == nil, data.count <= 65_536, recordCount < 65_536 else {
            throw CameraHistoryError.invalidResponse
        }
        recordCount += 1
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.requestID == request.requestID else { throw CameraHistoryError.invalidResponse }
        if record.type == "end", record.outcome == "error" {
            throw CameraHistoryError.remote(record.code, String((record.error ?? "NVR history retrieval failed.").prefix(512)))
        }
        switch record.type {
        case "begin":
            guard range == nil, record.cameraID == request.cameraID,
                  record.timeline == "canonical", let resolved = record.range, resolved.isValid,
                  resolved.duration <= 120.001 else { throw CameraHistoryError.invalidResponse }
            let expectedAnchor = request.relativeTo == nil ? 0 : record.anchor
            guard let expectedAnchor, expectedAnchor.isFinite,
                  abs(resolved.start - (request.range.start + expectedAnchor)) < 0.001,
                  abs(resolved.end - (request.range.end + expectedAnchor)) < 0.001 else {
                throw CameraHistoryError.invalidResponse
            }
            range = resolved
            anchor = record.anchor
        case "segment":
            guard request.operation == "frames", range != nil, let segment = record.segment, pieces.count < 1024,
                  !pieces.contains(where: { $0.segment.number == segment.number }) else {
                throw CameraHistoryError.invalidResponse
            }
            try segment.validate()
            pieces.append(CameraHistoryPiece(id: UUID(), segment: segment, samples: []))
        case "frame":
            guard request.operation == "frames", range != nil, let frame = record.frame, let piece = pieces.last,
                  frame.segment == piece.segment.number, frame.byteCount > 0,
                  frame.byteCount <= 8 * 1024 * 1024, frame.durationTicks > 0,
                  frame.decodeTicks.map({ $0 <= frame.presentationTicks }) ?? true,
                  piece.samples.last.map({ frame.presentationTicks >= $0.frame.presentationTicks }) ?? frame.keyFrame else {
                throw CameraHistoryError.invalidResponse
            }
            guard receivedBytes + frame.byteCount <= maximumBytes, frameCount < 30_000 else {
                throw CameraHistoryError.tooLarge
            }
            let time = piece.segment.time.canonicalUTC + Double(frame.presentationTicks) / Double(piece.segment.timescale)
            guard time.isFinite, abs(time) < 1e11,
                  time >= piece.segment.range.start - 0.001,
                  time < piece.segment.range.end + 0.001,
                  Double(frame.durationTicks) / Double(piece.segment.timescale) <= 86_400 else {
                throw CameraHistoryError.invalidResponse
            }
            pending = frame
            payload = Data()
            payload.reserveCapacity(frame.byteCount)
        case "available":
            guard request.operation == "availability", let range, let interval = record.range,
                  interval.isValid, available.count < 10_000,
                  interval.start >= range.start - 0.001, interval.end <= range.end + 0.001 else {
                throw CameraHistoryError.invalidResponse
            }
            available.append(interval)
        case "gap":
            guard request.operation != "neighbors", let range, let gap = record.range, gap.isValid, gaps.count < 10_000,
                  gap.start >= range.start - 0.001, gap.end <= range.end + 0.001 else {
                throw CameraHistoryError.invalidResponse
            }
            gaps.append(gap)
        case "neighbors":
            guard request.operation == "neighbors", neighbors == nil, let range, let value = record.neighbors,
                  value.previous.map({ $0.isValid && $0.end <= range.start }) ?? true,
                  value.next.map({ $0.isValid && $0.start >= range.end }) ?? true else {
                throw CameraHistoryError.invalidResponse
            }
            neighbors = value
        case "end":
            if request.operation == "neighbors" {
                guard let range, let neighbors, record.outcome == "complete", record.frames == 0 else {
                    throw CameraHistoryError.invalidResponse
                }
                result = CameraHistoryBatch(id: UUID(), range: range, anchor: anchor, pieces: [], gaps: [], neighbors: neighbors)
                return
            }
            guard let range, ["complete", "partial", "unavailable"].contains(record.outcome ?? ""),
                  record.frames == frameCount,
                  record.outcome != "complete" || (gaps.isEmpty && (frameCount > 0 || !available.isEmpty)),
                  record.outcome != "unavailable" || frameCount == 0 else { throw CameraHistoryError.invalidResponse }
            result = CameraHistoryBatch(id: UUID(), range: range, anchor: anchor, pieces: pieces,
                gaps: record.outcome == "unavailable" ? [range] : CameraHistoryRange.merged(gaps))
        default: throw CameraHistoryError.invalidResponse
        }
    }

    mutating func bytes(_ data: Data) throws {
        guard let pending, !data.isEmpty, data.count <= 65_536,
              payload.count + data.count <= pending.byteCount else { throw CameraHistoryError.invalidResponse }
        payload.append(data)
        guard payload.count == pending.byteCount else { return }
        guard let segment = pieces.last?.segment,
              Self.validAccessUnit(payload, lengthBytes: segment.nalUnitLengthBytes) else {
            throw CameraHistoryError.invalidResponse
        }
        pieces[pieces.count - 1].samples.append(CameraHistorySample(frame: pending, data: payload))
        receivedBytes += payload.count
        frameCount += 1
        self.pending = nil
        payload = Data()
    }

    static func validAccessUnit(_ data: Data, lengthBytes: Int) -> Bool {
        guard [1, 2, 4].contains(lengthBytes), data.count > lengthBytes else { return false }
        var offset = 0
        while offset < data.count {
            guard data.count - offset >= lengthBytes else { return false }
            let length = data[offset..<(offset + lengthBytes)].reduce(0) { ($0 << 8) | Int($1) }
            offset += lengthBytes
            guard length > 0, length <= data.count - offset else { return false }
            offset += length
        }
        return true
    }
}
