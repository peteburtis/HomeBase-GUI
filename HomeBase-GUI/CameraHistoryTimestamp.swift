import Foundation
import HomeBaseProtocol

nonisolated enum CameraHistoryTimestamp {
    static func timeZone(in metadata: [String: HBJSONValue], fallback: TimeZone = .autoupdatingCurrent) -> TimeZone {
        guard let value = metadata[HBDeviceMetadataKeys.cameraPlayback],
              let playback = try? value.decoded(HBCameraPlaybackMetadata.self),
              let identifier = playback.timeZoneIdentifier,
              let zone = TimeZone(identifier: identifier) else { return fallback }
        return zone
    }

    static func string(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// The timeline uses the NVR-derived live edge, not the phone's clock or a
    /// calendar-day boundary, to decide when the date becomes useful.
    static func timelineString(for date: Date, latest: Date, timeZone: TimeZone) -> String {
        let timestamp = string(for: date, timeZone: timeZone)
        let time = String(timestamp.suffix(8))
        return latest.timeIntervalSince(date) > 24 * 60 * 60 ? "\(time) \(timestamp.prefix(10))" : time
    }
}
