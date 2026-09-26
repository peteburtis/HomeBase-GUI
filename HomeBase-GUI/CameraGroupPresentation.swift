import SwiftUI

/// A presentation-only lens over the open cameras. Focusing never changes the
/// group's selection, session ownership, or shared playback clock.
struct CameraGroupPresentation {
    let sessions: [CameraGroupSession]
    let focusedCameraID: String?

    var focusedSession: CameraGroupSession? {
        guard sessions.count > 1 else { return nil }
        return sessions.first { $0.id == focusedCameraID }
    }

    var visibleSessions: [CameraGroupSession] {
        focusedSession.map { [$0] } ?? sessions
    }

    var showsMultipleCameras: Bool { focusedSession == nil && sessions.count > 1 }

    func isVisible(_ session: CameraGroupSession) -> Bool {
        focusedSession == nil || focusedSession === session
    }

    func frame(for session: CameraGroupSession, normal: CGRect, size: CGSize,
               division: CameraGroupLayout.Division?) -> CGRect {
        guard focusedSession === session else { return normal }
        // Use precisely the existing single-camera layout, including the
        // reserved fold when the device is partially open.
        if let division {
            return CameraGroupLayout.cells(count: 1, in: size, division: division).first ?? .zero
        }
        return CGRect(origin: .zero, size: size)
    }
}

/// Keep every pane mounted throughout the zoom and fade. Invisible cameras
/// retain their renderers and buffers, but cannot receive touches or VoiceOver.
struct CameraFocusedPanePlacement: ViewModifier {
    let frame: CGRect
    let isVisible: Bool
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .frame(width: frame.width, height: frame.height)
            .clipped()
            .position(x: frame.midX, y: frame.midY)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .zIndex(isFocused ? 1 : 0)
    }
}
