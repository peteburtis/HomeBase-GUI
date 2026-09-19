import SwiftUI

/// Native toolbar styling owns the glass, sizing, and foreground contrast.
struct CameraLiveModeButton: View {
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
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
            if showsTitle {
                // iOS 26 toolbars hide Label titles even with .titleAndIcon.
                // Compose only the regular-width label; sizing stays native.
                HStack {
                    Image(systemName: systemImage)
                    Text("Live")
                }
            } else {
                Image(systemName: systemImage)
            }
        }
        .accessibilityLabel("Live")
        .accessibilityValue(isLive ? "Live" : "Not live")
        .accessibilityHint(isLive ? "Already playing live" : "Returns to live playback")
    }

    private var showsTitle: Bool {
#if os(iOS)
        horizontalSizeClass != .compact
#else
        true
#endif
    }

    func returnToLive() {
        guard !isLive else { return }
        action()
    }
}

/// Let the toolbar provide the dismissal button's label, sizing, and glass.
struct CameraPlayerCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(role: .close, action: action)
            .accessibilityLabel("Close live video")
            .accessibilityIdentifier("camera.close")
    }
}

/// Native toolbar items retain system sizing, glass, and adaptation.
struct CameraPlaybackToolbar<Back: View, Pause: View, Forward: View, Speed: View>: ToolbarContent {
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    let isLive: Bool
    let playbackEnabled: Bool
    let close: () -> Void
    let goLive: () -> Void
    let back: Back
    let pause: Pause
    let forward: Forward
    let speed: Speed

    private var usesCompactOverflow: Bool {
#if os(iOS)
        horizontalSizeClass == .compact
#else
        false
#endif
    }

    private var placement: ToolbarItemPlacement {
#if os(iOS)
        .topBarLeading
#else
        .navigation
#endif
    }

    private var speedPlacement: ToolbarItemPlacement {
#if os(iOS)
        usesCompactOverflow ? .topBarTrailing : placement
#else
        placement
#endif
    }

    @ToolbarContentBuilder var body: some ToolbarContent {
        ToolbarItem(placement: placement) {
            CameraPlayerCloseButton(action: close)
        }
        ToolbarSpacer(.fixed, placement: placement)
        if usesCompactOverflow {
            ToolbarItem(placement: placement) { pause.disabled(!playbackEnabled) }
        } else {
            ToolbarItemGroup(placement: placement) {
                back.disabled(!playbackEnabled)
                pause.disabled(!playbackEnabled)
                forward.disabled(!playbackEnabled)
            }
        }
        if !usesCompactOverflow { ToolbarSpacer(.fixed, placement: placement) }
        ToolbarItem(placement: placement) {
            CameraLiveModeButton(isLive: isLive, action: goLive)
                .disabled(!playbackEnabled)
        }
        if !isLive {
            if !usesCompactOverflow { ToolbarSpacer(.fixed, placement: placement) }
            ToolbarItem(placement: speedPlacement) { speed.disabled(!playbackEnabled) }
        }
        if usesCompactOverflow {
            // iOS 26 compatibility: deliberately put the less-frequent actions
            // in the system overflow menu in compact width. When adopting iOS 27,
            // replace this size-class workaround with its toolbar overflow and
            // visibility-priority APIs (and keep this fallback for iOS 26).
            ToolbarItemGroup(placement: .secondaryAction) {
                back.disabled(!playbackEnabled)
                forward.disabled(!playbackEnabled)
            }
        }
    }
}
