import Foundation
import HomeBaseProtocol

/// Public wire contract shared with the recorder, not Keychain/private config.
nonisolated struct CameraS3ShardTiming: Codable, Equatable, Sendable {
    let format: String
    let schemaVersion: Int
    let storeID: String
    let cameraID: String
    let shardID: String
    let time: CameraHistorySegment.Time
    let firstFrameReceivedUTC: Double
    let timescale: UInt32
    let rtpTimestamp: UInt32
    let ssrc: UInt32?
}

nonisolated struct CameraS3ManifestShard: Codable, Equatable, Sendable {
    let id: String
    let key: String
    let size: Int64
    let sha256: String
    let encryption: String?
    let timing: CameraS3ShardTiming
    let endTicks: Int64
    var range: CameraHistoryRange {
        .init(start: timing.time.canonicalUTC,
              end: timing.time.canonicalUTC + Double(endTicks) / Double(timing.timescale))
    }

    func validate(store: HBCameraPlaybackMetadata.S3Store, cameraID: String) throws {
        guard UUID(uuidString: id) != nil, timing.shardID == id,
              timing.storeID == store.id, timing.cameraID == cameraID,
              timing.format == "com.graygoolabs.hbnvr.timing", timing.schemaVersion == 1,
              timing.timescale > 0, timing.timescale <= Int32.max, endTicks > 0,
              range.isValid, range.duration <= 31 * 86_400,
              timing.firstFrameReceivedUTC.isFinite, timing.time.receivedUTC.isFinite,
              timing.time.cameraUTC?.isFinite != false,
              UUID(uuidString: timing.time.epochID) != nil,
              ["camera", "received"].contains(timing.time.canonicalSource),
              timing.time.canonicalUTC == (timing.time.canonicalSource == "camera" ? timing.time.cameraUTC : timing.time.receivedUTC),
              size > 0,
              sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && $0.isASCII }),
              encryption == nil || encryption == "hbnvr-pbe-v1",
              key.hasPrefix(store.prefix), key.utf8.count <= 1024,
              !key.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              key.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw CameraS3HistoryError.invalidManifest
        }
    }
}

nonisolated struct CameraS3Manifest: Codable, Sendable {
    let format: String
    let schemaVersion: Int
    let storeID: String
    let cameraID: String
    let generatedAt: Double
    let period: String
    let shards: [CameraS3ManifestShard]
}

nonisolated struct CameraS3Catalog: Codable, Sendable {
    struct Day: Codable, Equatable, Sendable {
        let day: String
        let start: Double
        let end: Double
        var range: CameraHistoryRange { .init(start: start, end: end) }
    }
    let format: String
    let schemaVersion: Int
    let storeID: String
    let cameraID: String
    let generatedAt: Double
    let days: [Day]
}

nonisolated enum CameraS3HistoryError: LocalizedError, Equatable {
    case invalidManifest, unsupported, hashMismatch, incomplete, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidManifest: "The S3 playback index is invalid or exceeds the playback limits."
        case .unsupported: "Update HBNVR and Homebase to publish S3 playback manifests."
        case .hashMismatch: "The downloaded S3 recording did not match its manifest."
        case .incomplete: "The S3 index is being updated. Try again shortly."
        case .unavailable: "S3 history is unavailable. Check the saved reader credentials and encryption password."
        }
    }
}

nonisolated enum CameraS3ManifestLayout {
    static func root(prefix: String, cameraID: String) -> String {
        prefix + ".hbnvr/playback/v1/" + cameraID.lowercased() + "/"
    }
    static func day(_ timestamp: Double) -> String { stamp(timestamp, format: "yyyy-MM-dd") }
    static func month(_ timestamp: Double) -> String { stamp(timestamp, format: "yyyy-MM") }
    private static func stamp(_ timestamp: Double, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
    static func validDay(_ day: String) -> Bool {
        guard day.count == 10, day.utf8.allSatisfy({ (48...57).contains($0) || $0 == 45 }) else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return formatter.date(from: day).map { formatter.string(from: $0) == day } ?? false
    }
}
