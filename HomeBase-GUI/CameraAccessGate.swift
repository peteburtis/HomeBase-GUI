//
//  CameraAccessGate.swift
//  HomeBase-GUI
//

import Combine
import SwiftUI

private struct CameraAccessSessionKey: EnvironmentKey {
    static let defaultValue: CameraAccessSession? = nil
}

private struct CameraAccessLifecycleKey: EnvironmentKey {
    static let defaultValue: CameraAccessLifecycle? = nil
}

extension EnvironmentValues {
    var cameraAccessSession: CameraAccessSession? {
        get { self[CameraAccessSessionKey.self] }
        set { self[CameraAccessSessionKey.self] = newValue }
    }

    fileprivate var cameraAccessLifecycle: CameraAccessLifecycle? {
        get { self[CameraAccessLifecycleKey.self] }
        set { self[CameraAccessLifecycleKey.self] = newValue }
    }
}

/// A presentation snapshot, not a second authorization state. The session is
/// shared by the camera list and every player opened from it.
@MainActor
struct CameraAccessPresentation {
    let session: CameraAccessSession?
    let isAuthorized: Bool
    let isUnlocked: Bool
    let isAuthenticating: Bool
    let errorMessage: String?

    func unlock() {
        session?.unlock()
    }
}

struct CameraAccessGate<Content: View>: View {
    @Environment(\.cameraAccessSession) private var session
    @Environment(\.scenePhase) private var scenePhase
    @ViewBuilder let content: (CameraAccessPresentation) -> Content

    var body: some View {
        if let session {
            ObservedCameraAccessGate(session: session, content: content)
        } else {
            // Standalone previews/tests may omit the application session. Every
            // real app window supplies it at the root.
            content(CameraAccessPresentation(
                session: nil,
                isAuthorized: true,
                isUnlocked: true,
                isAuthenticating: false,
                errorMessage: nil
            ))
        }
    }
}

private struct ObservedCameraAccessGate<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var session: CameraAccessSession
    @ViewBuilder let content: (CameraAccessPresentation) -> Content

    var body: some View {
        content(CameraAccessPresentation(
            session: session,
            isAuthorized: session.isUnlocked,
            // Inactive also conceals imagery before the app-switcher snapshot,
            // but must not cancel the system's own authentication presentation.
            isUnlocked: session.isUnlocked && scenePhase == .active,
            isAuthenticating: session.isAuthenticating,
            errorMessage: session.errorMessage
        ))
    }
}

struct LockedCameraPreview: View {
    var body: some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                Image(systemName: "lock.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Camera locked")
    }
}

/// A locked preview never constructs its media view. Once authorized, transient
/// inactivity conceals the picture without rebuilding the stream underneath it.
struct CameraProtectedPreview<Content: View>: View {
    let access: CameraAccessPresentation
    @ViewBuilder let content: () -> Content

    var body: some View {
        if access.isAuthorized {
            content()
                .opacity(access.isUnlocked ? 1 : 0)
                .allowsHitTesting(access.isUnlocked)
                .overlay {
                    if !access.isUnlocked {
                        LockedCameraPreview()
                    }
                }
        } else {
            LockedCameraPreview()
        }
    }
}

struct CameraUnlockButton: View {
    let access: CameraAccessPresentation

    var body: some View {
        VStack(spacing: 8) {
            Button("Unlock", systemImage: "lock.open") {
                access.unlock()
            }
            .disabled(access.isAuthenticating)
            .accessibilityIdentifier("camera.unlock")

            if access.isAuthenticating {
                ProgressView()
                    .accessibilityLabel("Unlocking cameras")
            } else if let message = access.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

struct CameraAccessLockedView: View {
    let access: CameraAccessPresentation

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                CameraUnlockButton(access: access)
            }
            .padding()
        }
    }
}

/// Tracks actual camera-section ownership rather than the preview's appearance.
/// Presenting a fullscreen camera must not be mistaken for leaving Cameras.
@MainActor
final class CameraAccessLifecycle: ObservableObject {
    let session: CameraAccessSession
    private var owners: Set<UUID> = []
    private var isBackgrounded = false

    init(session: CameraAccessSession? = nil) {
        self.session = session ?? CameraAccessSession()
    }

    func setActive(_ isActive: Bool, owner: UUID) {
        if isActive {
            let wasEmpty = owners.isEmpty
            owners.insert(owner)
            if wasEmpty && !isBackgrounded {
                session.enter()
            }
        } else {
            let removed = owners.remove(owner) != nil
            if removed && owners.isEmpty {
                session.lock()
            }
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            isBackgrounded = true
            session.lock()
        case .active:
            if isBackgrounded && !owners.isEmpty {
                session.enter()
            }
            isBackgrounded = false
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    func reset() {
        owners.removeAll()
        session.lock()
    }
}

private struct CameraAccessScope: ViewModifier {
    @Environment(\.cameraAccessLifecycle) private var lifecycle
    @State private var owner = UUID()
    @State private var isVisible = false
    let isActive: Bool
    let isPresentingCamera: Bool

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                lifecycle?.setActive(isActive, owner: owner)
            }
            .onChange(of: isActive) { _, active in
                lifecycle?.setActive(active && (isVisible || isPresentingCamera), owner: owner)
            }
            .onDisappear {
                isVisible = false
                // A presentation obscures its origin view on iOS. The origin
                // retains the lease until the user actually navigates away.
                guard !isPresentingCamera else { return }
                lifecycle?.setActive(false, owner: owner)
            }
    }
}

extension View {
    func cameraAccessScope(
        isActive: Bool,
        isPresentingCamera: Bool = false
    ) -> some View {
        modifier(CameraAccessScope(
            isActive: isActive,
            isPresentingCamera: isPresentingCamera
        ))
    }

    func cameraAccessLifecycle(_ lifecycle: CameraAccessLifecycle) -> some View {
        environment(\.cameraAccessSession, lifecycle.session)
            .environment(\.cameraAccessLifecycle, lifecycle)
    }
}
