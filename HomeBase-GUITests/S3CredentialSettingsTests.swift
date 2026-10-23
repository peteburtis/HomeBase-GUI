import HomeBaseProtocol
import XCTest
#if os(iOS)
import SwiftUI
import UIKit
#endif
@testable import HomeBase_GUI

@MainActor
final class S3CredentialSettingsTests: XCTestCase {
    func testOpeningSettingsOnlyInspectsAttributes() async {
        let fixture = SettingsFixture()
        await fixture.model.refresh()
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.presence, .missing)
        XCTAssertEqual(fixture.store.inspections, 2)
        XCTAssertEqual(fixture.store.loads, 0)
        XCTAssertEqual(fixture.store.saves, 0)
        XCTAssertEqual(fixture.store.deletions, 0)
        XCTAssertTrue(fixture.auth.attempts.isEmpty)
    }

    func testAddRequiresBiometricsAndReusesContextWithoutUnlockingCameras() async {
        let fixture = SettingsFixture()
        let session = CameraAccessSession(credentials: fixture.store, authenticator: fixture.auth)
        let success = await fixture.model.add(fixture.store.bundle) {
            session.credentialsDidChange(presence: .biometricProtected)
        }
        XCTAssertTrue(success)
        XCTAssertEqual(fixture.store.added, [fixture.store.bundle])
        XCTAssertEqual(fixture.auth.attempts.count, 1)
        XCTAssertTrue(fixture.store.addAttempt === fixture.auth.attempts.first)
        XCTAssertEqual(fixture.model.presence, .biometricProtected)
        XCTAssertFalse(session.isUnlocked)
        XCTAssertNil(session.unlockedCredentials)
        XCTAssertEqual(fixture.store.loads, 0)
        XCTAssertEqual(fixture.store.saves, 0, "Settings cannot replace a credential")
    }

    func testExistingCredentialsCannotBeEditedOrReplaced() async {
        for presence in [CameraS3CredentialPresence.biometricProtected, .unprotected, .authenticationRequired] {
            let fixture = SettingsFixture()
            fixture.store.presence = presence
            let success = await fixture.model.add(fixture.store.bundle) { XCTFail("No change") }
            XCTAssertFalse(success)
            XCTAssertEqual(fixture.model.errorMessage, CameraAccessError.credentialsAlreadySaved.errorDescription)
            XCTAssertTrue(fixture.auth.attempts.isEmpty)
            XCTAssertTrue(fixture.store.added.isEmpty)
            XCTAssertEqual(fixture.store.saves, 0)
        }
    }

    func testInspectionFailureCannotBeTreatedAsMissingOrExposeErrorPayload() async {
        let fixture = SettingsFixture()
        fixture.store.failure = NSError(domain: "fixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "SECRET-ACCESS-KEY"])
        let success = await fixture.model.add(fixture.store.bundle) { XCTFail("No change") }
        XCTAssertFalse(success)
        XCTAssertFalse(fixture.model.errorMessage?.contains("SECRET") ?? true)
        XCTAssertTrue(fixture.auth.attempts.isEmpty)
        XCTAssertTrue(fixture.store.added.isEmpty)
    }

    func testFailedAuthenticationDoesNotSave() async {
        let fixture = SettingsFixture()
        fixture.auth.failure = .authenticationCancelled
        let success = await fixture.model.add(fixture.store.bundle) { XCTFail("No change") }
        XCTAssertFalse(success)
        XCTAssertTrue(fixture.store.added.isEmpty)
        XCTAssertEqual(fixture.model.presence, .missing)
    }

    func testCancellationDuringAuthenticationPreventsLateSave() async {
        let fixture = SettingsFixture()
        fixture.auth.suspends = true
        let task = Task { await fixture.model.add(fixture.store.bundle) { XCTFail("No change") } }
        await waitUntil { fixture.auth.pending != nil }
        fixture.model.cancel()
        fixture.auth.finish()
        let success = await task.value
        XCTAssertFalse(success)
        XCTAssertTrue(fixture.store.added.isEmpty)
        XCTAssertNil(fixture.model.errorMessage)
        XCTAssertFalse(fixture.model.isBusy)
    }

    func testConfirmedDeleteDoesNotReadOrAuthenticateCredentials() async {
        let fixture = SettingsFixture()
        fixture.store.presence = .biometricProtected
        await fixture.model.refresh()
        XCTAssertEqual(fixture.store.deletions, 0)
        var changes = 0
        await fixture.model.delete { changes += 1 }
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(fixture.store.deletions, 1)
        XCTAssertEqual(fixture.model.presence, .missing)
        XCTAssertEqual(fixture.store.loads, 0)
        XCTAssertTrue(fixture.auth.attempts.isEmpty)
        let success = await fixture.model.add(fixture.store.bundle) { changes += 1 }
        XCTAssertTrue(success, "Delete allows a new set to be added")
        XCTAssertEqual(changes, 2)
    }

    func testFailedDeleteKeepsSavedPresenceAndDoesNotInvalidateReaders() async {
        let fixture = SettingsFixture()
        fixture.store.presence = .biometricProtected
        await fixture.model.refresh()
        fixture.store.failure = CameraAccessError.keychain(-1)
        await fixture.model.delete { XCTFail("No change") }
        XCTAssertEqual(fixture.model.presence, .biometricProtected)
        XCTAssertNotNil(fixture.model.errorMessage)
    }

    func testCommittedAddStillInvalidatesReadersIfDismissalRacesSave() async {
        let fixture = SettingsFixture()
        fixture.store.suspendsAdd = true
        var changes = 0
        let task = Task { await fixture.model.add(fixture.store.bundle) { changes += 1 } }
        await waitUntil { fixture.store.pendingAdd != nil }
        fixture.model.cancel()
        fixture.store.pendingAdd?.resume()
        let success = await task.value
        XCTAssertFalse(success)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(fixture.model.presence, .biometricProtected)
    }

    func testDestinationsDeduplicateAcrossCamerasButKeepExactStoreBinding() throws {
        let store = HBCameraPlaybackMetadata.S3Store(id: UUID().uuidString, name: "Archive",
            bucket: "recordings", region: "us-east-1", prefix: "nvr/", expectedOwner: nil, clientEncryptionFormat: nil)
        let other = HBCameraPlaybackMetadata.S3Store(id: store.id, name: store.name,
            bucket: "other-recordings", region: store.region, prefix: store.prefix,
            expectedOwner: nil, clientEncryptionFormat: nil)
        func camera(_ name: String, store: HBCameraPlaybackMetadata.S3Store) throws -> HBTopologyDeviceDescriptor {
            var playback = HBCameraPlaybackMetadata(nvrInstanceID: UUID().uuidString,
                cameraID: UUID().uuidString, stores: [], s3Store: store)
            playback.available = false
            return .init(identifier: name, addressableName: name, displayName: name,
                metadata: [HBDeviceMetadataKeys.cameraPlayback: try HBJSONValue(encoding: playback)])
        }
        let destinations = try S3CredentialSettingsModel.destinations(in: [
            camera("front", store: store), camera("back", store: store), camera("other", store: other),
            .init(identifier: "light", addressableName: "light", displayName: "Light")
        ])
        XCTAssertEqual(Set(destinations.map(\.id)), Set([CameraS3Destination(store: store).id, CameraS3Destination(store: other).id]))
        XCTAssertEqual(destinations.count, 2)
    }

#if os(iOS)
    func testNativeSettingsAndAddFormPresentation() async throws {
        let fixture = SettingsFixture()
        let destination = CameraS3Destination(store: .init(id: UUID().uuidString,
            name: "Recording archive", bucket: "example-recordings", region: "us-west-2",
            prefix: "hbnvr/example/", expectedOwner: nil, clientEncryptionFormat: nil))
        let host = UIHostingController(rootView: AnyView(
            S3CredentialSettingsView(destinations: [destination], serverName: "homebase.local", model: fixture.model)
                .environment(\.scenePhase, .active).preferredColorScheme(.light)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        attachSnapshot(host, name: "Home settings with store policy and add credentials")
        XCTAssertEqual(fixture.store.loads, 0)
        XCTAssertEqual(fixture.store.deletions, 0)
        XCTAssertTrue(fixture.auth.attempts.isEmpty)

        host.rootView = AnyView(S3SettingsAddCredentialsView(model: fixture.model,
            destination: destination, onChange: { XCTFail("Rendering must not save") })
            .environment(\.scenePhase, .active).preferredColorScheme(.light))
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        func fields(in view: UIView) -> [UITextField] {
            (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        }
        let inputs = fields(in: host.view)
        XCTAssertEqual(inputs.count, 3)
        XCTAssertEqual(inputs.filter(\.isSecureTextEntry).count, 2)
        XCTAssertTrue(inputs.allSatisfy { ($0.text ?? "").isEmpty })
        XCTAssertTrue(fixture.store.added.isEmpty)
        attachSnapshot(host, name: "Settings add credentials with blank secure fields")
    }

    private func attachSnapshot(_ host: UIHostingController<AnyView>, name: String) {
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
#endif

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Operation did not reach expected suspension")
    }
}

@MainActor
private struct SettingsFixture {
    let store = SettingsCredentialStore()
    let auth = SettingsAuthenticator()
    let model: S3CredentialSettingsModel
    init() { model = S3CredentialSettingsModel(store: store, authenticator: auth) }
}

@MainActor
private final class SettingsCredentialStore: CameraS3CredentialStoring {
    let bundle = CameraS3Credentials(destinationID: "fixture-store", accessKeyID: "DUMMY", secretAccessKey: "DUMMY", encryptionPassword: nil)
    var presence: CameraS3CredentialPresence = .missing
    var inspections = 0, loads = 0, saves = 0, deletions = 0
    var added: [CameraS3Credentials] = []
    var addAttempt: CameraAuthenticationAttempt?
    var failure: Error?
    var suspendsAdd = false
    var pendingAdd: CheckedContinuation<Void, Never>?
    func inspect() async throws -> CameraS3CredentialPresence {
        inspections += 1
        if let failure { throw failure }
        return presence
    }
    func load(using attempt: CameraAuthenticationAttempt) async throws -> CameraS3Credentials { loads += 1; return bundle }
    func save(_ credentials: CameraS3Credentials, using attempt: CameraAuthenticationAttempt) async throws { saves += 1 }
    func add(_ credentials: CameraS3Credentials, using attempt: CameraAuthenticationAttempt) async throws {
        guard presence == .missing else { throw CameraAccessError.credentialsAlreadySaved }
        added.append(credentials); addAttempt = attempt; presence = .biometricProtected
        if suspendsAdd { await withCheckedContinuation { pendingAdd = $0 } }
    }
    func delete() async throws {
        if let failure { throw failure }
        deletions += 1; presence = .missing
    }
}

@MainActor
private final class SettingsAuthenticator: CameraBiometricAuthenticating {
    var attempts: [CameraAuthenticationAttempt] = []
    var failure: CameraAccessError?
    var suspends = false
    var pending: CheckedContinuation<Void, Never>?
    func authenticate(using attempt: CameraAuthenticationAttempt) async throws {
        attempts.append(attempt)
        if suspends { await withCheckedContinuation { pending = $0 } }
        if let failure { throw failure }
    }
    func finish() { pending?.resume(); pending = nil }
}
