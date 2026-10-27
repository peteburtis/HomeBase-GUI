import CryptoKit
import Foundation
import HomeBaseProtocol
import Security
import XCTest
@testable import HomeBase_GUI

nonisolated private final class MemoryIdentityPersistence: HomeBaseIdentityPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UUID: Data] = [:]
    var rejectWrites = false
    func load(serverID: UUID) throws -> Data? { lock.withLock { records[serverID] } }
    func save(_ data: Data, serverID: UUID) throws {
        try lock.withLock {
            if rejectWrites { throw HomeBaseAuthenticationError.keychain(errSecInteractionNotAllowed) }
            records[serverID] = data
        }
    }
    func delete(serverID: UUID) throws { _ = lock.withLock { records.removeValue(forKey: serverID) } }
}

private actor AuthenticationPeer {
    let fingerprint: Data
    var binding: HBChannelBinding
    let controllerID = UUID()
    let userID = UUID()
    var publicKey: Data?
    var enrollmentID: UUID?
    var lastBegin: HBProtocolEnvelope?
    var challenge: HBAuthChallenge?
    var enrollments = 0
    var failFirstEnrollmentResult = false
    var changeController = false

    init(fingerprint: Data, binding: HBChannelBinding) { self.fingerprint = fingerprint; self.binding = binding }
    func loseNextEnrollmentResult() { failFirstEnrollmentResult = true }
    func replaceController() { changeController = true }
    func useBinding(_ value: HBChannelBinding) { binding = value }

    func exchange(_ request: HBProtocolEnvelope) throws -> HBProtocolEnvelope {
        if request.operation == HBAuthProtocol.enrollBeginOperation || request.operation == HBAuthProtocol.beginOperation {
            if request.operation == HBAuthProtocol.enrollBeginOperation {
                let payload = try request.decodedPayload(as: HBAuthEnrollBeginRequest.self)
                try payload.validate()
                let key = try HBBase64URL.decode(payload.publicKey, expectedByteCount: 65)
                if let publicKey, let enrollmentID {
                    guard key == publicKey, payload.enrollmentID == enrollmentID else { throw HomeBaseAuthenticationError.invalidIdentity }
                } else { publicKey = key; enrollmentID = payload.enrollmentID }
            } else {
                let payload = try request.decodedPayload(as: HBAuthBeginRequest.self)
                guard payload.userID == userID else { throw HomeBaseAuthenticationError.invalidIdentity }
            }
            lastBegin = request
            let value = HBAuthChallenge(serverNonce: HBBase64URL.encode(try HBAuthP256.randomBytes()),
                controllerID: changeController ? UUID() : controllerID, userID: userID)
            challenge = value
            return try .response(to: request, body: .success(value))
        }
        guard let begin = lastBegin, let challenge, let publicKey else { throw HomeBaseAuthenticationError.invalidResponse }
        let proof = try request.decodedPayload(as: HBAuthProofRequest.self)
        guard proof.challengeID == challenge.challengeID else { throw HomeBaseAuthenticationError.invalidResponse }
        let transcript: Data
        if request.operation == HBAuthProtocol.enrollProveOperation {
            transcript = try HBAuthTranscript.enrollment(challenge: challenge,
                request: begin.decodedPayload(as: HBAuthEnrollBeginRequest.self), serverFingerprint: fingerprint,
                binding: binding, clientID: begin.clientID, beginRequestID: begin.requestID)
        } else {
            transcript = try HBAuthTranscript.authentication(challenge: challenge,
                request: begin.decodedPayload(as: HBAuthBeginRequest.self), serverFingerprint: fingerprint,
                binding: binding, clientID: begin.clientID, beginRequestID: begin.requestID, publicKey: publicKey)
        }
        try HBAuthP256.verify(signature: HBBase64URL.decode(proof.signature, expectedByteCount: 64),
                             message: transcript, publicKey: publicKey)
        lastBegin = nil; self.challenge = nil
        if request.operation == HBAuthProtocol.enrollProveOperation {
            enrollments = 1
            if failFirstEnrollmentResult {
                failFirstEnrollmentResult = false
                throw URLError(.networkConnectionLost)
            }
        }
        return try .response(to: request, body: .success(HBAuthResult(userID: userID,
            userDescription: "Test iPad", authorizationLevel: 2)))
    }
}

