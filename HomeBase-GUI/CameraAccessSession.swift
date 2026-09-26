import Combine
import Foundation
import LocalAuthentication

nonisolated enum CameraAccessError: Error, LocalizedError, Equatable, Sendable {
    case biometryNotAvailable
    case biometryNotEnrolled
    case biometryLockout
    case authenticationCancelled
    case authenticationFailed
    case authenticationUnavailable
    case keychain(Int32)
    case invalidSavedCredentials
    case invalidCredentials
    case cannotProtectCredentials
    case sessionClosed
    case authenticationInProgress

    var errorDescription: String? {
        switch self {
        case .biometryNotAvailable: "Biometric authentication is unavailable."
        case .biometryNotEnrolled: "Set up Face ID or Touch ID on this device to unlock cameras."
        case .biometryLockout: "Biometric authentication is locked. Unlock your device and try again."
        case .authenticationCancelled: "Authentication was cancelled. Select Unlock to try again."
        case .authenticationFailed: "Authentication did not succeed. Select Unlock to try again."
        case .authenticationUnavailable: "Authentication could not be completed."
        case .keychain(let status): "Saved S3 credentials could not be accessed (Keychain \(status)). S3 access remains locked."
        case .invalidSavedCredentials: "Saved S3 credentials could not be read. S3 access remains locked."
        case .invalidCredentials: "An S3 destination, access key ID, and secret access key are required."
        case .cannotProtectCredentials: "Biometric protection could not be created for these credentials."
        case .sessionClosed: "The camera session was closed. Unlock cameras to continue."
        case .authenticationInProgress: "Authentication is already in progress."
        }
    }

    nonisolated static func authentication(_ error: Error?) -> CameraAccessError {
        guard let error = error as? LAError else { return .authenticationUnavailable }
        switch error.code {
        case .biometryNotAvailable: return .biometryNotAvailable
        case .biometryNotEnrolled: return .biometryNotEnrolled
        case .biometryLockout: return .biometryLockout
        case .userCancel, .appCancel, .systemCancel: return .authenticationCancelled
        case .authenticationFailed: return .authenticationFailed
        default: return .authenticationUnavailable
        }
    }
}

@MainActor
protocol CameraBiometricAuthenticating {
    func authenticate(using attempt: CameraAuthenticationAttempt) async throws
}

@MainActor
final class CameraSystemBiometricAuthenticator: CameraBiometricAuthenticating {
    func authenticate(using attempt: CameraAuthenticationAttempt) async throws {
        // evaluatePolicy, rather than an app-owned consent preference, lets the
        // OS ask permission on first use and reflects later Settings changes.
        // No passcode fallback: only biometryNotAvailable permits optional entry.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            attempt.context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock cameras and saved recording access."
            ) { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: CameraAccessError.authentication(error)) }
            }
        }
    }
}

nonisolated enum CameraAccessEnvironment: Sendable {
    case device
    case simulator

    static var current: Self {
#if targetEnvironment(simulator)
        .simulator
#else
        .device
#endif
    }
}

