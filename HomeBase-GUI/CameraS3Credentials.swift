import Foundation
import LocalAuthentication
import Security

/// This value is deliberately not part of server metadata, defaults, or logs.
/// Only the credential store serializes it, directly into one Keychain item.
nonisolated struct CameraS3Credentials: Codable, Equatable, Sendable {
    let destinationID: String
    let accessKeyID: String
    let secretAccessKey: String
    let encryptionPassword: String?
}

nonisolated enum CameraS3CredentialPresence: Equatable, Sendable {
    case missing
    case biometricProtected
    case unprotected
    /// Noninteractive inspection could not determine the item's attributes.
    /// Retry the real read after authentication; never infer absence from this.
    case authenticationRequired
}

/// LAContext is designed for a request to cross the Keychain/LA boundary. Keep
/// one context per attempt so the Keychain read reuses that attempt's biometric
/// authentication rather than presenting a second prompt.
nonisolated final class CameraAuthenticationAttempt: @unchecked Sendable {
    let context = LAContext()

    init() {
        context.interactionNotAllowed = false
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
    }

    func invalidate() { context.invalidate() }
}

@MainActor
protocol CameraS3CredentialStoring {
    func inspect() async throws -> CameraS3CredentialPresence
    func load(using attempt: CameraAuthenticationAttempt) async throws -> CameraS3Credentials
    func save(_ credentials: CameraS3Credentials, using attempt: CameraAuthenticationAttempt) async throws
}

/// Exactly one client-wide credential item, on this device only. No AWS SDK
/// provider, environment credentials, or syncable credential copy is used.
@MainActor
final class CameraKeychainCredentialStore: CameraS3CredentialStoring {
    private nonisolated let service: String
    private nonisolated let account: String
    nonisolated static let biometricMarker = Data("camera-s3.biometric.v1".utf8)
    nonisolated static let unprotectedMarker = Data("camera-s3.unprotected.v1".utf8)

    init(service: String = "io.pjb.HomeBase-GUI.camera-s3", account: String = "playback-credentials") {
        self.service = service
        self.account = account
    }

    func inspect() async throws -> CameraS3CredentialPresence {
        try await Task.detached(priority: .userInitiated) {
            var query = self.baseQuery
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            // A physical device may require authentication even for this
            // attributes-only probe. Defer that requirement to the real read.
            let context = LAContext()
            context.interactionNotAllowed = true
            defer { context.invalidate() }
            query[kSecUseAuthenticationContext as String] = context
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return try Self.presence(status: status, attributes: result as? [String: Any])
        }.value
    }

    nonisolated static func presence(status: OSStatus, attributes: [String: Any]?) throws -> CameraS3CredentialPresence {
        if status == errSecItemNotFound { return .missing }
        if status == errSecInteractionNotAllowed { return .authenticationRequired }
        guard status == errSecSuccess else { throw CameraAccessError.keychain(status) }
        guard let attributes else { throw CameraAccessError.invalidSavedCredentials }
        return presence(for: attributes)
    }

    /// Unknown formats and ACLs always require biometrics for credential reads.
    /// An explicit legacy marker without an ACL is the only unprotected case;
    /// the current app never writes that format.
    nonisolated static func presence(for attributes: [String: Any]) -> CameraS3CredentialPresence {
        if attributes[kSecAttrGeneric as String] as? Data == unprotectedMarker,
           attributes[kSecAttrAccessControl as String] == nil {
            return .unprotected
        }
        return .biometricProtected
    }

    func load(using attempt: CameraAuthenticationAttempt) async throws -> CameraS3Credentials {
        try await Task.detached(priority: .userInitiated) {
            var query = self.baseQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecUseAuthenticationContext as String] = attempt.context
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess else { throw CameraAccessError.keychain(status) }
            guard let data = result as? Data,
                  let credentials = try? JSONDecoder().decode(CameraS3Credentials.self, from: data),
                  !credentials.destinationID.isEmpty,
                  !credentials.accessKeyID.isEmpty,
                  !credentials.secretAccessKey.isEmpty else {
                throw CameraAccessError.invalidSavedCredentials
            }
            return credentials
        }.value
    }

    func save(_ credentials: CameraS3Credentials, using attempt: CameraAuthenticationAttempt) async throws {
        guard !credentials.destinationID.isEmpty, !credentials.accessKeyID.isEmpty,
              !credentials.secretAccessKey.isEmpty else { throw CameraAccessError.invalidCredentials }
        try await Task.detached(priority: .userInitiated) {
            var error: Unmanaged<CFError>?
            guard let control = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryAny, &error
            ) else {
                // Do not interpolate Keychain error payloads or credential data.
                throw CameraAccessError.cannotProtectCredentials
            }
            let data = try JSONEncoder().encode(credentials)
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessControl as String: control,
                kSecAttrGeneric as String: Self.biometricMarker,
                kSecAttrLabel as String: "HomeBase S3 playback",
            ]
            var query = self.baseQuery
            query[kSecUseAuthenticationContext as String] = attempt.context
            var addition = query.merging(attributes) { _, new in new }
            addition[kSecAttrSynchronizable as String] = false
            let status = SecItemAdd(addition as CFDictionary, nil)
            if status == errSecDuplicateItem {
                // Updating in place preserves the old credential if the update
                // fails. Never delete it first to work around a Keychain error.
                var metadataQuery = query
                metadataQuery[kSecReturnAttributes as String] = true
                metadataQuery[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                let metadataStatus = SecItemCopyMatching(metadataQuery as CFDictionary, &result)
                guard metadataStatus == errSecSuccess else { throw CameraAccessError.keychain(metadataStatus) }
                guard let existing = result as? [String: Any],
                      existing[kSecAttrGeneric as String] as? Data == Self.biometricMarker,
                      existing[kSecAttrAccessControl as String] != nil else {
                    // We cannot atomically upgrade an unknown/legacy item's
                    // ACL with SecItemUpdate. Refuse rather than replacing it
                    // with data whose actual protection is uncertain.
                    throw CameraAccessError.cannotProtectCredentials
                }
                var replacement = attributes
                replacement.removeValue(forKey: kSecAttrAccessControl as String)
                let updateStatus = SecItemUpdate(query as CFDictionary, replacement as CFDictionary)
                guard updateStatus == errSecSuccess else { throw CameraAccessError.keychain(updateStatus) }
            } else if status != errSecSuccess {
                throw CameraAccessError.keychain(status)
            }
        }.value
    }

    private nonisolated var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
