import XCTest
import Security
import LocalAuthentication
@testable import HomeBase_GUI

@MainActor
final class CameraAccessSessionTests: XCTestCase {
    func testCameraLockSynchronouslyRevokesStreamsAndReentryGetsFreshAuthorization() async throws {
        let fixture = Fixture()
        let arbiter = CameraStreamArbiter { _, _ in throw CameraStreamError.ended }
        XCTAssertThrowsError(try fixture.session.authorizeStreams(arbiter))
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        let first = try fixture.session.authorizeStreams(arbiter)
        XCTAssertTrue(first.isValid)
        fixture.session.lock()
        XCTAssertFalse(first.isValid, "No async teardown window permits new frames/acquisitions")
        XCTAssertThrowsError(try fixture.session.authorizeStreams(arbiter))
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        let second = try fixture.session.authorizeStreams(arbiter)
        XCTAssertTrue(second.isValid)
        XCTAssertFalse(first === second)
        fixture.session.lock()
        await arbiter.shutdown()
    }

    func testMissingCredentialsAuthenticateWithoutKeychainDataRead() async {
        let fixture = Fixture()
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        XCTAssertTrue(fixture.session.isUnlocked)
        XCTAssertEqual(fixture.store.inspections, 1)
        XCTAssertEqual(fixture.authenticator.attempts.count, 1)
        XCTAssertTrue(fixture.store.loads.isEmpty)
        XCTAssertNil(fixture.session.unlockedCredentials)
    }

    func testProtectedCredentialsReuseAuthenticatedContextForKeychainRead() async {
        let fixture = Fixture(presence: .biometricProtected)
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        XCTAssertTrue(fixture.session.isUnlocked)
        XCTAssertEqual(fixture.session.unlockedCredentials, fixture.store.bundle)
        XCTAssertEqual(fixture.store.loads.count, 1)
        XCTAssertTrue(fixture.store.loads.first === fixture.authenticator.attempts.first)
    }

    func testNotAvailableAllowsCameraPageButNeverReadsProtectedCredentials() async {
        for presence in [CameraS3CredentialPresence.missing, .unprotected, .biometricProtected, .authenticationRequired] {
            let fixture = Fixture(presence: presence)
            fixture.authenticator.failure = .biometryNotAvailable
            fixture.session.enter()
            await waitUntil { !fixture.session.isAuthenticating }
            XCTAssertTrue(fixture.session.isUnlocked)
            XCTAssertEqual(fixture.store.loads.count, presence == .unprotected ? 1 : 0)
            XCTAssertNil(fixture.session.errorMessage)
            if presence == .biometricProtected || presence == .authenticationRequired {
                XCTAssertNil(fixture.session.unlockedCredentials)
                XCTAssertNotNil(fixture.session.credentialErrorMessage)
                XCTAssertTrue(fixture.session.canRetrySavedCredentials)
            }
        }
    }

    func testCancellationFailureEnrollmentAndLockoutNeverPermitOptionalEntry() async {
        for error in [CameraAccessError.authenticationCancelled, .authenticationFailed,
                      .biometryNotEnrolled, .biometryLockout, .authenticationUnavailable] {
            for presence in [CameraS3CredentialPresence.missing, .unprotected, .biometricProtected, .authenticationRequired] {
                let fixture = Fixture(presence: presence)
                fixture.authenticator.failure = error
                fixture.session.enter()
                await waitUntil { !fixture.session.isAuthenticating }
                XCTAssertFalse(fixture.session.isUnlocked, "\(error), \(presence)")
                XCTAssertTrue(fixture.store.loads.isEmpty)
                XCTAssertEqual(fixture.authenticator.attempts.count, 1, "Never start a second prompt automatically")
                XCTAssertNotNil(fixture.session.errorMessage)
            }
        }
    }

    func testInteractionNotAllowedPreflightReachesAuthenticationAndReadsExistingCredentials() async throws {
        // Reproduce the physical-device response that the simulator's real
        // Keychain fixture did not produce. Exercise the actual classifier.
        let presence = try CameraKeychainCredentialStore.presence(status: errSecInteractionNotAllowed, attributes: nil)
        let fixture = Fixture(presence: presence)
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        XCTAssertEqual(presence, .authenticationRequired)
        XCTAssertTrue(fixture.session.isUnlocked)
        XCTAssertEqual(fixture.session.unlockedCredentials, fixture.store.bundle)
        XCTAssertEqual(fixture.authenticator.attempts.count, 1)
        XCTAssertEqual(fixture.store.loads.count, 1)
        XCTAssertTrue(fixture.store.loads.first === fixture.authenticator.attempts.first)
        XCTAssertFalse(try XCTUnwrap(fixture.store.loads.first).context.interactionNotAllowed)
        XCTAssertNil(fixture.session.errorMessage)
        XCTAssertNil(fixture.session.credentialErrorMessage)
        XCTAssertTrue(fixture.store.saved.isEmpty, "The existing credential is read, never replaced")
    }

