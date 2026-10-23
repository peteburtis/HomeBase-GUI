import Foundation
import HomeBaseProtocol

nonisolated enum CameraVideoTags {
    static let hiddenKey = "homebase.hidden"
    static func hidden(_ tags: [String: String]?) -> Bool { tags?[hiddenKey] != nil }

    private struct Span: Decodable {
        let startFrame: Int
        let endFrame: Int
        let value: String
    }
    /// Consume and validate the whole map, but retain only the presentation
    /// decision. This bounds per-frame memory independently of tag vocabulary.
    static func hiddenFrames(_ data: Data, count: Int) throws -> IndexSet {
        guard data.count <= 4_194_304, (1...1_000_000).contains(count) else { throw CameraHistoryError.invalidResponse }
        let map = try JSONDecoder().decode([String: [Span]].self, from: data)
        guard map.count <= 65_536, map.values.reduce(0, { $0 + $1.count }) <= 65_536 else { throw CameraHistoryError.invalidResponse }
        var result = IndexSet()
        for (key, spans) in map {
            var end = 0
            for span in spans {
                try HBVideoTags.validate([key: span.value])
                guard span.startFrame >= end, span.endFrame > span.startFrame, span.endFrame <= count else { throw CameraHistoryError.invalidResponse }
                if key == hiddenKey { result.insert(integersIn: span.startFrame..<span.endFrame) }
                end = span.endFrame
            }
        }
        return result
    }
}

/// The manifest is authoritative, including explicit removal over an unknown
/// legacy base. Never combine it with an older embedded MP4/JPEG timeline.
nonisolated struct CameraVideoTagTimeline: Codable, Equatable, Sendable {
    struct Change: Codable, Equatable, Sendable {
        let ticks: Int64
        let frame: Int64
        let tags: [String: String]
    }
    struct Override: Codable, Equatable, Sendable {
        let start: Int64
        let end: Int64
        let key: String
        let value: String?
    }
    let version: Int
    let changes: [Change]
    var unknownFromTicks: Int64? = nil
    var unknownFromFrame: Int64? = nil
    var overrides: [Override]? = nil
    static let maximumBytes = 512 * 1024

    func validate() throws {
        guard [1, 2].contains(version), changes.count <= 4096,
              (changes.first?.ticks == 0 && changes.first?.frame == 0)
                || (version == 2 && changes.isEmpty && unknownFromTicks == 0),
              version == 2 || overrides == nil,
              (overrides?.count ?? 0) <= 4096,
              try JSONEncoder().encode(self).count <= Self.maximumBytes else { throw CameraHistoryError.invalidResponse }
        var previous: Change?
        for change in changes {
            try HBVideoTags.validate(change.tags)
            guard change.ticks >= 0, change.frame >= 0,
                  previous.map({ change.ticks > $0.ticks && change.frame > $0.frame }) ?? true else { throw CameraHistoryError.invalidResponse }
            previous = change
        }
        if let unknownFromTicks, unknownFromTicks <= (previous?.ticks ?? -1) { throw CameraHistoryError.invalidResponse }
        if let unknownFromFrame {
            guard unknownFromTicks != nil, unknownFromFrame >= 0, unknownFromFrame > (previous?.frame ?? -1) else { throw CameraHistoryError.invalidResponse }
        }
        for edit in overrides ?? [] {
            guard edit.start >= 0, edit.end > edit.start else { throw CameraHistoryError.invalidResponse }
            try HBVideoTags.validate([edit.key: edit.value ?? ""])
        }
    }

    func hidden(ticks: Int64, frame: Int64?) -> Bool {
        let known: Bool
        if let frame, let unknownFromFrame { known = frame < unknownFromFrame }
        else { known = unknownFromTicks.map { ticks < $0 } ?? true }
        let base = known ? changes.last(where: { change in
            if let frame { return change.frame <= frame }
            return change.ticks <= ticks
        })?.tags : nil
        var hidden = CameraVideoTags.hidden(base)
        for edit in overrides ?? [] where edit.key == CameraVideoTags.hiddenKey && ticks >= edit.start && ticks < edit.end {
            hidden = edit.value != nil
        }
        return hidden
    }
}

nonisolated struct CameraStoredVideoTags: Codable, Equatable, Sendable {
    let timeline: CameraVideoTagTimeline?
    let encrypted: Data?
    func validate() throws {
        guard (timeline == nil) != (encrypted == nil) else { throw CameraHistoryError.invalidResponse }
        try timeline?.validate()
        if let encrypted {
            guard encrypted.count <= CameraVideoTagTimeline.maximumBytes + 72,
                  encrypted.starts(with: CameraS3Decryption.magic) else { throw CameraHistoryError.invalidResponse }
        }
    }
    func thaw(password: String?) throws -> CameraVideoTagTimeline {
        try validate()
        if let timeline { return timeline }
        let data = try CameraS3Decryption.decrypt(encrypted!, password: password)
        guard data.count <= CameraVideoTagTimeline.maximumBytes else { throw CameraHistoryError.tooLarge }
        let value = try JSONDecoder().decode(CameraVideoTagTimeline.self, from: data)
        try value.validate()
        return value
    }
}
