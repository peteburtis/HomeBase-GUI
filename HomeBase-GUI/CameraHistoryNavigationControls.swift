import SwiftUI

struct CameraHistoryNavigationControls: View {
    let neighbors: CameraHistoryNeighbors
    let jump: (Bool) -> Void

    var body: some View {
        HStack(spacing: 20) {
            if neighbors.previous != nil { navigationButton(previous: true) }
            Text(neighbors.previous == nil && neighbors.next == nil ? "No other video available" : "Next available")
                .font(.callout)
            if neighbors.next != nil { navigationButton(previous: false) }
        }
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
        .accessibilityLabel(previous ? "Previous available recording" : "Next available recording")
        .accessibilityHint(previous ? "Jump to the preceding recording" : "Jump to the following recording")
    }
}