final class HomeBaseAuthenticationTests: XCTestCase {
    private func invitation() throws -> HomeBasePairingInvitation {
        .init(endpoint: try XCTUnwrap(HomeBaseEndpoint(host: "192.168.1.2", port: 10503,
            serverFingerprint: Data(repeating: 7, count: 32))),
              creationToken: HBBase64URL.encode(Data(repeating: 9, count: 32)))
    }

    func testKeychainIdentityUsesAfterFirstUnlockDeviceOnlyAndAtomicUpdate() throws {
        let id = UUID(), persistence = HomeBaseKeychainIdentityPersistence()
        defer { try? persistence.delete(serverID: id) }
        try persistence.save(Data("pending".utf8), serverID: id)
        try persistence.save(Data("enrolled".utf8), serverID: id)
        XCTAssertEqual(try persistence.load(serverID: id), Data("enrolled".utf8))
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: persistence.service,
            kSecAttrAccount as String: id.uuidString.lowercased(),
            kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &value), errSecSuccess)
        let attributes = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testPairingURLRequiresCanonicalFingerprintAndSingleUseToken() throws {
        let fp = HBBase64URL.encode(Data(repeating: 7, count: 32))
        let token = HBBase64URL.encode(Data(repeating: 9, count: 32))
        let valid = "homebasews://192.168.1.2:10503/#fp=\(fp)&token=\(token)"
        let parsed = try XCTUnwrap(HomeBasePairingCode.invitation(from: valid))
        XCTAssertEqual(parsed, try invitation())
        XCTAssertEqual(parsed.endpoint.webSocketURL?.absoluteString, "wss://192.168.1.2:10503/")
        XCTAssertNil(HomeBasePairingCode.invitation(from: "homebasews://192.168.1.2:10503/"))
        XCTAssertNil(HomeBasePairingCode.invitation(from: valid + "&token=\(token)"))
        XCTAssertNil(HomeBasePairingCode.invitation(from: valid.replacingOccurrences(of: fp, with: fp + "=")))
        XCTAssertNil(HomeBasePairingCode.invitation(from: valid.replacingOccurrences(of: "/#", with: "/?token=secret#")))
        XCTAssertNil(HomeBasePairingCode.invitation(from: valid.replacingOccurrences(of: "192.168.1.2", with: "user:password@192.168.1.2")))
        XCTAssertNil(HomeBasePairingCode.invitation(from: valid.replacingOccurrences(of: "#fp", with: "other#fp")))
    }

    func testEnrollmentPersistsKeyBeforeSendingAndErasesConsumedToken() async throws {
        let persistence = MemoryIdentityPersistence(), id = UUID()
        let store = HomeBaseAuthenticationStore(persistence: persistence, useSecureEnclave: false)
        let invitation = try invitation()
        try await store.prepare(serverID: id, invitation: invitation)
        let pending = try XCTUnwrap(persistence.load(serverID: id))
        let record = try JSONDecoder().decode(HomeBaseIdentityRecord.self, from: pending)
        XCTAssertEqual(record.creationToken, invitation.creationToken)
        XCTAssertEqual(record.pendingEndpoint, invitation.endpoint)
        XCTAssertNil(record.userID)
        let binding = try HBChannelBinding(kind: .tlsExporter, value: Data(repeating: 5, count: 32))
        let peer = AuthenticationPeer(fingerprint: invitation.endpoint.serverFingerprint!, binding: binding)
        let result = try await HomeBaseClientAuthenticator.authenticate(serverID: id, binding: binding, store: store) {
            XCTAssertNotNil(try persistence.load(serverID: id))
            return try await peer.exchange($0)
        }
        let identity = try await store.identity(serverID: id)
        XCTAssertEqual(identity.userID, result.userID)
        XCTAssertEqual(identity.publicKey, record.publicKey)
        XCTAssertEqual(identity.userDescription, "Test iPad")
        let finishedRecord = try await store.record(serverID: id)
        let finished = try XCTUnwrap(finishedRecord)
        XCTAssertNil(finished.creationToken)
        XCTAssertNil(finished.pendingEndpoint)
        XCTAssertEqual(finished.authorizationLevel, 2)
        _ = try await HomeBaseClientAuthenticator.authenticate(serverID: id, binding: binding, store: store) {
            try await peer.exchange($0)
        }
    }

    func testLostEnrollmentReplyRetainsSameKeyAndEnrollmentID() async throws {
        let persistence = MemoryIdentityPersistence(), id = UUID()
        let store = HomeBaseAuthenticationStore(persistence: persistence, useSecureEnclave: false)
        let invitation = try invitation()
        try await store.prepare(serverID: id, invitation: invitation)
        let initialRecord = try await store.record(serverID: id)
        let initial = try XCTUnwrap(initialRecord)
        let binding = try HBChannelBinding(kind: .tlsExporter, value: Data(repeating: 4, count: 32))
        let peer = AuthenticationPeer(fingerprint: invitation.endpoint.serverFingerprint!, binding: binding)
        await peer.loseNextEnrollmentResult()
        do {
            _ = try await HomeBaseClientAuthenticator.authenticate(serverID: id, binding: binding, store: store) { try await peer.exchange($0) }
            XCTFail("A lost response must leave enrollment pending")
        } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        let relaunchedStore = HomeBaseAuthenticationStore(persistence: persistence, useSecureEnclave: false)
        try await relaunchedStore.prepare(serverID: id, invitation: invitation)
        let retryRecord = try await relaunchedStore.record(serverID: id)
        let retry = try XCTUnwrap(retryRecord)
        XCTAssertEqual(retry.publicKey, initial.publicKey)
        XCTAssertEqual(retry.enrollmentID, initial.enrollmentID)
        _ = try await HomeBaseClientAuthenticator.authenticate(serverID: id, binding: binding, store: relaunchedStore) { try await peer.exchange($0) }
        let count = await peer.enrollments
        XCTAssertEqual(count, 1)
    }

    func testProofCannotBeRelayedOntoAnotherTLSConnection() async throws {
        let id = UUID(), store = HomeBaseAuthenticationStore(persistence: MemoryIdentityPersistence(), useSecureEnclave: false)
        let invitation = try invitation()
        try await store.prepare(serverID: id, invitation: invitation)
        let actualBinding = try HBChannelBinding(kind: .tlsExporter, value: Data(repeating: 1, count: 32))
        let otherBinding = try HBChannelBinding(kind: .tlsExporter, value: Data(repeating: 2, count: 32))
        let peer = AuthenticationPeer(fingerprint: invitation.endpoint.serverFingerprint!, binding: otherBinding)
        do {
            _ = try await HomeBaseClientAuthenticator.authenticate(serverID: id, binding: actualBinding, store: store) { try await peer.exchange($0) }
            XCTFail("A signature from another TLS connection must fail")
        } catch { XCTAssertEqual(error as? HBAuthenticationError, .invalidSignature) }
        let pending = try await store.record(serverID: id)
        XCTAssertNil(pending?.userID)
    }

    func testIdentityPersistenceFailureDoesNotCreatePendingCredentials() async throws {
        let persistence = MemoryIdentityPersistence(), id = UUID()
        persistence.rejectWrites = true
        let store = HomeBaseAuthenticationStore(persistence: persistence, useSecureEnclave: false)
        do {
            try await store.prepare(serverID: id, invitation: invitation())
            XCTFail("Key persistence must succeed before enrolling")
        } catch {}
        XCTAssertNil(try persistence.load(serverID: id))
    }

    func testPendingEnrollmentNeverSendsInvitationOverBluetooth() async throws {
        let id = UUID(), store = HomeBaseAuthenticationStore(persistence: MemoryIdentityPersistence(), useSecureEnclave: false)
        try await store.prepare(serverID: id, invitation: invitation())
        let binding = try HBChannelBinding(kind: .noiseHandshake, value: Data(repeating: 3, count: 32))
        do {
            _ = try await HomeBaseClientAuthenticator.authenticate(serverID: id, binding: binding, store: store) { _ in
                XCTFail("A pending invitation is restricted to pinned TLS enrollment")
                throw HomeBaseAuthenticationError.invalidResponse
            }
            XCTFail("Expected rejection before sending")
        } catch HomeBaseAuthenticationError.invalidIdentity { }
    }

    func testEnrolledIdentityAuthenticatesOnNoiseWithoutInvitation() async throws {
        let id = UUID(), store = HomeBaseAuthenticationStore(persistence: MemoryIdentityPersistence(), useSecureEnclave: false)
        let invitation = try invitation()
        try await store.prepare(serverID: id, invitation: invitation)
        let tls = try HBChannelBinding(kind: .tlsExporter, value: Data(repeating: 4, count: 32))
        let peer = AuthenticationPeer(fingerprint: invitation.endpoint.serverFingerprint!, binding: tls)
        let enrolled = try await HomeBaseClientAuthenticator.authenticate(serverID: id, binding: tls, store: store) { try await peer.exchange($0) }
        let noise = try HBChannelBinding(kind: .noiseHandshake, value: Data(repeating: 6, count: 32))
        await peer.useBinding(noise)
        let result = try await HomeBaseClientAuthenticator.authenticate(serverID: id, binding: noise, store: store) { request in
            XCTAssertTrue([HBAuthProtocol.beginOperation, HBAuthProtocol.proveOperation].contains(request.operation))
            return try await peer.exchange(request)
        }
        XCTAssertEqual(result.userID, enrolled.userID)
    }

    func testLoginRejectsChangedControllerIdentityBeforeProof() async throws {
        let id = UUID(), store = HomeBaseAuthenticationStore(persistence: MemoryIdentityPersistence(), useSecureEnclave: false)
        let invitation = try invitation()
        try await store.prepare(serverID: id, invitation: invitation)
        let binding = try HBChannelBinding(kind: .tlsExporter, value: Data(repeating: 5, count: 32))
        let peer = AuthenticationPeer(fingerprint: invitation.endpoint.serverFingerprint!, binding: binding)
        let enrolled = try await HomeBaseClientAuthenticator.authenticate(serverID: id, binding: binding, store: store) { try await peer.exchange($0) }
        await peer.replaceController()
        do {
            _ = try await HomeBaseClientAuthenticator.authenticate(serverID: id, binding: binding, store: store) { request in
                XCTAssertEqual(request.operation, HBAuthProtocol.beginOperation, "Must reject substituted controller before proof")
                return try await peer.exchange(request)
            }
            XCTFail("A saved controller identity must not change")
        } catch HomeBaseAuthenticationError.invalidResponse { }
        let identity = try await store.identity(serverID: id)
        XCTAssertEqual(identity.userID, enrolled.userID)
    }

    @MainActor
    func testConcurrentPairingURLsShareOnePendingIdentity() async throws {
        let suite = "HomeBaseAuthenticationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identities = HomeBaseAuthenticationStore(persistence: MemoryIdentityPersistence(), useSecureEnclave: false)
        let servers = PairedServerStore(defaults: defaults, didRemoveServer: { _ in }, authenticationStore: identities)
        let invitation = try invitation()
        async let first = servers.add(invitation)
        async let second = servers.add(invitation)
        let pair = try await (first, second)
        XCTAssertEqual(pair.0.id, pair.1.id)
        XCTAssertEqual(servers.servers.count, 1)
        let record = try await identities.record(serverID: pair.0.id)
        XCTAssertEqual(record?.pendingEndpoint, invitation.endpoint)
        let savedDefaults = try XCTUnwrap(defaults.data(forKey: "pairedServers"))
        XCTAssertFalse(String(decoding: savedDefaults, as: UTF8.self).contains(invitation.creationToken))
    }
}
