import SwiftUI

extension ToolbarContent {
    /// Keep related playback controls on the horizontal bar when iPhone Duo
    /// moves the remaining toolbar items to a vertical edge.
    @ToolbarContentBuilder
    func cameraPlaybackHorizontalAxis() -> some ToolbarContent {
#if os(iOS)
        if #available(iOS 27.1, *) {
            axisBehavior(.horizontalOnly)
        } else {
            self
        }
#else
        self
#endif
    }
}

/// Native toolbar styling owns the glass, sizing, and foreground contrast.
struct CameraLiveModeButton: View {
    let isLive: Bool
    let showsTitle: Bool
    let action: () -> Void

    init(
        isLive: Bool,
        showsTitle: Bool = true,
        action: @escaping () -> Void
    ) {
        self.isLive = isLive
        self.showsTitle = showsTitle
        self.action = action
    }

    var systemImage: String {
        isLive
            ? "dot.radiowaves.left.and.right"
            : CameraPlayerPanelPicker.historySymbol
    }

    var title: String { isLive ? "Live" : "History" }

    @ViewBuilder
    var body: some View {
        button
            .buttonStyle(.borderedProminent)
            .tint(isLive ? .red : .yellow)
    }

    private var button: some View {
        Button(action: toggleMode) {
            if showsTitle {
                HStack {
                    Image(systemName: systemImage)
                    Text(title)
                }
            } else {
                Image(systemName: systemImage)
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(isLive ? "Live video" : "History")
        .accessibilityHint(isLive ? "Pauses and shows history" : "Returns to live video")
    }

    func toggleMode() {
        action()
    }
}

/// Let the toolbar provide the dismissal button's label, sizing, and glass.
struct CameraPlayerCloseButton: View {
    var returnsToCameras = false
    var usesSystemCloseRole = true
    let action: () -> Void

    @ViewBuilder var body: some View {
        if returnsToCameras {
            Button("Back to cameras", systemImage: "chevron.backward", action: action)
                .accessibilityIdentifier("camera.backToCameras")
        } else if usesSystemCloseRole {
            Button(role: .close, action: action)
                .accessibilityLabel("Close live video")
                .accessibilityIdentifier("camera.close")
        } else {
            // The system close role gets its own glass island. Use a normal
            // toolbar button when Close shares a group with Minimize.
            Button("Close live video", systemImage: "xmark", action: action)
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("camera.close")
        }
    }
}