    func testInspectionFailureStillRequiresUIAuthenticationAndKeepsS3Separate() async {
        let fixture = Fixture()
        fixture.store.inspectionError = CameraAccessError.keychain(errSecNotAvailable)
        fixture.store.loadError = CameraAccessError.keychain(errSecNotAvailable)
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        XCTAssertTrue(fixture.session.isUnlocked)
        XCTAssertEqual(fixture.authenticator.attempts.count, 1)
        XCTAssertEqual(fixture.store.loads.count, 1)
        XCTAssertNil(fixture.session.unlockedCredentials)
        XCTAssertNil(fixture.session.errorMessage)
        XCTAssertNotNil(fixture.session.credentialErrorMessage)
        XCTAssertTrue(fixture.session.canRetrySavedCredentials)

        fixture.session.lock()
        fixture.authenticator.failure = .authenticationCancelled
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        XCTAssertFalse(fixture.session.isUnlocked)
        XCTAssertEqual(fixture.authenticator.attempts.count, 2)
        XCTAssertEqual(fixture.store.loads.count, 1, "A cancelled UI gate never attempts a credential read")
    }

    func testProtectedReadFailureRetainsSuccessfulUIAuthenticationWithoutAnotherPrompt() async {
        let fixture = Fixture(presence: .biometricProtected)
        fixture.store.loadError = CameraAccessError.keychain(errSecItemNotFound)
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        XCTAssertTrue(fixture.session.isUnlocked)
        XCTAssertNil(fixture.session.unlockedCredentials)
        XCTAssertEqual(fixture.authenticator.attempts.count, 1)
        XCTAssertNil(fixture.session.errorMessage)
        XCTAssertNotNil(fixture.session.credentialErrorMessage)
        XCTAssertFalse(fixture.session.credentialErrorMessage?.contains("Cameras remain locked") ?? true)
        XCTAssertTrue(fixture.session.canRetrySavedCredentials)
    }

    func testSavedCredentialRetryUsesBiometricsWithoutRelockingCamerasOrWritingAnything() async throws {
        let fixture = Fixture(presence: .authenticationRequired)
        fixture.store.loadError = CameraAccessError.keychain(errSecInteractionNotAllowed)
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        XCTAssertTrue(fixture.session.canRetrySavedCredentials)
        fixture.store.loadError = nil
        try await fixture.session.unlockCredentials()
        XCTAssertTrue(fixture.session.isUnlocked)
        XCTAssertEqual(fixture.session.unlockedCredentials, fixture.store.bundle)
        XCTAssertFalse(fixture.session.canRetrySavedCredentials)
        XCTAssertNil(fixture.session.credentialErrorMessage)
        XCTAssertEqual(fixture.authenticator.attempts.count, 2)
        XCTAssertTrue(fixture.store.loads.last === fixture.authenticator.attempts.last)
        XCTAssertFalse(fixture.authenticator.attempts[0] === fixture.authenticator.attempts[1])
        XCTAssertTrue(fixture.store.saved.isEmpty)
    }

    func testCancelledOrUnavailableCredentialRetryDoesNotRevokeCameraAccessOrReadSecrets() async {
        let fixture = Fixture(presence: .biometricProtected)
        fixture.authenticator.failure = .biometryNotAvailable
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        for error in [CameraAccessError.biometryNotAvailable, .authenticationCancelled, .authenticationFailed] {
            fixture.authenticator.failure = error
            do { try await fixture.session.unlockCredentials(); XCTFail("S3 must still require biometrics") }
            catch { XCTAssertEqual(error as? CameraAccessError, fixture.authenticator.failure) }
            XCTAssertTrue(fixture.session.isUnlocked)
            XCTAssertNil(fixture.session.unlockedCredentials)
            XCTAssertTrue(fixture.store.loads.isEmpty)
            XCTAssertNil(fixture.session.errorMessage)
            XCTAssertNotNil(fixture.session.credentialErrorMessage)
        }
    }

