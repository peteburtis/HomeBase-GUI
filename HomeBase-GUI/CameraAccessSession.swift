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
        case .authenticationCancelled: "Cameras remain locked. Select Unlock to try again."
        case .authenticationFailed: "Authentication did not succeed. Select Unlock to try again."
        case .authenticationUnavailable: "Authentication could not be completed. Cameras remain locked."
        case .keychain(let status): "Saved S3 credentials could not be accessed (Keychain \(status)). Cameras remain locked."
        case .invalidSavedCredentials: "Saved S3 credentials could not be read. Cameras remain locked."
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

/// Ephemeral camera-section state. There is deliberately no persisted consent
/// preference: the current OS result is authoritative on every fresh entry.
@MainActor
final class CameraAccessSession: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var unlockedCredentials: CameraS3Credentials?

    private let credentials: any CameraS3CredentialStoring
    private let authenticator: any CameraBiometricAuthenticating
    private var hasEntered = false
    private var generation: UInt64 = 0
    private var attempt: CameraAuthenticationAttempt?
    private var task: Task<Void, Never>?

    init(
        credentials: (any CameraS3CredentialStoring)? = nil,
        authenticator: (any CameraBiometricAuthenticating)? = nil
    ) {
        self.credentials = credentials ?? CameraKeychainCredentialStore()
        self.authenticator = authenticator ?? CameraSystemBiometricAuthenticator()
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
        task = Task { [weak self] in
            await self?.authenticate(request, generation: requestGeneration)
        }
    }

    func lock() {
        generation &+= 1
        task?.cancel()
        task = nil
        attempt?.invalidate()
        attempt = nil
        hasEntered = false
        isAuthenticating = false
        isUnlocked = false
        unlockedCredentials = nil
        errorMessage = nil
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
        errorMessage = nil
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
            } onCancel: {
                request.invalidate()
            }
        } catch {
            if generation == requestGeneration { errorMessage = Self.safeMessage(error) }
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
            let presence = try await credentials.inspect()
            try requireCurrent(requestGeneration)
            do {
                try await authenticator.authenticate(using: request)
            } catch CameraAccessError.biometryNotAvailable where presence != .biometricProtected {
                // This intentionally covers missing hardware AND permission
                // denial. It never applies to protected credentials.
            }
            try requireCurrent(requestGeneration)
            let bundle: CameraS3Credentials?
            if presence == .missing { bundle = nil }
            else { bundle = try await credentials.load(using: request) }
            try requireCurrent(requestGeneration)
            unlockedCredentials = bundle
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
}
