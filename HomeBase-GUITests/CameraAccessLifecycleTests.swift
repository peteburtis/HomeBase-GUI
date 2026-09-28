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
        let session = CameraAccessSession(credentials: CameraPageTestCredentials(), authenticator: auth, environment: .device)
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
        let session = CameraAccessSession(credentials: CameraPageTestCredentials(), authenticator: auth, environment: .device)
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
        let session = CameraAccessSession(credentials: CameraPageTestCredentials(), authenticator: auth, environment: .device)
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

    func testBackgroundBrowserWindowDoesNotSuspendActiveCameraWindow() async {
        let auth = CameraPageTestAuthenticator()
        let session = CameraAccessSession(
            credentials: CameraPageTestCredentials(),
            authenticator: auth,
            environment: .device
        )
        let lifecycle = CameraAccessLifecycle(session: session)
        let cameraOwner = UUID()
        let browserScene = UUID()
        let cameraScene = UUID()

        lifecycle.scenePhaseChanged(.active, scene: browserScene)
        lifecycle.scenePhaseChanged(.active, scene: cameraScene)
        lifecycle.setActive(true, owner: cameraOwner)
        await settle(session)

        lifecycle.scenePhaseChanged(.background, scene: browserScene)
        XCTAssertTrue(session.isUnlocked)
        XCTAssertFalse(session.streamsSuspended)
        XCTAssertEqual(auth.calls, 1)

        lifecycle.scenePhaseChanged(.background, scene: cameraScene)
        XCTAssertFalse(session.isUnlocked)
        XCTAssertTrue(session.streamsSuspended)

        lifecycle.scenePhaseChanged(.active, scene: cameraScene)
        await settle(session)
        XCTAssertTrue(session.isUnlocked)
        XCTAssertFalse(session.streamsSuspended)
        XCTAssertEqual(auth.calls, 2)

        lifecycle.sceneDisconnected(cameraScene)
        XCTAssertFalse(session.isUnlocked)
        XCTAssertTrue(session.streamsSuspended)
    }

    func testLastCameraOwnerLeavingClearsSecretsButOneOwnerLeavingDoesNot() async {
        let credentials = CameraPageTestCredentials(presence: .biometricProtected)
        let session = CameraAccessSession(credentials: credentials, authenticator: CameraPageTestAuthenticator(), environment: .device)
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
        let session = CameraAccessSession(credentials: CameraPageTestCredentials(), authenticator: auth, environment: .device)
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

    func testActivePiPRetainsAuthorizationAndCredentialsButRevokesForegroundStreams() async throws {
        let auth = CameraPageTestAuthenticator()
        let credentials = CameraPageTestCredentials(presence: .biometricProtected)
        let session = CameraAccessSession(credentials: credentials, authenticator: auth, environment: .device)
        let lifecycle = CameraAccessLifecycle(session: session)
        let owner = UUID()
        let arbiter = CameraStreamArbiter { _, _ in throw CameraStreamError.ended }
        lifecycle.setActive(true, owner: owner)
        await settle(session)
        let bundle = try XCTUnwrap(session.unlockedCredentials)
        let foreground = try session.authorizeStreams(arbiter)
        let pip = try session.authorizePictureInPicture(camera: "bedroom")
        lifecycle.pictureInPictureStarted()
        lifecycle.scenePhaseChanged(.inactive)
        lifecycle.scenePhaseChanged(.background)

        XCTAssertTrue(session.isUnlocked)
        XCTAssertEqual(session.unlockedCredentials, bundle)
        XCTAssertFalse(foreground.isValid)
        XCTAssertThrowsError(try session.authorizeStreams(arbiter), "No new ordinary stream while backgrounded")
        XCTAssertTrue(pip.permits(camera: "bedroom"))
        XCTAssertFalse(pip.permits(camera: "living"))

        lifecycle.scenePhaseChanged(.active)
        await settle(session)
        XCTAssertEqual(auth.calls, 1, "Returning with active PiP must not prompt again")
        XCTAssertEqual(credentials.loads, 1, "Reuse memory, not a second Keychain read")
        XCTAssertEqual(session.unlockedCredentials, bundle)
        XCTAssertTrue(try session.authorizeStreams(arbiter).isValid)

        lifecycle.pictureInPictureStopped()
        XCTAssertTrue(session.isUnlocked, "The foreground viewer now owns the session")
        lifecycle.scenePhaseChanged(.background)
        XCTAssertFalse(session.isUnlocked, "The next departure without PiP follows normal locking")
        XCTAssertNil(session.unlockedCredentials)
        pip.invalidate()
        await arbiter.shutdown()
    }

    func testPiPKeepsAccessAfterViewerClosesButStoppingInBackgroundClearsIt() async throws {
        let auth = CameraPageTestAuthenticator()
        let session = CameraAccessSession(credentials: CameraPageTestCredentials(presence: .biometricProtected),
            authenticator: auth, environment: .device)
        let lifecycle = CameraAccessLifecycle(session: session)
        let owner = UUID()
        lifecycle.setActive(true, owner: owner)
        await settle(session)
        lifecycle.pictureInPictureStarted()
        lifecycle.setActive(false, owner: owner)
        XCTAssertTrue(session.isUnlocked)
        lifecycle.scenePhaseChanged(.background)
        XCTAssertNotNil(session.unlockedCredentials)
        lifecycle.pictureInPictureStopped()
        XCTAssertFalse(session.isUnlocked)
        XCTAssertNil(session.unlockedCredentials)
        lifecycle.scenePhaseChanged(.active)
        await settle(session)
        XCTAssertEqual(auth.calls, 1, "No camera owner means no foreground prompt")
        lifecycle.setActive(true, owner: UUID())
        await settle(session)
        XCTAssertEqual(auth.calls, 2, "A later camera entry must authenticate normally")
    }

    func testPiPRestorationBridgesNativeStopForegroundAndViewerOwnershipInEitherOrder() async throws {
        for foregroundFirst in [true, false] {
            let auth = CameraPageTestAuthenticator()
            let credentials = CameraPageTestCredentials(presence: .biometricProtected)
            let session = CameraAccessSession(credentials: credentials, authenticator: auth, environment: .device)
            let lifecycle = CameraAccessLifecycle(session: session)
            let oldOwner = UUID(), reopenedViewer = UUID()
            lifecycle.setActive(true, owner: oldOwner)
            await settle(session)
            let bundle = try XCTUnwrap(session.unlockedCredentials)
            lifecycle.pictureInPictureStarted()
            lifecycle.setActive(false, owner: oldOwner)
            lifecycle.scenePhaseChanged(.background)
            lifecycle.pictureInPictureWillRestore()
            lifecycle.pictureInPictureRestorationCompleted(true)
            lifecycle.pictureInPictureStopped()
            XCTAssertEqual(session.unlockedCredentials, bundle, "Native stop must not interrupt the handoff")

            if foregroundFirst { lifecycle.scenePhaseChanged(.active) }
            lifecycle.setActive(true, owner: reopenedViewer)
            if !foregroundFirst { lifecycle.scenePhaseChanged(.active) }
            await settle(session)
            XCTAssertTrue(session.isUnlocked)
            XCTAssertEqual(session.unlockedCredentials, bundle)
            XCTAssertEqual(auth.calls, 1)
            XCTAssertEqual(credentials.loads, 1)

            lifecycle.setActive(false, owner: reopenedViewer)
            XCTAssertFalse(session.isUnlocked, "The restoration hold must end after the foreground handoff")
            XCTAssertNil(session.unlockedCredentials)
        }
    }

    func testFailedPiPRestorationCannotLeaveAnUnownedSessionUnlocked() async {
        let session = CameraAccessSession(credentials: CameraPageTestCredentials(presence: .biometricProtected),
            authenticator: CameraPageTestAuthenticator(), environment: .device)
        let lifecycle = CameraAccessLifecycle(session: session)
        lifecycle.setActive(true, owner: UUID())
        await settle(session)
        lifecycle.pictureInPictureStarted()
        lifecycle.scenePhaseChanged(.background)
        lifecycle.pictureInPictureWillRestore()
        lifecycle.pictureInPictureStopped()
        XCTAssertTrue(session.isUnlocked)
        lifecycle.pictureInPictureRestorationCompleted(false)
        XCTAssertFalse(session.isUnlocked)
        XCTAssertNil(session.unlockedCredentials)
    }

    func testExplicitReopenTransfersPiPAuthorizationBeforeOrAfterViewerScopeAppears() async throws {
        for scopeAppearsFirst in [true, false] {
            let auth = CameraPageTestAuthenticator()
            let credentials = CameraPageTestCredentials(presence: .biometricProtected)
            let session = CameraAccessSession(credentials: credentials, authenticator: auth, environment: .device)
            let lifecycle = CameraAccessLifecycle(session: session)
            let oldOwner = UUID(), newOwner = UUID()
            lifecycle.setActive(true, owner: oldOwner)
            await settle(session)
            let bundle = try XCTUnwrap(session.unlockedCredentials)
            lifecycle.pictureInPictureStarted()
            lifecycle.setActive(false, owner: oldOwner)
            if scopeAppearsFirst { lifecycle.setActive(true, owner: newOwner) }

            // The controller's explicit-reopen path: hold access, immediately
            // stop the PiP lease, then let the new viewer take over.
            lifecycle.pictureInPictureWillRestore()
            lifecycle.pictureInPictureStopped()
            lifecycle.pictureInPictureRestorationCompleted(true)
            XCTAssertTrue(session.isUnlocked)
            XCTAssertEqual(session.unlockedCredentials, bundle)
            if !scopeAppearsFirst { lifecycle.setActive(true, owner: newOwner) }
            // Native didStop can follow the new viewer's onAppear.
            lifecycle.pictureInPictureStopped()
            await settle(session)
            XCTAssertFalse(session.streamsSuspended)
            XCTAssertEqual(auth.calls, 1)
            XCTAssertEqual(credentials.loads, 1)
            lifecycle.setActive(false, owner: newOwner)
            XCTAssertFalse(session.isUnlocked, "The temporary handoff must not outlive the viewer")
            XCTAssertNil(session.unlockedCredentials)
        }
    }

    func testDeviceLockRetainsActivePiPButServerResetAlwaysClearsIt() async {
        for lockBeforeBackground in [true, false] {
            let session = CameraAccessSession(credentials: CameraPageTestCredentials(presence: .biometricProtected),
                authenticator: CameraPageTestAuthenticator(), environment: .device)
            let lifecycle = CameraAccessLifecycle(session: session)
            lifecycle.setActive(true, owner: UUID())
            await settle(session)
            lifecycle.pictureInPictureStarted()
            if lockBeforeBackground { lifecycle.protectedDataWillBecomeUnavailable() }
            lifecycle.scenePhaseChanged(.background)
            lifecycle.pictureInPictureWillRestore()
            lifecycle.protectedDataWillBecomeUnavailable()
            XCTAssertTrue(session.isUnlocked)
            XCTAssertNotNil(session.unlockedCredentials)
            XCTAssertTrue(session.streamsSuspended)
            lifecycle.reset()
            XCTAssertFalse(session.isUnlocked)
            XCTAssertNil(session.unlockedCredentials)
            lifecycle.pictureInPictureRestorationCompleted(true)
            XCTAssertFalse(session.isUnlocked, "A late restore callback cannot resurrect authorization")
        }
    }

    func testDeviceLockWithoutRunningOutputClearsSecretsEvenBeforeBackground() async {
        let session = CameraAccessSession(credentials: CameraPageTestCredentials(presence: .biometricProtected),
            authenticator: CameraPageTestAuthenticator(), environment: .device)
        let lifecycle = CameraAccessLifecycle(session: session)
        lifecycle.setActive(true, owner: UUID())
        await settle(session)
        lifecycle.pictureInPictureStarted()
        lifecycle.protectedDataWillBecomeUnavailable()
        XCTAssertTrue(session.isUnlocked)
        lifecycle.pictureInPictureStopped()
        XCTAssertFalse(session.isUnlocked, "Stopping the last output while locked releases the retained grant")
        XCTAssertNil(session.unlockedCredentials)
        lifecycle.scenePhaseChanged(.active)
        lifecycle.setActive(true, owner: UUID())
        session.enter()
        await settle(session)
        XCTAssertTrue(session.isUnlocked)
        lifecycle.protectedDataWillBecomeUnavailable()
        XCTAssertFalse(session.isUnlocked, "An ordinary viewer gets no lock-screen continuation")
    }

    func testPiPCannotRetainAnAuthorizationThatWasNeverGranted() async {
        let auth = CameraPageTestAuthenticator(error: .authenticationCancelled)
        let session = CameraAccessSession(credentials: CameraPageTestCredentials(), authenticator: auth, environment: .device)
        let lifecycle = CameraAccessLifecycle(session: session)
        lifecycle.setActive(true, owner: UUID())
        await settle(session)
        lifecycle.pictureInPictureStarted()
        lifecycle.pictureInPictureWillRestore()
        lifecycle.scenePhaseChanged(.background)
        auth.error = nil
        lifecycle.scenePhaseChanged(.active)
        await settle(session)
        XCTAssertEqual(auth.calls, 2)
        lifecycle.scenePhaseChanged(.background)
        XCTAssertFalse(session.isUnlocked, "An unauthorized PiP callback must not create a lasting exception")
    }

#if os(iOS)
    func testConnectedDisplayKeepsExistingMatrixAndKeysAcrossLockInEitherLifecycleOrder() async throws {
        for count in [1, 4] {
            for childFirst in [true, false] {
                let auth = CameraPageTestAuthenticator()
                let credentials = CameraPageTestCredentials(presence: .biometricProtected)
                let access = CameraAccessSession(credentials: credentials, authenticator: auth, environment: .device)
                let lifecycle = CameraAccessLifecycle(session: access)
                lifecycle.setActive(true, owner: UUID())
                await settle(access)
                let endpoint = try XCTUnwrap(HomeBasePairingCode.endpoint(from: "homebasews://127.0.0.1:1"))
                let client = HomeBaseWebSocketClient(endpoint: endpoint)
                let cameras = CameraVideoCatalog.cameras(in: [], includesArtificial: true)
                let group = CameraGroupPlayback(client: client,
                    initialSession: CameraGroupSession(camera: try XCTUnwrap(cameras.first), client: client))
                for camera in cameras.dropFirst().prefix(count - 1) { group.toggle(camera) }
                group.activateResources(access: access)
                let presentation = CameraExternalDisplayPresentation()
                presentation.update(group: group, isVisible: true, lifecycle: lifecycle)
                let output = UUID(), secondOutput = UUID()
                presentation.outputConnected(output)
                presentation.outputConnected(secondOutput)
                let arbiter = CameraStreamArbiter { _, _ in throw CameraStreamError.ended }
                let foreground = try access.authorizeStreams(arbiter)
                let authorizations = try group.sessions.map {
                    try access.authorizeViewerStream(arbiter, camera: $0.id, owner: $0.streamOwner)
                }
                let identities = group.sessions.map(ObjectIdentifier.init)
                let renderers = group.sessions.map { ObjectIdentifier($0.playback.renderer) }
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertTrue(group.sessions.allSatisfy { $0.liveVideo.state == .playing })

                lifecycle.scenePhaseChanged(.inactive)
                if childFirst { group.suspendForPhone(stopImmediately: true) }
                lifecycle.protectedDataWillBecomeUnavailable()
                lifecycle.scenePhaseChanged(.background)
                if !childFirst { group.suspendForPhone(stopImmediately: true) }
                presentation.update(group: group, isVisible: access.isUnlocked, lifecycle: lifecycle)
                XCTAssertTrue(presentation.isVisible)
                XCTAssertTrue(group.hasActiveExternalDisplay)
                XCTAssertTrue(group.sessions.allSatisfy(\.resourcesActive))
                XCTAssertTrue(group.sessions.allSatisfy { $0.liveVideo.state == .playing })
                XCTAssertTrue(authorizations.allSatisfy(\.isValid))
                XCTAssertFalse(foreground.isValid)
                XCTAssertNotNil(access.unlockedCredentials)
                XCTAssertEqual(group.sessions.map(ObjectIdentifier.init), identities)
                XCTAssertEqual(group.sessions.map { ObjectIdentifier($0.playback.renderer) }, renderers)
                XCTAssertFalse(CameraAccessPresentation(session: access, isAuthorized: true,
                    isUnlocked: false, isAuthenticating: false, errorMessage: nil).canStream)
                XCTAssertThrowsError(try access.authorizeStreams(arbiter))
                XCTAssertThrowsError(try access.authorizeViewerStream(arbiter, camera: "new", owner: UUID()))
                do {
                    try await access.unlockCredentials()
                    XCTFail("Retained credentials must not enable a fresh locked Keychain request")
                } catch { XCTAssertEqual(error as? CameraAccessError, .sessionClosed) }

                lifecycle.scenePhaseChanged(.active)
                group.resume()
                group.activateResources(access: access)
                await settle(access)
                XCTAssertEqual(auth.calls, 1)
                XCTAssertEqual(credentials.loads, 1)
                XCTAssertTrue(authorizations.allSatisfy(\.isValid), "Returning must not restart retained video")
                lifecycle.scenePhaseChanged(.background)
                group.suspendForPhone(stopImmediately: true)
                presentation.outputDisconnected(output)
                XCTAssertTrue(group.hasActiveExternalDisplay, "Another connected output still owns the matrix")
                presentation.outputDisconnected(secondOutput)
                XCTAssertFalse(group.hasActiveExternalDisplay)
                XCTAssertFalse(presentation.isVisible)
                XCTAssertTrue(group.sessions.allSatisfy { !$0.resourcesActive })
                XCTAssertTrue(authorizations.allSatisfy { !$0.isValid })
                XCTAssertFalse(access.isUnlocked)
                XCTAssertNil(access.unlockedCredentials)
                presentation.clear()
                group.deactivate()
                lifecycle.reset()
                await arbiter.shutdown()
            }
        }
    }

    func testAccessoryRegistrationAloneAndLateConnectionCannotRetainOrStartBackgroundVideo() async throws {
        let access = CameraAccessSession(credentials: CameraPageTestCredentials(),
            authenticator: CameraPageTestAuthenticator(), environment: .device)
        let lifecycle = CameraAccessLifecycle(session: access)
        lifecycle.setActive(true, owner: UUID())
        await settle(access)
        let endpoint = try XCTUnwrap(HomeBasePairingCode.endpoint(from: "homebasews://127.0.0.1:1"))
        let client = HomeBaseWebSocketClient(endpoint: endpoint)
        let camera = try XCTUnwrap(CameraVideoCatalog.cameras(in: [], includesArtificial: true).first)
        let group = CameraGroupPlayback(client: client, initialSession: CameraGroupSession(camera: camera, client: client))
        let presentation = CameraExternalDisplayPresentation()
        defer { presentation.clear(); group.deactivate(); lifecycle.reset() }
        group.activateResources(access: access)
        presentation.update(group: group, isVisible: true, lifecycle: lifecycle)
        XCTAssertFalse(group.hasActiveExternalDisplay)
        lifecycle.pictureInPictureStarted()
        lifecycle.scenePhaseChanged(.background)
        group.suspendForPhone(stopImmediately: true)
        presentation.outputConnected(UUID())
        XCTAssertFalse(presentation.isVisible)
        XCTAssertFalse(group.hasActiveExternalDisplay, "PiP retention cannot authorize a newly connected display")
        XCTAssertTrue(group.sessions.allSatisfy { !$0.resourcesActive })
        lifecycle.pictureInPictureStopped()
        XCTAssertFalse(access.isUnlocked)
    }

    func testExplicitRevocationBlanksConnectedDisplayAndStopsItsResources() async throws {
        let access = CameraAccessSession(credentials: CameraPageTestCredentials(presence: .biometricProtected),
            authenticator: CameraPageTestAuthenticator(), environment: .device)
        let lifecycle = CameraAccessLifecycle(session: access)
        lifecycle.setActive(true, owner: UUID())
        await settle(access)
        let endpoint = try XCTUnwrap(HomeBasePairingCode.endpoint(from: "homebasews://127.0.0.1:1"))
        let client = HomeBaseWebSocketClient(endpoint: endpoint)
        let camera = try XCTUnwrap(CameraVideoCatalog.cameras(in: [], includesArtificial: true).first)
        let group = CameraGroupPlayback(client: client, initialSession: CameraGroupSession(camera: camera, client: client))
        let presentation = CameraExternalDisplayPresentation()
        defer { presentation.clear(); group.deactivate() }
        group.activateResources(access: access)
        presentation.update(group: group, isVisible: true, lifecycle: lifecycle)
        presentation.outputConnected(UUID())
        XCTAssertTrue(group.hasActiveExternalDisplay)
        lifecycle.reset()
        XCTAssertFalse(presentation.isVisible)
        XCTAssertFalse(group.hasActiveExternalDisplay)
        XCTAssertTrue(group.sessions.allSatisfy { !$0.resourcesActive })
        XCTAssertNil(access.unlockedCredentials)
    }

    func testRetainedPiPAccessAutomaticallyResumesGroupAndPreviewAfterInactiveReturn() async throws {
        let auth = CameraPageTestAuthenticator()
        let credentials = CameraPageTestCredentials(presence: .biometricProtected)
        let session = CameraAccessSession(credentials: credentials, authenticator: auth, environment: .device)
        let lifecycle = CameraAccessLifecycle(session: session)
        lifecycle.setActive(true, owner: UUID())
        await settle(session)
        lifecycle.pictureInPictureStarted()

        let state = CameraStreamResumeTestState(session: session)
        let host = UIHostingController(rootView: AnyView(CameraStreamResumeTestFixture(state: state)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.isHidden = false
        defer {
            host.rootView = AnyView(Color.clear)
            window.isHidden = true
            window.rootViewController = nil
            state.coordinators.forEach { $0.close(stopImmediately: true) }
            lifecycle.reset()
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await state.waitForStarts(1)
        XCTAssertEqual(state.starts, [1, 1])
        XCTAssertEqual(state.previewStarts, 1)

        // Transient inactivity from the foreground is concealment only.
        state.phase = .inactive
        lifecycle.scenePhaseChanged(.inactive)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.coordinators.allSatisfy(\.isActive))
        state.phase = .active
        lifecycle.scenePhaseChanged(.active)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.starts, [1, 1])

        state.phase = .background
        lifecycle.scenePhaseChanged(.background)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(session.isUnlocked)
        XCTAssertNotNil(session.unlockedCredentials)
        XCTAssertTrue(state.coordinators.allSatisfy { !$0.isActive })

        // Reproduce iOS's intermediate return phase, then deliberately let the
        // child viewer observe .active before the root access lifecycle does.
        state.phase = .inactive
        lifecycle.scenePhaseChanged(.inactive)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.coordinators.allSatisfy { !$0.isActive })
        state.phase = .active
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.starts, [1, 1])
        XCTAssertEqual(state.previewStarts, 1)
        XCTAssertTrue(state.authorizationErrors.isEmpty)

        // No further scene change or Try Again action: the published readiness
        // transition alone must restart both panes and the standalone preview.
        lifecycle.scenePhaseChanged(.active)
        try await state.waitForStarts(2)
        XCTAssertEqual(state.starts, [2, 2])
        XCTAssertEqual(state.previewStarts, 2)
        XCTAssertTrue(state.authorizationErrors.isEmpty)
        XCTAssertEqual(auth.calls, 1)
        XCTAssertEqual(credentials.loads, 1)

        // The opposite parent/child observation order must also work.
        state.phase = .background
        lifecycle.scenePhaseChanged(.background)
        try await Task.sleep(for: .milliseconds(100))
        lifecycle.scenePhaseChanged(.active)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.starts, [2, 2])
        state.phase = .active
        try await state.waitForStarts(3)
        XCTAssertEqual(state.starts, [3, 3])
        XCTAssertEqual(state.previewStarts, 3)
        XCTAssertTrue(state.authorizationErrors.isEmpty)
        XCTAssertEqual(auth.calls, 1)
        XCTAssertEqual(credentials.loads, 1)

        host.rootView = AnyView(Color.clear)
        window.isHidden = true
        window.rootViewController = nil
        state.coordinators.forEach { $0.close(stopImmediately: true) }
        for coordinator in state.coordinators { await coordinator.waitForTransitions() }
        lifecycle.reset()
        await state.arbiter.shutdown()
        try await Task.sleep(for: .milliseconds(100))
        withExtendedLifetime(state) {}
    }

    func testCameraOnlyUnlockOffersSavedCredentialRetry() async throws {
        let auth = CameraPageTestAuthenticator(error: .biometryNotAvailable)
        let session = CameraAccessSession(
            credentials: CameraPageTestCredentials(presence: .biometricProtected), authenticator: auth, environment: .device)
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
        let session = CameraAccessSession(credentials: CameraPageTestCredentials(), authenticator: auth, environment: .device)
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
    var loads = 0
    init(presence: CameraS3CredentialPresence = .missing) { self.presence = presence }
    func inspect() async throws -> CameraS3CredentialPresence { presence }
    func load(using attempt: CameraAuthenticationAttempt) async throws -> CameraS3Credentials {
        loads += 1
        return .init(destinationID: "test", accessKeyID: "test-id", secretAccessKey: "test-secret", encryptionPassword: nil)
    }
    func save(_ credentials: CameraS3Credentials, using attempt: CameraAuthenticationAttempt) async throws {}
}

