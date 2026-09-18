import SwiftUI

nonisolated enum CameraPlaybackSpeed: Int, CaseIterable, Identifiable, Sendable {
    case normal = 1
    case double = 2
    case quadruple = 4

    var id: Int { rawValue }
    var multiplier: Double { Double(rawValue) }
    var label: String { "\(rawValue)×" }

    // History replies necessarily trail the advertised live edge. Treat the
    // last half-second as caught up, rather than chasing network latency forever.
    static let historyEdgeTolerance = 0.5
}

struct CameraPlaybackSpeedMenu: View {
    @Binding var speed: CameraPlaybackSpeed

    var body: some View {
        Menu {
            Picker("Playback speed", selection: $speed) {
                ForEach(CameraPlaybackSpeed.allCases) { speed in
                    Text(speed.label).tag(speed)
                }
            }
        } label: {
            Text(speed.label)
        }
        .accessibilityLabel("Playback speed")
        .accessibilityValue(speed.label)
    }
}
