import Foundation
import CryptoKit
import HomeBaseProtocol
import Security

nonisolated enum HomeBaseAuthenticationError: Error, LocalizedError {
    case invalidPairingURL, missingIdentity, invalidIdentity, invalidResponse, keychain(OSStatus), keyUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidPairingURL: "Enter the complete HomeBase pairing URL printed below its QR code."
        case .missingIdentity: "Pair this device with HomeBase to create its credentials."
        case .invalidIdentity: "The saved HomeBase identity cannot be used. Pair this device again."
        case .invalidResponse: "HomeBase authentication failed because the response did not match this connection."
        case .keychain: "HomeBase credentials could not be accessed securely. Unlock this device and try again."
        case .keyUnavailable: "The HomeBase signing key is unavailable. Unlock this device and try again."
        }
    }
}

nonisolated struct HomeBasePairingInvitation: Equatable, Sendable {
    let endpoint: HomeBaseEndpoint
    let creationToken: String
}

nonisolated struct HomeBaseClientIdentity: Equatable, Sendable {
    let userID: UUID
    let clientID: UUID
    let controllerID: UUID
    let serverFingerprint: Data
    let publicKey: Data
    let userDescription: String?
    let authorizationLevel: Int?
}

/// All sensitive state, including a pending single-use invitation, is committed
/// in one device-only Keychain item before enrollment sends its first request.
nonisolated struct HomeBaseIdentityRecord: Codable, Equatable, Sendable {
    enum KeyKind: String, Codable, Sendable { case secureEnclave, software }
    var version = 1
    let clientID: UUID
    let serverFingerprint: Data
    let publicKey: Data
    let privateKeyRepresentation: Data
    let keyKind: KeyKind
    let enrollmentID: UUID
    var pendingEndpoint: HomeBaseEndpoint?
    var creationToken: String?
    var userID: UUID?
    var controllerID: UUID?
    var userDescription: String?
    var authorizationLevel: Int?
}

nonisolated protocol HomeBaseIdentityPersisting: Sendable {
    func load(serverID: UUID) throws -> Data?
    func save(_ data: Data, serverID: UUID) throws
    func delete(serverID: UUID) throws
}