    func testLateCredentialReadCannotUnlockAfterBackgroundOrSectionExit() async {
        let fixture = Fixture(presence: .authenticationRequired)
        fixture.store.suspendsLoad = true
        fixture.session.enter()
        await waitUntil { fixture.store.pendingLoads.count == 1 }
        fixture.session.lock()
        fixture.store.finishLoad()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(fixture.session.isUnlocked)
        XCTAssertNil(fixture.session.unlockedCredentials)
        XCTAssertNil(fixture.session.credentialErrorMessage)
        XCTAssertNil(fixture.session.errorMessage)
    }

    func testLockDuringExplicitCredentialRetryDoesNotRepublishSecrets() async {
        let fixture = Fixture(presence: .authenticationRequired)
        fixture.authenticator.failure = .biometryNotAvailable
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        fixture.authenticator.failure = nil
        fixture.store.suspendsLoad = true
        let retry = Task { try await fixture.session.unlockCredentials() }
        await waitUntil { fixture.store.pendingLoads.count == 1 }
        fixture.session.lock()
        fixture.store.finishLoad()
        do { try await retry.value; XCTFail("Stale retry must not succeed") }
        catch { XCTAssertEqual(error as? CameraAccessError, .sessionClosed) }
        XCTAssertFalse(fixture.session.isUnlocked)
        XCTAssertNil(fixture.session.unlockedCredentials)
        XCTAssertNil(fixture.session.credentialErrorMessage)
    }

    func testConcurrentCredentialRetriesDoNotOverlapAuthentication() async throws {
        let fixture = Fixture(presence: .authenticationRequired)
        fixture.authenticator.failure = .biometryNotAvailable
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        fixture.authenticator.failure = nil
        fixture.authenticator.suspends = true
        let retry = Task { try await fixture.session.unlockCredentials() }
        await waitUntil { fixture.authenticator.pending.count == 1 }
        do { try await fixture.session.unlockCredentials(); XCTFail("Duplicate prompt") }
        catch { XCTAssertEqual(error as? CameraAccessError, .authenticationInProgress) }
        XCTAssertEqual(fixture.authenticator.attempts.count, 2)
        fixture.authenticator.finishNext()
        try await retry.value
        XCTAssertEqual(fixture.store.loads.count, 1)
    }

    func testUnavailableUIWithUnknownKeychainStateNeverAttemptsCredentialRead() async {
        let fixture = Fixture()
        fixture.store.inspectionError = CameraAccessError.keychain(errSecNotAvailable)
        fixture.authenticator.failure = .biometryNotAvailable
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        XCTAssertTrue(fixture.session.isUnlocked)
        XCTAssertTrue(fixture.session.canRetrySavedCredentials)
        XCTAssertNil(fixture.session.unlockedCredentials)
        XCTAssertTrue(fixture.store.loads.isEmpty)
        XCTAssertEqual(fixture.authenticator.attempts.count, 1)
    }

    func testCancellingCredentialRetryCannotPublishLateReadButKeepsUIUnlocked() async {
        let fixture = Fixture(presence: .authenticationRequired)
        fixture.authenticator.failure = .biometryNotAvailable
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        fixture.authenticator.failure = nil
        fixture.store.suspendsLoad = true
        let retry = Task { try await fixture.session.unlockCredentials() }
        await waitUntil { fixture.store.pendingLoads.count == 1 }
        retry.cancel()
        fixture.store.finishLoad()
        do { try await retry.value; XCTFail("Cancelled editor must not publish credentials") }
        catch { XCTAssertEqual(error as? CameraAccessError, .sessionClosed) }
        XCTAssertTrue(fixture.session.isUnlocked)
        XCTAssertNil(fixture.session.unlockedCredentials)
        XCTAssertFalse(fixture.session.isAuthenticating)
    }

    func testRepeatedEntryDoesNotRepeatCancelledPromptButUnlockDoes() async {
        let fixture = Fixture()
        fixture.authenticator.failure = .authenticationCancelled
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        fixture.session.enter()
        XCTAssertEqual(fixture.authenticator.attempts.count, 1)
        fixture.authenticator.failure = nil
        fixture.session.unlock()
        await waitUntil { !fixture.session.isAuthenticating }
        XCTAssertTrue(fixture.session.isUnlocked)
        XCTAssertEqual(fixture.authenticator.attempts.count, 2)
    }

    func testRepeatedUnlockNeverOverlapsPrompts() async {
        let fixture = Fixture()
        fixture.authenticator.suspends = true
        fixture.session.enter()
        await waitUntil { fixture.authenticator.pending.count == 1 }
        fixture.session.enter()
        fixture.session.unlock()
        fixture.session.unlock()
        XCTAssertEqual(fixture.authenticator.attempts.count, 1)
        fixture.authenticator.finishNext()
        await waitUntil { !fixture.session.isAuthenticating }
        XCTAssertTrue(fixture.session.isUnlocked)
    }

