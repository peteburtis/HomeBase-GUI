import XCTest
import Security
import LocalAuthentication
@testable import HomeBase_GUI

@MainActor
final class CameraS3CredentialsTests: XCTestCase {
    func testNoninteractiveKeychainResponseClassification() throws {
        XCTAssertEqual(try CameraKeychainCredentialStore.presence(status: errSecInteractionNotAllowed, attributes: nil), .authenticationRequired)
        XCTAssertEqual(try CameraKeychainCredentialStore.presence(status: errSecItemNotFound, attributes: nil), .missing)
        XCTAssertEqual(try CameraKeychainCredentialStore.presence(status: errSecSuccess,
            attributes: [kSecAttrGeneric as String: CameraKeychainCredentialStore.biometricMarker]), .biometricProtected)
        XCTAssertThrowsError(try CameraKeychainCredentialStore.presence(status: errSecAuthFailed, attributes: nil))
        XCTAssertThrowsError(try CameraKeychainCredentialStore.presence(status: errSecNotAvailable, attributes: nil))
        XCTAssertThrowsError(try CameraKeychainCredentialStore.presence(status: errSecSuccess, attributes: nil))
    }

    /// An isolated simulator-only item exercises the real Keychain attribute
    /// query, without touching production credentials or presenting auth UI.
    func testIsolatedBiometricItemInspectionNeverReportsMissingOrNeedsPrompt() async throws {
#if targetEnvironment(simulator)
        let service = "io.pjb.HomeBase-GUI.tests.camera-s3.\(UUID().uuidString)"
        let account = "metadata-only-fixture"
        let store = CameraKeychainCredentialStore(service: service, account: account)
        let attempt = CameraAuthenticationAttempt()
        attempt.context.interactionNotAllowed = true
        let deletion: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: attempt.context,
        ]
        defer {
            let status = SecItemDelete(deletion as CFDictionary)
            XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound,
                "Could not clean isolated test Keychain item: \(status)")
            attempt.invalidate()
        }
        let initialPresence = try await store.inspect()
        XCTAssertEqual(initialPresence, .missing)
        do {
            try await store.save(CameraS3Credentials(destinationID: "test", accessKeyID: "DUMMY", secretAccessKey: "DUMMY", encryptionPassword: nil), using: attempt)
        } catch CameraAccessError.keychain(let status) where [errSecNotAvailable, errSecAuthFailed, errSecInteractionNotAllowed].contains(status) {
            throw XCTSkip("This simulator cannot provision a biometric item without interaction (\(status)).")
        }
        let savedPresence = try await store.inspect()
        XCTAssertTrue([.biometricProtected, .authenticationRequired].contains(savedPresence))

        var query = deletion
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        XCTAssertTrue([errSecSuccess, errSecInteractionNotAllowed].contains(status))
        if status == errSecSuccess {
            let attributes = try XCTUnwrap(result as? [String: Any])
            XCTAssertNil(attributes[kSecValueData as String])
            XCTAssertNotNil(attributes[kSecAttrAccessControl as String])
            XCTAssertEqual(attributes[kSecAttrGeneric as String] as? Data, CameraKeychainCredentialStore.biometricMarker)
        }
#else
        throw XCTSkip("Real Keychain fixture is simulator-only; deterministic policy tests run on every platform.")
#endif
    }
}