nonisolated struct HomeBaseKeychainIdentityPersistence: HomeBaseIdentityPersisting {
    let service = "io.pjb.HomeBase-GUI.user-identity.v1"
    private func query(_ serverID: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: serverID.uuidString.lowercased(),
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }
    func load(serverID: UUID) throws -> Data? {
        var query = query(serverID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw HomeBaseAuthenticationError.keychain(status) }
        return data
    }
    func save(_ data: Data, serverID: UUID) throws {
        let base = query(serverID)
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemAdd(base.merging(values) { _, value in value } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updated = SecItemUpdate(base as CFDictionary, values as CFDictionary)
            guard updated == errSecSuccess else { throw HomeBaseAuthenticationError.keychain(updated) }
        } else if status != errSecSuccess { throw HomeBaseAuthenticationError.keychain(status) }
    }
    func delete(serverID: UUID) throws {
        let status = SecItemDelete(query(serverID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HomeBaseAuthenticationError.keychain(status) }
    }
}

actor HomeBaseAuthenticationStore {
    static let shared = HomeBaseAuthenticationStore()
    private let persistence: any HomeBaseIdentityPersisting
    private let useSecureEnclave: Bool
    init(persistence: any HomeBaseIdentityPersisting = HomeBaseKeychainIdentityPersistence(),
         useSecureEnclave: Bool = SecureEnclave.isAvailable) {
        self.persistence = persistence
        self.useSecureEnclave = useSecureEnclave
    }

    func prepare(serverID: UUID, invitation: HomeBasePairingInvitation) throws {
        guard let fingerprint = invitation.endpoint.serverFingerprint, fingerprint.count == 32,
              (try? HBBase64URL.decode(invitation.creationToken, expectedByteCount: 32)) != nil else {
            throw HomeBaseAuthenticationError.invalidPairingURL
        }
        if let existing = try record(serverID: serverID) {
            guard existing.serverFingerprint == fingerprint,
                  existing.creationToken == invitation.creationToken || existing.userID != nil else {
                throw HomeBaseAuthenticationError.invalidIdentity
            }
            return
        }
        let representation: Data, publicKey: Data, kind: HomeBaseIdentityRecord.KeyKind
        if useSecureEnclave {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, [.privateKeyUsage], &error) else {
                throw HomeBaseAuthenticationError.keyUnavailable
            }
            let key: SecureEnclave.P256.Signing.PrivateKey
            do { key = try .init(accessControl: access) }
            catch { throw HomeBaseAuthenticationError.keyUnavailable }
            representation = key.dataRepresentation; publicKey = key.publicKey.x963Representation; kind = .secureEnclave
        } else {
            let key = P256.Signing.PrivateKey()
            representation = key.rawRepresentation; publicKey = key.publicKey.x963Representation; kind = .software
        }
        let value = HomeBaseIdentityRecord(clientID: serverID, serverFingerprint: fingerprint,
            publicKey: publicKey, privateKeyRepresentation: representation, keyKind: kind,
            enrollmentID: UUID(), pendingEndpoint: invitation.endpoint, creationToken: invitation.creationToken)
        try persistence.save(JSONEncoder().encode(value), serverID: serverID)
    }

    func record(serverID: UUID) throws -> HomeBaseIdentityRecord? {
        guard let data = try persistence.load(serverID: serverID) else { return nil }
        let value = try JSONDecoder().decode(HomeBaseIdentityRecord.self, from: data)
        guard value.version == 1, value.clientID == serverID, value.serverFingerprint.count == 32,
              value.publicKey.count == 65,
              ((value.userID != nil && value.controllerID != nil && value.creationToken == nil && value.pendingEndpoint == nil)
                || (value.userID == nil && value.controllerID == nil && value.creationToken != nil
                    && value.pendingEndpoint?.serverFingerprint == value.serverFingerprint)) else {
            throw HomeBaseAuthenticationError.invalidIdentity
        }
        return value
    }

    func identity(serverID: UUID) throws -> HomeBaseClientIdentity {
        guard let value = try record(serverID: serverID), let userID = value.userID,
              let controllerID = value.controllerID else { throw HomeBaseAuthenticationError.missingIdentity }
        return .init(userID: userID, clientID: value.clientID, controllerID: controllerID,
                     serverFingerprint: value.serverFingerprint, publicKey: value.publicKey,
                     userDescription: value.userDescription, authorizationLevel: value.authorizationLevel)
    }

    func sign(serverID: UUID, transcript: Data) throws -> Data {
        guard let value = try record(serverID: serverID) else { throw HomeBaseAuthenticationError.missingIdentity }
        switch value.keyKind {
        case .secureEnclave:
            do {
                return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: value.privateKeyRepresentation)
                    .signature(for: transcript).rawRepresentation
            } catch { throw HomeBaseAuthenticationError.keyUnavailable }
        case .software:
            return try P256.Signing.PrivateKey(rawRepresentation: value.privateKeyRepresentation)
                .signature(for: transcript).rawRepresentation
        }
    }

    func complete(serverID: UUID, challenge: HBAuthChallenge, result: HBAuthResult) throws {
        guard var record = try record(serverID: serverID), challenge.userID == result.userID,
              record.userID == nil || record.userID == result.userID,
              record.controllerID == nil || record.controllerID == challenge.controllerID else {
            throw HomeBaseAuthenticationError.invalidResponse
        }
        record.userID = result.userID; record.controllerID = challenge.controllerID
        record.userDescription = result.userDescription; record.authorizationLevel = result.authorizationLevel
        record.pendingEndpoint = nil
        record.creationToken = nil
        try persistence.save(JSONEncoder().encode(record), serverID: serverID)
    }
    func remove(serverID: UUID) throws { try persistence.delete(serverID: serverID) }
}

