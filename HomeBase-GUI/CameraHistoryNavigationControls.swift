import SwiftUI

struct CameraHistoryNavigationControls: View {
    let neighbors: CameraHistoryNeighbors
    var searchIsComplete = true
    var excludesHidden = false
    let jump: (Bool) -> Void

    var body: some View {
        HStack(spacing: 20) {
            if neighbors.previous != nil { navigationButton(previous: true) }
            Text(statusLabel)
                .font(.callout)
            if neighbors.next != nil { navigationButton(previous: false) }
        }
    }

    private var statusLabel: String {
        if neighbors.previous == nil && neighbors.next == nil {
            if !searchIsComplete { return "Search incomplete" }
            return "No other video available"
        }
        return "Next available"
    }

    private func navigationButton(previous: Bool) -> some View {
        Button { jump(previous) } label: {
            Image(systemName: previous ? "chevron.backward" : "chevron.forward")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .cameraGlassBacker(in: Circle(), interactive: true)
        .accessibilityLabel(excludesHidden
            ? (previous ? "Previous unveiled recording" : "Next unveiled recording")
            : (previous ? "Previous available recording" : "Next available recording"))
        .accessibilityHint(previous ? "Jump to the preceding recording" : "Jump to the following recording")
    }
}
