import SwiftUI

/// One button with fixed label geometry. Only the glass tint and foreground
/// change, so the toolbar cannot replace the inactive state with an icon circle.
struct CameraLiveModeButton: View {
    let isLive: Bool
    let shuttleControlsVisible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Live")
                .font(.body)
                .fixedSize()
                .padding(.horizontal, 14)
                .frame(minWidth: 64, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isLive ? Color.black : Color.white)
        .cameraGlassBacker(in: Capsule(), interactive: true, tint: isLive ? .red : nil)
        .fixedSize()
        .accessibilityLabel("Live")
        .accessibilityValue(isLive ? "Live" : "Not live")
        .accessibilityHint(isLive
            ? (shuttleControlsVisible ? "Hides playback controls" : "Shows playback controls")
            : "Returns to live playback and hides playback controls")
    }
}