/// Ephemeral camera-section state. There is deliberately no persisted consent
/// preference. Simulator-only camera viewing is exempt when S3 credentials are absent.
@MainActor
final class CameraAccessSession: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var unlockedCredentials: CameraS3Credentials?
    @Published private(set) var credentialPresence: CameraS3CredentialPresence?
    @Published private(set) var credentialErrorMessage: String?
    // Authentication can survive a PiP background transition independently of
    // ordinary stream readiness. Publish both sides of that transition so the
    // viewer can resume even when its authorization never changed.
    @Published private(set) var streamsSuspended = false

    var canRetrySavedCredentials: Bool {
        isUnlocked && credentialPresence != .missing && unlockedCredentials == nil
    }

    private let credentials: any CameraS3CredentialStoring
    private let authenticator: any CameraBiometricAuthenticating
    private let environment: CameraAccessEnvironment
    private var hasEntered = false
    private var generation: UInt64 = 0
    private var attempt: CameraAuthenticationAttempt?
    private var task: Task<Void, Never>?
    private var streamAuthorization = CameraStreamAuthorization()
    private var streamArbiters: [ObjectIdentifier: CameraStreamArbiter] = [:]

    func authorizeStreams(_ arbiter: CameraStreamArbiter) throws -> CameraStreamAuthorization {
        guard isUnlocked, !streamsSuspended else { throw CameraAccessError.sessionClosed }
        if !streamAuthorization.isValid { streamAuthorization = CameraStreamAuthorization() }
        streamArbiters[ObjectIdentifier(arbiter)] = arbiter
        return streamAuthorization
    }

    /// Only an explicit foreground PiP action may create this lease. It grants
    /// no UI, control, history, or Keychain access. The PiP owner must revoke it
    /// on stop/failure, server changes, and protected-data loss.
    func authorizePictureInPicture(camera: String) throws -> CameraStreamAuthorization {
        guard isUnlocked, !camera.isEmpty else { throw CameraAccessError.sessionClosed }
        return CameraStreamAuthorization(camera: camera)
    }

    init(
        credentials: (any CameraS3CredentialStoring)? = nil,
        authenticator: (any CameraBiometricAuthenticating)? = nil,
        environment: CameraAccessEnvironment = .current
    ) {
        self.credentials = credentials ?? CameraKeychainCredentialStore()
        self.authenticator = authenticator ?? CameraSystemBiometricAuthenticator()
        self.environment = environment
    }

    /// Call on camera-section entry, not when moving between its list/player.
    func enter() {
        guard !hasEntered else { return }
        hasEntered = true
        unlock()
    }

    /// Explicit retry after a cancelled or failed prompt. Duplicate calls never
    /// overlap prompts, and automatic reappearance never repeatedly asks.
    func unlock() {
        guard !isUnlocked, !isAuthenticating else { return }
        hasEntered = true
        generation &+= 1
        let requestGeneration = generation
        let request = CameraAuthenticationAttempt()
        attempt = request
        isAuthenticating = true
        errorMessage = nil
        credentialErrorMessage = nil
        task = Task { [weak self] in
            await self?.authenticate(request, generation: requestGeneration)
        }
    }

    /// PiP may retain authentication and loaded credentials, but ordinary
    /// foreground media must still lose its lease while the app is backgrounded.
    func suspendStreams() {
        streamsSuspended = true
        revokeStreams()
    }

    func resumeStreams() {
        streamsSuspended = false
    }

    private func revokeStreams() {
        // Revoke synchronously, including subscriptions still being acquired.
        // Privacy locking never keeps the ordinary view-handoff grace period.
        let authorization = streamAuthorization
        authorization.invalidate()
        let arbiters = Array(streamArbiters.values)
        streamArbiters.removeAll()
        Task { for arbiter in arbiters { await arbiter.revoke(authorization) } }
    }

    func lock() {
        revokeStreams()
        generation &+= 1
        task?.cancel()
        task = nil
        attempt?.invalidate()
        attempt = nil
        hasEntered = false
        isAuthenticating = false
        isUnlocked = false
        unlockedCredentials = nil
        credentialPresence = nil
        credentialErrorMessage = nil
        errorMessage = nil
    }

    /// Explicit S3-padlock retry. Camera access is already authorized and must
    /// not be revoked by a Keychain failure or cancelled credential prompt.
    func unlockCredentials() async throws {
        guard isUnlocked else { throw CameraAccessError.sessionClosed }
        guard !isAuthenticating else { throw CameraAccessError.authenticationInProgress }
        generation &+= 1
        let requestGeneration = generation
        let request = CameraAuthenticationAttempt()
        attempt = request
        isAuthenticating = true
        credentialErrorMessage = nil
        defer {
            request.invalidate()
            if generation == requestGeneration {
                attempt = nil
                isAuthenticating = false
            }
        }
        do {
            try await withTaskCancellationHandler {
                try await authenticator.authenticate(using: request)
                try requireCurrent(requestGeneration)
                let bundle = try await credentials.load(using: request)
                try requireCurrent(requestGeneration)
                unlockedCredentials = bundle
            } onCancel: {
                request.invalidate()
            }
        } catch {
            if generation == requestGeneration { credentialErrorMessage = Self.safeCredentialMessage(error) }
            throw (error as? CameraAccessError) ?? CameraAccessError.authenticationUnavailable
        }
    }

    /// Called only from explicit S3 setup. All newly saved credentials require
    /// biometrics even if this device entered the optional camera page unlocked.
    func saveCredentials(_ bundle: CameraS3Credentials) async throws {
        guard isUnlocked else { throw CameraAccessError.sessionClosed }
        guard !isAuthenticating else { throw CameraAccessError.authenticationInProgress }
        generation &+= 1
        let requestGeneration = generation
        let request = CameraAuthenticationAttempt()
        attempt = request
        isAuthenticating = true
        credentialErrorMessage = nil
        defer {
            request.invalidate()
            if generation == requestGeneration {
                attempt = nil
                isAuthenticating = false
            }
        }
        do {
            try await withTaskCancellationHandler {
                try await authenticator.authenticate(using: request)
                try requireCurrent(requestGeneration)
                try await credentials.save(bundle, using: request)
                try requireCurrent(requestGeneration)
                unlockedCredentials = bundle
                credentialPresence = .biometricProtected
            } onCancel: {
                request.invalidate()
            }
        } catch {
            if generation == requestGeneration { credentialErrorMessage = Self.safeCredentialMessage(error) }
            throw (error as? CameraAccessError) ?? CameraAccessError.authenticationUnavailable
        }
    }

    private func authenticate(_ request: CameraAuthenticationAttempt, generation requestGeneration: UInt64) async {
        defer {
            request.invalidate()
            if generation == requestGeneration {
                attempt = nil
                isAuthenticating = false
                task = nil
            }
        }
        do {
            let presence: CameraS3CredentialPresence?
            var inspectionError: Error?
            do {
                presence = try await credentials.inspect()
            } catch {
                // Inspection trouble is not evidence that credentials are
                // absent, and must not prevent the independent UI lock prompt.
                presence = nil
                inspectionError = error
            }
            try requireCurrent(requestGeneration)
            credentialPresence = presence
            credentialErrorMessage = inspectionError.map(Self.safeCredentialMessage)
            // Only the standalone viewing gate is optional in the simulator.
            // Unknown/present credentials follow the normal authentication path;
            // credential save/retry never use this exemption or an unlocked context.
            if environment == .simulator, presence == .missing {
                isUnlocked = true
                return
            }
            var authenticated = false
            do {
                try await authenticator.authenticate(using: request)
                authenticated = true
            } catch CameraAccessError.biometryNotAvailable {
                // The optional UI lock permits local camera viewing when the
                // OS says biometry is unavailable, regardless of S3 state.
                // This NEVER authorizes a protected/unknown credential read.
                try requireCurrent(requestGeneration)
                if presence != .missing {
                    credentialErrorMessage = "Biometric authentication is unavailable. S3 access remains locked."
                }
            }
            try requireCurrent(requestGeneration)
            if presence != .missing && (authenticated || presence == .unprotected) {
                do {
                    let bundle = try await credentials.load(using: request)
                    try requireCurrent(requestGeneration)
                    unlockedCredentials = bundle
                    credentialErrorMessage = nil
                } catch {
                    try requireCurrent(requestGeneration)
                    // The successful biometric prompt also satisfies the UI
                    // lock. Do not ask twice or lock out local/live playback.
                    credentialErrorMessage = Self.safeCredentialMessage(error)
                }
            }
            try requireCurrent(requestGeneration)
            isUnlocked = true
        } catch {
            guard generation == requestGeneration else { return }
            errorMessage = Self.safeMessage(error)
        }
    }

    private func requireCurrent(_ requestGeneration: UInt64) throws {
        guard generation == requestGeneration, !Task.isCancelled else {
            throw CameraAccessError.sessionClosed
        }
    }

    private static func safeMessage(_ error: Error) -> String {
        // Errors from dependencies may contain data supplied by a server or
        // credentials. Only our closed set of sanitized messages reaches UI.
        (error as? CameraAccessError)?.errorDescription
            ?? CameraAccessError.authenticationUnavailable.errorDescription!
    }

    private static func safeCredentialMessage(_ error: Error) -> String {
        (error as? CameraAccessError)?.errorDescription
            ?? "Saved S3 credentials could not be unlocked. Camera viewing is still available."
    }
}
