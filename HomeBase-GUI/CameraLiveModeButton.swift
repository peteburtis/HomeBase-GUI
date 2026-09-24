import SwiftUI

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