nonisolated enum HomeBaseClientAuthenticator {
    typealias Exchange = @Sendable (HBProtocolEnvelope) async throws -> HBProtocolEnvelope

    /// `binding` must be computed locally by the TLS/Noise transport. Nothing
    /// supplied by the peer may replace it, even if a peer's JSON contains one.
    static func authenticate(serverID: UUID, binding: HBChannelBinding,
                             store: HomeBaseAuthenticationStore = .shared,
                             exchange: Exchange) async throws -> HBAuthResult {
        try Task.checkCancellation()
        guard let record = try await store.record(serverID: serverID) else { throw HomeBaseAuthenticationError.missingIdentity }
        let nonce = HBBase64URL.encode(randomBytes())
        let begin: HBProtocolEnvelope
        let enrollment: HBAuthEnrollBeginRequest?
        let authentication: HBAuthBeginRequest?
        if let token = record.creationToken {
            guard binding.type == "tls-exporter" else { throw HomeBaseAuthenticationError.invalidIdentity }
            let request = HBAuthEnrollBeginRequest(enrollmentID: record.enrollmentID, creationToken: token,
                publicKey: HBBase64URL.encode(record.publicKey), clientNonce: nonce)
            enrollment = request; authentication = nil
            begin = try .request(operation: HBAuthProtocol.enrollBeginOperation, clientID: record.clientID, payload: request)
        } else if let userID = record.userID {
            let request = HBAuthBeginRequest(userID: userID, clientNonce: nonce)
            authentication = request; enrollment = nil
            begin = try .request(operation: HBAuthProtocol.beginOperation, clientID: record.clientID, payload: request)
        } else { throw HomeBaseAuthenticationError.invalidIdentity }
        let response = try await checkedExchange(begin, exchange: exchange)
        let challenge = try response.decodedPayload(as: HBProtocolResponse.self).decodedResult(as: HBAuthChallenge.self)
        try challenge.validate()
        guard record.controllerID == nil || record.controllerID == challenge.controllerID,
              record.userID == nil || record.userID == challenge.userID else { throw HomeBaseAuthenticationError.invalidResponse }
        let transcript: Data
        if let enrollment {
            transcript = try HBAuthTranscript.enrollment(challenge: challenge, request: enrollment,
                serverFingerprint: record.serverFingerprint, binding: binding, clientID: record.clientID,
                beginRequestID: begin.requestID)
        } else if let authentication {
            transcript = try HBAuthTranscript.authentication(challenge: challenge, request: authentication,
                serverFingerprint: record.serverFingerprint, binding: binding, clientID: record.clientID,
                beginRequestID: begin.requestID, publicKey: record.publicKey)
        } else { throw HomeBaseAuthenticationError.invalidIdentity }
        try Task.checkCancellation()
        let signature = try await store.sign(serverID: serverID, transcript: transcript)
        let proof = try HBProtocolEnvelope.request(
            operation: enrollment == nil ? HBAuthProtocol.proveOperation : HBAuthProtocol.enrollProveOperation,
            clientID: record.clientID,
            payload: HBAuthProofRequest(challengeID: challenge.challengeID, signature: HBBase64URL.encode(signature)))
        let completed = try await checkedExchange(proof, exchange: exchange)
        let result = try completed.decodedPayload(as: HBProtocolResponse.self).decodedResult(as: HBAuthResult.self)
        try result.validate()
        try Task.checkCancellation()
        try await store.complete(serverID: serverID, challenge: challenge, result: result)
        return result
    }

    private static func checkedExchange(_ request: HBProtocolEnvelope, exchange: Exchange) async throws -> HBProtocolEnvelope {
        try Task.checkCancellation()
        let result = try await exchange(request)
        try Task.checkCancellation()
        try result.validate()
        guard result.messageKind == .response, result.operation == request.operation,
              result.requestID == request.requestID, result.clientID == request.clientID,
              result.sessionID == nil, result.subscriptionID == nil, result.deliverySequence == nil else {
            throw HomeBaseAuthenticationError.invalidResponse
        }
        return result
    }
    private static func randomBytes() -> Data {
        // CryptoKit's random symmetric key uses the platform CSPRNG.
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}