#if os(iOS)
@MainActor
private final class CameraStreamResumeTestState: ObservableObject {
    @Published var phase = ScenePhase.active
    let session: CameraAccessSession
    let arbiter = CameraStreamArbiter { _, _ in throw CameraStreamError.ended }
    var coordinators: [CameraSessionResourceCoordinator] = []
    var starts = [0, 0]
    var previewStarts = 0
    var authorizationErrors: [String] = []

    init(session: CameraAccessSession) {
        self.session = session
        coordinators = (0..<2).map { index in
            CameraSessionResourceCoordinator(
                startLiveVideo: { [weak self] access in
                    guard let self, let access else { return }
                    do {
                        _ = try access.authorizeStreams(self.arbiter)
                        self.starts[index] += 1
                    } catch { self.authorizationErrors.append(error.localizedDescription) }
                },
                stopLiveVideo: { _ in }, startControls: {}, stopControls: {})
        }
    }

    func startPreview() {
        do {
            _ = try session.authorizeStreams(arbiter)
            previewStarts += 1
        } catch { authorizationErrors.append(error.localizedDescription) }
    }

    func waitForStarts(_ count: Int) async throws {
        for _ in 0..<100 {
            if starts == [count, count], previewStarts == count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct CameraStreamResumeTestFixture: View {
    @ObservedObject var state: CameraStreamResumeTestState

    var body: some View {
        CameraAccessGate { access in
            CameraStreamResumeTestContent(state: state, access: access)
        }
        .environment(\.cameraAccessSession, state.session)
        .environment(\.scenePhase, state.phase)
    }
}

private struct CameraStreamResumeTestContent: View {
    @ObservedObject var state: CameraStreamResumeTestState
    let access: CameraAccessPresentation

    var body: some View {
        let suspended = CameraLiveVideoLifecycle.isSuspended(
            in: state.phase, isStreamEnabled: access.canStream)
        VStack {
            // As in the real viewer, this nested view observes the presentation
            // snapshot, not the access session directly. A readiness-only update
            // must survive that boundary and restart the resource coordinators.
            Color.clear.onChange(of: suspended, initial: true) { _, value in
                for coordinator in state.coordinators {
                    coordinator.setActive(!value, access: access.session, stopImmediately: value)
                }
            }
            // Standalone camera previews use this task identity instead.
            Color.clear.task(id: CameraLiveVideoLifecycle.taskIdentity(
                retryID: 0, scenePhase: state.phase, isStreamEnabled: access.canStream)) {
                    guard !suspended, !Task.isCancelled else { return }
                    state.startPreview()
                }
        }
    }
}

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
