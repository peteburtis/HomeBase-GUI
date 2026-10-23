import Foundation

/// Launch-only fixture for testing native PiP through iPhone Mirroring, where
/// completing Face ID forces a lock/reconnect. Never enabled in release builds,
/// and never backed by the real Keychain, even if the phone has S3 credentials.
@MainActor
enum CameraPiPTestFixture {
    static let environmentVariable = "HOMEBASE_CAMERA_PIP_TEST_FIXTURE"

    static func isEnabled(environment: [String: String]) -> Bool {
#if DEBUG
        environment[environmentVariable] == "1"
#else
        false
#endif
    }

    static func makeAccessSession(environment: [String: String] = ProcessInfo.processInfo.environment) -> CameraAccessSession {
#if DEBUG
        if isEnabled(environment: environment) {
            return CameraAccessSession(credentials: NoCredentials(),
                authenticator: NoBiometry(), environment: .device)
        }
#endif
        return CameraAccessSession()
    }

#if DEBUG
    private struct NoBiometry: CameraBiometricAuthenticating {
        func authenticate(using attempt: CameraAuthenticationAttempt) async throws {
            // The existing optional camera-only gate permits this outcome.
            // Explicit S3 authentication still fails: no authenticated context
            // is manufactured or handed to a credential store.
            throw CameraAccessError.biometryNotAvailable
        }
    }

    private struct NoCredentials: CameraS3CredentialStoring {
        func inspect() async throws -> CameraS3CredentialPresence { .missing }
        func load(using attempt: CameraAuthenticationAttempt) async throws -> CameraS3Credentials {
            throw CameraAccessError.authenticationUnavailable
        }
        func save(_ credentials: CameraS3Credentials, using attempt: CameraAuthenticationAttempt) async throws {
            throw CameraAccessError.authenticationUnavailable
        }
    }
#endif
}