    func testLockIgnoresLateAuthenticationAndReleasesCredentials() async {
        let fixture = Fixture(presence: .biometricProtected)
        fixture.authenticator.suspends = true
        fixture.session.enter()
        await waitUntil { fixture.authenticator.pending.count == 1 }
        fixture.session.lock()
        fixture.authenticator.finishNext()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(fixture.session.isUnlocked)
        XCTAssertFalse(fixture.session.isAuthenticating)
        XCTAssertTrue(fixture.store.loads.isEmpty)
        XCTAssertNil(fixture.session.errorMessage)
        fixture.authenticator.suspends = false
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        XCTAssertNotNil(fixture.session.unlockedCredentials)
        fixture.session.lock()
        XCTAssertNil(fixture.session.unlockedCredentials)
        XCTAssertFalse(fixture.session.isUnlocked)
    }

    func testOldPromptCannotAffectNewSession() async {
        let fixture = Fixture()
        fixture.authenticator.suspends = true
        fixture.session.enter()
        await waitUntil { fixture.authenticator.pending.count == 1 }
        fixture.session.lock()
        fixture.session.enter()
        await waitUntil { fixture.authenticator.pending.count == 2 }
        fixture.authenticator.finishNext()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(fixture.session.isUnlocked)
        XCTAssertTrue(fixture.session.isAuthenticating)
        fixture.authenticator.finishNext(error: .authenticationCancelled)
        await waitUntil { !fixture.session.isAuthenticating }
        XCTAssertFalse(fixture.session.isUnlocked)
    }

    func testFreshEntryReevaluatesOSInsteadOfRememberingConsent() async {
        let fixture = Fixture()
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        XCTAssertTrue(fixture.session.isUnlocked)
        fixture.session.lock()
        fixture.authenticator.failure = .biometryNotAvailable
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        XCTAssertTrue(fixture.session.isUnlocked)
        XCTAssertEqual(fixture.authenticator.attempts.count, 2)
        XCTAssertFalse(fixture.authenticator.attempts[0] === fixture.authenticator.attempts[1])
    }

    func testSavingAlwaysRequiresBiometricsAndSharesContextWithKeychain() async throws {
        let fixture = Fixture()
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        let bundle = fixture.store.bundle
        try await fixture.session.saveCredentials(bundle)
        XCTAssertEqual(fixture.store.saved, [bundle])
        XCTAssertEqual(fixture.session.unlockedCredentials, bundle)
        XCTAssertTrue(fixture.store.saveAttempts.first === fixture.authenticator.attempts.last)
        XCTAssertTrue(fixture.session.isUnlocked)
        XCTAssertFalse(fixture.session.isAuthenticating)
    }

    func testOptionalUnavailableEntryCannotSaveUnprotectedCredentials() async {
        let fixture = Fixture()
        fixture.authenticator.failure = .biometryNotAvailable
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        XCTAssertTrue(fixture.session.isUnlocked)
        do {
            try await fixture.session.saveCredentials(fixture.store.bundle)
            XCTFail("Credential setup must require successful biometrics")
        } catch { XCTAssertEqual(error as? CameraAccessError, .biometryNotAvailable) }
        XCTAssertTrue(fixture.store.saved.isEmpty)
        XCTAssertNil(fixture.session.unlockedCredentials)
    }

    func testLockWhileSavingDoesNotReopenSessionEvenIfPublicationCompleted() async {
        let fixture = Fixture()
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        fixture.store.suspendsSave = true
        let save = Task { try await fixture.session.saveCredentials(fixture.store.bundle) }
        await waitUntil { fixture.store.pendingSave != nil }
        fixture.session.lock()
        fixture.store.finishSave()
        do { try await save.value; XCTFail("Closed session must not report unlocked") }
        catch { XCTAssertEqual(error as? CameraAccessError, .sessionClosed) }
        XCTAssertEqual(fixture.store.saved.count, 1, "An already-published protected item remains safely in Keychain")
        XCTAssertNil(fixture.session.unlockedCredentials)
        XCTAssertFalse(fixture.session.isUnlocked)
    }

