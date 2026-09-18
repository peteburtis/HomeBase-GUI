import SwiftUI

/// Native toolbar styling owns the glass, sizing, and foreground contrast.
struct CameraLiveModeButton: View {
    let isLive: Bool
    let action: () -> Void

    var systemImage: String {
        isLive
            ? "dot.radiowaves.left.and.right"
            : "chevron.forward.dotted.chevron.forward"
    }

    @ViewBuilder
    var body: some View {
        if isLive {
            button.buttonStyle(.borderedProminent).tint(.red)
        } else {
            button
        }
    }

    private var button: some View {
        Button(action: returnToLive) {
            // Toolbars hide standard Label titles even with .titleAndIcon.
            // Compose only the content; leave all button styling native.
            HStack {
                Image(systemName: systemImage)
                Text("Live")
            }
        }
        .accessibilityLabel("Live")
        .accessibilityValue(isLive ? "Live" : "Not live")
        .accessibilityHint(isLive ? "Already playing live" : "Returns to live playback")
    }

    func returnToLive() {
        guard !isLive else { return }
        action()
    }
}

enum CameraPlaybackToolbarMetrics {
    static let separation: CGFloat = 24
}

/// Timeline visibility never changes the leading playback controls. Native
/// grouping gives the three shuttle buttons one shared glass capsule.
struct CameraPlaybackToolbar<Back: View, Pause: View, Forward: View, Speed: View>: ToolbarContent {
    let isLive: Bool
    let playbackEnabled: Bool
    let close: () -> Void
    let goLive: () -> Void
    let back: Back
    let pause: Pause
    let forward: Forward
    let speed: Speed

    private var placement: ToolbarItemPlacement {
#if os(iOS)
        .topBarLeading
#else
        .navigation
#endif
    }

    @ToolbarContentBuilder var body: some ToolbarContent {
        ToolbarItem(placement: placement) {
            CameraPlayerCloseButton(separatesPlayback: true, action: close)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItemGroup(placement: placement) {
            back.disabled(!playbackEnabled)
            pause.disabled(!playbackEnabled)
            forward.disabled(!playbackEnabled)
        }
        ToolbarSpacer(.fixed, placement: placement)
        ToolbarItem(placement: placement) {
            CameraLiveModeButton(isLive: isLive, action: goLive)
                .disabled(!playbackEnabled)
        }
        if !isLive {
            ToolbarSpacer(.fixed, placement: placement)
            ToolbarItem(placement: placement) { speed.disabled(!playbackEnabled) }
        }
    }
}
