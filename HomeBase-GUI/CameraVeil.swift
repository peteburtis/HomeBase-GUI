import Combine
import LocalAuthentication
import SwiftUI

/// LocalAuthentication has no public Face ID permission-status query.
/// A successful OS check in this process is proof that consent already exists;
/// never persist that proof across restores/reinstalls or trigger consent here.
@MainActor enum CameraBiometricConsent {
    static var hasAuthenticated = false
}

@MainActor protocol CameraVeilAuthenticating {
    func authenticateIfAvailable() async -> Bool
    func cancel()
}

@MainActor final class CameraVeilBiometrics: CameraVeilAuthenticating {
    private var context: LAContext?
    // Cancellation is explicit; releasing an idle context needs no actor hop.
    nonisolated deinit {}
    static func shouldEvaluate(available: Bool, type: LABiometryType, knownConsent: Bool) -> Bool {
        available && (type == .touchID || knownConsent)
    }
    func authenticateIfAvailable() async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        let available = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        guard Self.shouldEvaluate(available: available, type: context.biometryType,
                                  knownConsent: CameraBiometricConsent.hasAuthenticated) else { return true }
        self.context = context
        defer { if self.context === context { self.context = nil } }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Show hidden camera footage.") { success, error in
                if success { continuation.resume(returning: true); return }
                // Availability can change between preflight and evaluation.
                let code = (error as? LAError)?.code
                continuation.resume(returning: code == .biometryNotAvailable || code == .biometryNotEnrolled || code == .biometryLockout)
            }
        }
    }
    func cancel() { context?.invalidate(); context = nil }
}

/// One full-screen viewer, shared by its camera panes. No stored preference,
/// tag mutation, Keychain access, or effect on the camera-grid previews.
@MainActor final class CameraVeilSession: ObservableObject {
    @Published private(set) var showsHidden = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var authenticationFailed = false
    private let authenticator: any CameraVeilAuthenticating
    private var task: Task<Void, Never>?
    private var generation = UUID()
    init(authenticator: (any CameraVeilAuthenticating)? = nil) {
        self.authenticator = authenticator ?? CameraVeilBiometrics()
    }
    // SwiftUI may release StateObjects outside a Swift task. hide() owns cleanup.
    nonisolated deinit {}

    func toggle() {
        if showsHidden || isAuthenticating { hide(); return }
        let id = UUID(); generation = id
        authenticationFailed = false; isAuthenticating = true
        task = Task { [weak self] in
            guard let self else { return }
            let allowed = await self.authenticator.authenticateIfAvailable()
            guard !Task.isCancelled, self.generation == id else { return }
            self.isAuthenticating = false; self.task = nil
            self.showsHidden = allowed; self.authenticationFailed = !allowed
        }
    }
    func hide() {
        generation = UUID(); task?.cancel(); task = nil; authenticator.cancel()
        showsHidden = false; isAuthenticating = false; authenticationFailed = false
    }
}

private struct CameraShowsHiddenVideoKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var cameraShowsHiddenVideo: Bool {
        get { self[CameraShowsHiddenVideoKey.self] }
        set { self[CameraShowsHiddenVideoKey.self] = newValue }
    }
}

struct CameraVeilCover: View {
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                Image(systemName: "eye.slash").font(.largeTitle)
                Text("Private Video").font(.headline)
            }.foregroundStyle(.white)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Private Video")
        .allowsHitTesting(false)
    }
}

struct CameraVeilButton: View {
    @ObservedObject var veil: CameraVeilSession
    var body: some View {
        Button { veil.toggle() } label: {
            ZStack {
                if veil.isAuthenticating { ProgressView().tint(.white) }
                else { Image(systemName: veil.showsHidden ? "eye" : "eye.slash").font(.title3.weight(.semibold)) }
            }
            .frame(width: CameraPTZOverlayMetrics.buttonSize, height: CameraPTZOverlayMetrics.buttonSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .cameraGlassBacker(in: Circle(), interactive: true)
        .accessibilityLabel(veil.showsHidden ? "Hide private video" : "Show hidden footage")
        .accessibilityHint(veil.authenticationFailed ? "Authentication did not succeed. Tap to try again." : "Applies to this viewer until it closes or enters the background.")
        .help(veil.showsHidden ? "Hide private video" : "Show hidden footage")
    }
}