    func testUnknownErrorMessageCannotLeakCredentialData() async {
        let fixture = Fixture()
        fixture.store.inspectionError = NSError(domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "SECRET-ACCESS-KEY"])
        fixture.store.loadError = fixture.store.inspectionError
        fixture.session.enter()
        await waitUntil { !fixture.session.isAuthenticating }
        XCTAssertTrue(fixture.session.isUnlocked)
        XCTAssertNil(fixture.session.errorMessage)
        XCTAssertFalse(fixture.session.credentialErrorMessage?.contains("SECRET") ?? true)
    }

    func testUnknownMetadataAndAnyACLRequireBiometricsForCredentials() {
        XCTAssertEqual(CameraKeychainCredentialStore.presence(for: [:]), .biometricProtected)
        XCTAssertEqual(CameraKeychainCredentialStore.presence(for: [kSecAttrGeneric as String: Data("future-format".utf8)]), .biometricProtected)
        let legacy: [String: Any] = [kSecAttrGeneric as String: CameraKeychainCredentialStore.unprotectedMarker]
        XCTAssertEqual(CameraKeychainCredentialStore.presence(for: legacy), .unprotected)
        var protected = legacy
        protected[kSecAttrAccessControl as String] = "opaque ACL"
        XCTAssertEqual(CameraKeychainCredentialStore.presence(for: protected), .biometricProtected)
    }

    func testAuthenticationErrorsAreExplicitAndOnlyNotAvailableAllowsOptionalEntry() {
        let mapping: [(LAError.Code, CameraAccessError)] = [
            (.biometryNotAvailable, .biometryNotAvailable),
            (.biometryNotEnrolled, .biometryNotEnrolled),
            (.biometryLockout, .biometryLockout),
            (.userCancel, .authenticationCancelled), (.systemCancel, .authenticationCancelled),
            (.appCancel, .authenticationCancelled), (.authenticationFailed, .authenticationFailed),
            (.passcodeNotSet, .authenticationUnavailable), (.userFallback, .authenticationUnavailable),
        ]
        for (code, expected) in mapping {
            XCTAssertEqual(CameraAccessError.authentication(LAError(code)), expected)
        }
        XCTAssertEqual(CameraAccessError.authentication(nil), .authenticationUnavailable)
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for deterministic authentication task", file: file, line: line)
    }
}

@MainActor
private struct Fixture {
    let store: TestCredentialStore
    let authenticator: TestBiometricAuthenticator
    let session: CameraAccessSession

    init(presence: CameraS3CredentialPresence = .missing) {
        store = TestCredentialStore(presence: presence)
        authenticator = TestBiometricAuthenticator()
        session = CameraAccessSession(credentials: store, authenticator: authenticator)
    }
}

@MainActor
private final class TestCredentialStore: CameraS3CredentialStoring {
    let presence: CameraS3CredentialPresence
    let bundle = CameraS3Credentials(destinationID: "test-server/store/bucket/prefix", accessKeyID: "TEST-ID", secretAccessKey: "TEST-SECRET", encryptionPassword: "TEST-PASSWORD")
    var inspections = 0
    var inspectionError: Error?
    var loadError: Error?
    var loads: [CameraAuthenticationAttempt] = []
    var suspendsLoad = false
    var pendingLoads: [CheckedContinuation<Void, Never>] = []
    var saved: [CameraS3Credentials] = []
    var saveAttempts: [CameraAuthenticationAttempt] = []
    var suspendsSave = false
    var pendingSave: CheckedContinuation<Void, Never>?

    init(presence: CameraS3CredentialPresence) { self.presence = presence }
    func inspect() async throws -> CameraS3CredentialPresence {
        inspections += 1
        if let inspectionError { throw inspectionError }
        return presence
    }
    func load(using attempt: CameraAuthenticationAttempt) async throws -> CameraS3Credentials {
        loads.append(attempt)
        if suspendsLoad { await withCheckedContinuation { pendingLoads.append($0) } }
        if let loadError { throw loadError }
        return bundle
    }
    func finishLoad() { pendingLoads.removeFirst().resume() }
    func save(_ credentials: CameraS3Credentials, using attempt: CameraAuthenticationAttempt) async throws {
        saved.append(credentials)
        saveAttempts.append(attempt)
        if suspendsSave { await withCheckedContinuation { pendingSave = $0 } }
    }
    func finishSave() { pendingSave?.resume(); pendingSave = nil }
}

@MainActor
private final class TestBiometricAuthenticator: CameraBiometricAuthenticating {
    var failure: CameraAccessError?
    var attempts: [CameraAuthenticationAttempt] = []
    var suspends = false
    var pending: [CheckedContinuation<Void, Error>] = []

    func authenticate(using attempt: CameraAuthenticationAttempt) async throws {
        attempts.append(attempt)
        if suspends { try await withCheckedThrowingContinuation { pending.append($0) } }
        else if let failure { throw failure }
    }
    func finishNext(error: CameraAccessError? = nil) {
        let continuation = pending.removeFirst()
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
}
