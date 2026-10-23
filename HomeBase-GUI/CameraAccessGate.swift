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

    var cameraAccessLifecycle: CameraAccessLifecycle? {
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

    /// Retained PiP authentication is not permission to restart foreground
    /// streams during background -> inactive, before the lifecycle resumes them.
    /// Store this in the snapshot so nested views receive a changed input even
    /// when every authentication field (and the session reference) is unchanged.
    let canStream: Bool

    init(session: CameraAccessSession?, isAuthorized: Bool, isUnlocked: Bool,
         isAuthenticating: Bool, errorMessage: String?) {
        self.session = session
        self.isAuthorized = isAuthorized
        self.isUnlocked = isUnlocked
        self.isAuthenticating = isAuthenticating
        self.errorMessage = errorMessage
        canStream = isAuthorized && session?.streamsSuspended != true
    }

    /// Authentication is normally quick. Keep initial entry, in-flight retries,
    /// and temporary system-UI concealment blank; offer recovery only on failure.
    var showsUnlockRecovery: Bool {
        !isAuthorized && !isAuthenticating && errorMessage != nil
    }

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
            isUnlocked: session.isUnlocked && !session.streamsSuspended && scenePhase == .active,
            isAuthenticating: session.isAuthenticating,
            errorMessage: session.errorMessage
        ))
    }
}

struct LockedCameraPreview: View {
    let showsLock: Bool

    var body: some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if showsLock {
                    Image(systemName: "lock.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
            }
            .accessibilityLabel(showsLock ? "Camera locked" : "Camera preview hidden")
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
                        LockedCameraPreview(showsLock: access.showsUnlockRecovery)
                    }
                }
        } else {
            LockedCameraPreview(showsLock: access.showsUnlockRecovery)
        }
    }
}

struct CameraUnlockButton: View {
    let access: CameraAccessPresentation

    var body: some View {
        if access.showsUnlockRecovery {
            VStack(spacing: 8) {
                Button("Unlock", systemImage: "lock.open") {
                    access.unlock()
                }
                .accessibilityIdentifier("camera.unlock")

                if let message = access.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }
}

struct CameraAccessLockedView: View {
    let access: CameraAccessPresentation

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if access.showsUnlockRecovery {
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
}

/// Tracks actual camera-section ownership rather than the preview's appearance.
/// Presenting a fullscreen camera must not be mistaken for leaving Cameras.
@MainActor
final class CameraAccessLifecycle: ObservableObject {
    private enum TrackedScenePhase: Equatable {
        case active
        case inactive
        case background
    }

    let session: CameraAccessSession
    private var owners: Set<UUID> = []
    private var isBackgrounded = false
    private var scenePhases: [UUID: TrackedScenePhase] = [:]
    private let legacySceneID = UUID()
    private var hasActivePictureInPicture = false
    private var externalDisplays: Set<UUID> = []
    private var isDeviceLocked = false
    private var isRestoringPictureInPicture = false
    private var restorationTimeout: Task<Void, Never>?

    private var retainsAccessForPictureInPicture: Bool {
        hasActivePictureInPicture || isRestoringPictureInPicture
    }

    private var retainsAccessForOutput: Bool {
        retainsAccessForPictureInPicture || !externalDisplays.isEmpty
    }

    init(session: CameraAccessSession? = nil) {
        self.session = session ?? CameraAccessSession()
    }

    func setActive(_ isActive: Bool, owner: UUID) {
        if isActive {
            let wasEmpty = owners.isEmpty
            owners.insert(owner)
            if wasEmpty && !isBackgrounded && !isDeviceLocked {
                session.resumeStreams()
                session.enter()
            }
            finishRestorationHandoffIfReady()
        } else {
            let removed = owners.remove(owner) != nil
            if removed && owners.isEmpty {
                session.suspendStreams()
                lockIfUnowned()
            }
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        scenePhaseChanged(phase, scene: legacySceneID)
    }

    /// Track window phases independently. One hidden browser window must not
    /// suspend streams that belong to another active camera window.
    func scenePhaseChanged(_ phase: ScenePhase, scene sceneID: UUID) {
        switch phase {
        case .background:
            scenePhases[sceneID] = .background
            enterBackgroundIfEverySceneIsBackgrounded()
        case .active:
            scenePhases[sceneID] = .active
            isDeviceLocked = false
            if isBackgrounded {
                session.resumeStreams()
            }
            if isBackgrounded, !owners.isEmpty {
                session.enter()
            }
            isBackgrounded = false
            finishRestorationHandoffIfReady()
        case .inactive:
            scenePhases[sceneID] = .inactive
        @unknown default:
            break
        }
    }

    func sceneDisconnected(_ sceneID: UUID) {
        scenePhases.removeValue(forKey: sceneID)
        enterBackgroundIfEverySceneIsBackgrounded()
    }

    private func enterBackgroundIfEverySceneIsBackgrounded() {
        guard !isBackgrounded,
              scenePhases.isEmpty
                || scenePhases.values.allSatisfy({ $0 == .background })
        else { return }
        isBackgrounded = true
        session.suspendStreams()
        lockIfUnowned()
    }

    func pictureInPictureStarted() {
        // Retain an existing grant only; PiP can never manufacture authorization.
        guard session.isUnlocked else { return }
        hasActivePictureInPicture = true
    }

    /// Called only for a connected window, not merely an accessory registration.
    @discardableResult
    func externalDisplayStarted(owner: UUID) -> Bool {
        guard session.isUnlocked, !session.streamsSuspended,
              !isBackgrounded, !isDeviceLocked else { return false }
        externalDisplays.insert(owner)
        return true
    }

    func externalDisplayStopped(owner: UUID) {
        if externalDisplays.remove(owner) != nil { lockIfUnowned() }
    }

    func pictureInPictureStopped() {
        hasActivePictureInPicture = false
        lockIfUnowned()
    }

    func pictureInPictureWillRestore() {
        guard hasActivePictureInPicture, session.isUnlocked else { return }
        isRestoringPictureInPicture = true
        restorationTimeout?.cancel()
        restorationTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.pictureInPictureRestorationCompleted(false)
        }
    }

    func pictureInPictureRestorationCompleted(_ success: Bool) {
        if success {
            finishRestorationHandoffIfReady()
        } else {
            endRestorationHandoff()
            lockIfUnowned()
        }
    }

    private func finishRestorationHandoffIfReady() {
        // Native PiP may stop before the scene is active or the reopened
        // viewer's access scope appears. Bridge both event orders without a
        // second Face ID prompt or a temporary release of S3 credentials.
        guard isRestoringPictureInPicture, !isBackgrounded, !owners.isEmpty else { return }
        endRestorationHandoff()
    }

    private func endRestorationHandoff() {
        restorationTimeout?.cancel()
        restorationTimeout = nil
        isRestoringPictureInPicture = false
    }

    private func lockIfUnowned() {
        if !retainsAccessForOutput && (isBackgrounded || isDeviceLocked || owners.isEmpty) {
            session.lock()
        }
    }

    func protectedDataWillBecomeUnavailable() {
        isDeviceLocked = true
        session.suspendStreams()
        // Keep only already-running output and secrets already in memory. This
        // does not grant access to protected files or perform another Keychain read.
        if !hasActivePictureInPicture { endRestorationHandoff() }
        lockIfUnowned()
    }

    func reset() {
        owners.removeAll()
        externalDisplays.removeAll()
        hasActivePictureInPicture = false
        endRestorationHandoff()
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
