import Combine
import HomeBaseProtocol
import SwiftUI
import XCTest
#if os(iOS)
import UIKit
#endif
@testable import HomeBase_GUI

@MainActor
final class CameraAccessLifecycleTests: XCTestCase {
    func testUnlockRecoveryAppearsOnlyAfterFailureAndHidesDuringRetry() async {
        let auth = CameraPageTestAuthenticator(error: .authenticationCancelled)
        let session = CameraAccessSession(credentials: CameraPageTestCredentials(), authenticator: auth)
        func presentation() -> CameraAccessPresentation {
            .init(session: session, isAuthorized: session.isUnlocked, isUnlocked: session.isUnlocked,
                  isAuthenticating: session.isAuthenticating, errorMessage: session.errorMessage)
        }
        XCTAssertFalse(presentation().showsUnlockRecovery, "Initial entry is plain black")
        session.enter()
        XCTAssertFalse(presentation().showsUnlockRecovery, "No lock or retry while authenticating")
        await settle(session)
        XCTAssertTrue(presentation().showsUnlockRecovery, "Cancellation exposes recovery")
        auth.error = nil
        session.unlock()
        XCTAssertFalse(presentation().showsUnlockRecovery, "Retry immediately hides lock and Unlock")
        await settle(session)
        XCTAssertTrue(session.isUnlocked)
        XCTAssertFalse(presentation().showsUnlockRecovery)
        session.lock()
        XCTAssertFalse(presentation().showsUnlockRecovery, "A fresh locked session is not a failure")
    }

    func testTransientConcealmentAndStaleFailureNeverShowRecovery() {
        XCTAssertFalse(CameraAccessPresentation(session: nil, isAuthorized: true, isUnlocked: false,
            isAuthenticating: false, errorMessage: "Previous failure").showsUnlockRecovery)
        XCTAssertFalse(CameraAccessPresentation(session: nil, isAuthorized: false, isUnlocked: false,
            isAuthenticating: true, errorMessage: "Previous failure").showsUnlockRecovery)
    }

    func testRepeatedAppearanceAndAdditionalCameraOwnersDoNotRepeatCancelledPrompt() async {
        let auth = CameraPageTestAuthenticator(error: .authenticationCancelled)
        let session = CameraAccessSession(credentials: CameraPageTestCredentials(), authenticator: auth)
        let lifecycle = CameraAccessLifecycle(session: session)
        let page = UUID(), player = UUID()

        lifecycle.setActive(true, owner: page)
        await settle(session)
        XCTAssertEqual(auth.calls, 1)
        XCTAssertFalse(session.isUnlocked)
        lifecycle.setActive(true, owner: page)
        lifecycle.setActive(true, owner: player)
        lifecycle.setActive(false, owner: page)
        await Task.yield()
        XCTAssertEqual(auth.calls, 1)
        XCTAssertNotNil(session.errorMessage)

        session.unlock()
        await settle(session)
        XCTAssertEqual(auth.calls, 2, "Only an explicit Unlock retries within the same section session")
        lifecycle.setActive(false, owner: player)
        lifecycle.setActive(true, owner: page)
        await settle(session)
        XCTAssertEqual(auth.calls, 3, "Returning after actually leaving starts a new session")
    }

    func testInactiveAuthenticationPresentationDoesNotRelockButBackgroundDoes() async {
        let auth = CameraPageTestAuthenticator()
        let session = CameraAccessSession(credentials: CameraPageTestCredentials(), authenticator: auth)
        let lifecycle = CameraAccessLifecycle(session: session)
        lifecycle.setActive(true, owner: UUID())
        await settle(session)
        XCTAssertTrue(session.isUnlocked)
        lifecycle.scenePhaseChanged(.inactive)
        lifecycle.scenePhaseChanged(.active)
        XCTAssertTrue(session.isUnlocked)
        XCTAssertEqual(auth.calls, 1)

        lifecycle.scenePhaseChanged(.background)
        XCTAssertFalse(session.isUnlocked)
        lifecycle.scenePhaseChanged(.active)
        await settle(session)
        XCTAssertTrue(session.isUnlocked)
        XCTAssertEqual(auth.calls, 2)
    }

    func testLastCameraOwnerLeavingClearsSecretsButOneOwnerLeavingDoesNot() async {
        let credentials = CameraPageTestCredentials(presence: .biometricProtected)
        let session = CameraAccessSession(credentials: credentials, authenticator: CameraPageTestAuthenticator())
        let lifecycle = CameraAccessLifecycle(session: session)
        let first = UUID(), second = UUID()
        lifecycle.setActive(true, owner: first)
        lifecycle.setActive(true, owner: second)
        await settle(session)
        XCTAssertNotNil(session.unlockedCredentials)
        lifecycle.setActive(false, owner: first)
        XCTAssertTrue(session.isUnlocked)
        XCTAssertNotNil(session.unlockedCredentials)
        lifecycle.setActive(false, owner: second)
        XCTAssertFalse(session.isUnlocked)
        XCTAssertNil(session.unlockedCredentials)
    }

    func testNoCameraOwnerMeansNoForegroundPromptAndServerChangeResetsSession() async {
        let auth = CameraPageTestAuthenticator()
        let session = CameraAccessSession(credentials: CameraPageTestCredentials(), authenticator: auth)
        let lifecycle = CameraAccessLifecycle(session: session)
        lifecycle.scenePhaseChanged(.background)
        lifecycle.scenePhaseChanged(.active)
        await Task.yield()
        XCTAssertEqual(auth.calls, 0)

        lifecycle.setActive(true, owner: UUID())
        await settle(session)
        lifecycle.reset()
        XCTAssertFalse(session.isUnlocked)
        lifecycle.scenePhaseChanged(.background)
        lifecycle.scenePhaseChanged(.active)
        await Task.yield()
        XCTAssertEqual(auth.calls, 1)
    }

    func testMediaSuspensionUsesAuthorizationNotTransientInactivity() {
        for phase in [ScenePhase.active, .inactive, .background] {
            XCTAssertTrue(CameraLiveVideoLifecycle.isSuspended(in: phase, isStreamEnabled: false),
                "A locked fullscreen player must never keep its media connection running")
        }
        XCTAssertFalse(CameraLiveVideoLifecycle.isSuspended(in: .inactive, isStreamEnabled: true),
            "Showing Face ID over an authorized player only conceals it")
        XCTAssertEqual(
            CameraLiveVideoLifecycle.taskIdentity(retryID: 0, scenePhase: .active, isStreamEnabled: true),
            CameraLiveVideoLifecycle.taskIdentity(retryID: 0, scenePhase: .inactive, isStreamEnabled: true)
        )
        XCTAssertTrue(CameraLiveVideoLifecycle.isSuspended(in: .background, isStreamEnabled: true))
    }

#if os(iOS)
    func testCameraOnlyUnlockOffersSavedCredentialRetry() async throws {
        let auth = CameraPageTestAuthenticator(error: .biometryNotAvailable)
        let session = CameraAccessSession(
            credentials: CameraPageTestCredentials(presence: .biometricProtected), authenticator: auth)
        session.enter()
        await settle(session)
        XCTAssertTrue(session.isUnlocked)
        XCTAssertNil(session.unlockedCredentials)
        XCTAssertTrue(session.canRetrySavedCredentials)
        let destination = CameraS3Destination(store: .init(
            id: "8EC120A6-5FF1-49E2-83CF-F7C2BCFF8A31", name: "Recording archive",
            bucket: "example-recordings", region: "us-west-2", prefix: "hbnvr/example/"))
        let host = UIHostingController(rootView: AnyView(
            CameraS3CredentialsView(access: session, destination: destination)
                .environment(\.scenePhase, .active).preferredColorScheme(.dark)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.isHidden = false
        defer {
            host.rootView = AnyView(Color.clear)
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        attachSnapshot(host, name: "Camera viewing unlocked with saved S3 credentials retry")
        XCTAssertEqual(auth.calls, 1, "Opening the form must not automatically loop authentication")
        host.rootView = AnyView(Color.clear)
        host.view.layoutIfNeeded()
        window.isHidden = true
        window.rootViewController = nil
        try await Task.sleep(for: .milliseconds(200))
        withExtendedLifetime(session) { XCTAssertTrue(session.isUnlocked) }
        withExtendedLifetime(auth) { XCTAssertEqual(auth.calls, 1) }
    }

    func testLockedCameraChipsAndS3AccessNativePresentationSnapshots() async throws {
        let auth = CameraPageTestAuthenticator(error: .authenticationCancelled)
        let session = CameraAccessSession(credentials: CameraPageTestCredentials(), authenticator: auth)
        let client = HomeBaseWebSocketClient(endpoint: try XCTUnwrap(
            HomeBasePairingCode.endpoint(from: "homebasews://127.0.0.1:1")))
        let cameras = CameraVideoCatalog.cameras(in: [
            HBTopologyDeviceDescriptor(identifier: "front-camera", addressableName: "FrontCamera",
                displayName: "Front Camera", metadata: [CameraLiveVideoCapability.availableMetadataKey: true]),
            HBTopologyDeviceDescriptor(identifier: "garden-camera", addressableName: "GardenCamera",
                displayName: "Garden Camera", metadata: [CameraLiveVideoCapability.availableMetadataKey: true]),
        ])
        let host = UIHostingController(rootView: AnyView(
            VideoView(cameras: cameras, client: client)
                .environment(\.cameraAccessSession, session)
                .environment(\.scenePhase, .active)
                .preferredColorScheme(.light)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.isHidden = false
        defer {
            host.rootView = AnyView(Color.clear)
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(auth.calls, 0)
        attachSnapshot(host, name: "Initial camera chips are plain black without lock or Unlock")
        session.enter()
        await settle(session)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(session.isUnlocked)
        XCTAssertEqual(auth.calls, 1, "Rendering failed-auth chips must not prompt again")
        attachSnapshot(host, name: "Locked camera chips retain names and explicit Unlock")

        let destination = CameraS3Destination(store: .init(
            id: "8EC120A6-5FF1-49E2-83CF-F7C2BCFF8A31", name: "Recording archive",
            bucket: "example-recordings", region: "us-west-2", prefix: "hbnvr/example/",
            expectedOwner: nil, clientEncryptionFormat: "hbnvr-pbe-v1"))
        // Blank form, fake session, no save/Keychain/AWS operation. This test
        // only mounts the native editor and verifies secret fields are secure.
        host.rootView = AnyView(CameraS3CredentialsView(access: session, destination: destination)
            .environment(\.scenePhase, .active).preferredColorScheme(.dark))
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let fields = descendants(of: host.view).compactMap { $0 as? UITextField }
        XCTAssertEqual(fields.count, 3)
        XCTAssertEqual(fields.filter(\.isSecureTextEntry).count, 2)
        XCTAssertTrue(fields.allSatisfy { ($0.text ?? "").isEmpty }, "Credentials must never be prefilled")
        attachSnapshot(host, name: "S3 access native form with empty protected-secret fields")

        host.rootView = AnyView(NavigationStack {
            CameraS3IAMPolicyView(destination: destination)
        }.preferredColorScheme(.dark))
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        attachSnapshot(host, name: "Read-only IAM policy with copy and share actions")

        window.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
        host.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 60, bottom: 21, right: 60)
        host.rootView = AnyView(CameraS3PadlockTestFixture().preferredColorScheme(.dark))
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        attachSnapshot(host, name: "Missing video S3 padlock opposite history capsule")
        XCTAssertEqual(auth.calls, 1)
        host.rootView = AnyView(Color.clear)
        host.view.layoutIfNeeded()
        window.isHidden = true
        window.rootViewController = nil
        try await Task.sleep(for: .milliseconds(200))
        withExtendedLifetime(session) { XCTAssertFalse(session.isUnlocked) }
        withExtendedLifetime(auth) { XCTAssertEqual(auth.calls, 1) }
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

    private func descendants(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    func testLockedPreviewDoesNotConstructMediaAndInactiveOnlyConcealsExistingMedia() async throws {
        let state = CameraPreviewTestState()
        let host = UIHostingController(rootView: AnyView(CameraPreviewTestFixture(state: state)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 220)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.mediaAppearances, 0, "Locked chips must not instantiate their camera player")

        state.authorized = true
        state.visible = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.mediaAppearances, 1)
        state.visible = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.mediaDisappearances, 0, "The system's auth prompt must not tear down an authorized preview")
        state.authorized = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.mediaDisappearances, 1, "Relocking releases the media view")
        // Release SwiftUI's cached references while this MainActor test still
        // retains the state. UIKit's deferred destruction otherwise hits the
        // existing iOS 26.1 isolated-deinit runtime issue.
        host.rootView = AnyView(Color.clear)
        host.view.layoutIfNeeded()
        window.isHidden = true
        window.rootViewController = nil
        try await Task.sleep(for: .milliseconds(200))
        withExtendedLifetime(state) { XCTAssertEqual(state.mediaDisappearances, 1) }
    }
#endif

    private func settle(_ session: CameraAccessSession) async {
        for _ in 0..<100 where session.isAuthenticating {
            await Task.yield()
        }
        XCTAssertFalse(session.isAuthenticating)
    }
}

@MainActor
private final class CameraPageTestAuthenticator: CameraBiometricAuthenticating {
    var calls = 0
    var error: CameraAccessError?
    init(error: CameraAccessError? = nil) { self.error = error }
    func authenticate(using attempt: CameraAuthenticationAttempt) async throws {
        calls += 1
        if let error { throw error }
    }
}

@MainActor
private final class CameraPageTestCredentials: CameraS3CredentialStoring {
    let presence: CameraS3CredentialPresence
    init(presence: CameraS3CredentialPresence = .missing) { self.presence = presence }
    func inspect() async throws -> CameraS3CredentialPresence { presence }
    func load(using attempt: CameraAuthenticationAttempt) async throws -> CameraS3Credentials {
        .init(destinationID: "test", accessKeyID: "test-id", secretAccessKey: "test-secret", encryptionPassword: nil)
    }
    func save(_ credentials: CameraS3Credentials, using attempt: CameraAuthenticationAttempt) async throws {}
}

#if os(iOS)
@MainActor
private final class CameraPreviewTestState: ObservableObject {
    @Published var authorized = false
    @Published var visible = false
    var mediaAppearances = 0
    var mediaDisappearances = 0
}

private struct CameraPreviewTestFixture: View {
    @ObservedObject var state: CameraPreviewTestState
    var body: some View {
        CameraProtectedPreview(access: .init(session: nil, isAuthorized: state.authorized,
            isUnlocked: state.visible, isAuthenticating: false, errorMessage: nil)) {
            Color.red.aspectRatio(16 / 9, contentMode: .fit)
                .onAppear { state.mediaAppearances += 1 }
                .onDisappear { state.mediaDisappearances += 1 }
        }
    }
}

private struct CameraS3PadlockTestFixture: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Label("No recording at this time", systemImage: "video.slash")
                .foregroundStyle(.white)
            CameraPlayerPanelPlacement(panel: .off, timelineBounds: nil, leading: true) {
                CameraS3PadlockButton {}
            }
            CameraPlayerPanelPlacement(panel: .off, timelineBounds: nil) {
                CameraPlayerPanelPicker(selection: .constant(.off), availability: .init(
                    historyAvailable: true, ptzSupported: true, isLive: false, isMultiple: false))
            }
        }
    }
}
#endif
