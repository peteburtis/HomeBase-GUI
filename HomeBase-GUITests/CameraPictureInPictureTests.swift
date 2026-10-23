#if os(iOS)
import AVKit
import Combine
import MediaPlayer
import SwiftUI
import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraPictureInPictureTests: XCTestCase {
    func testMenuDescribesStartingSwappingAndStoppingLivePiP() {
        let start = CameraPiPMenuAction(isSource: false, isActive: false, isLive: true)
        XCTAssertEqual(start, .start)
        XCTAssertEqual(start.title, "Picture in Picture")
        XCTAssertEqual(start.systemImage, "pip.enter")
        let history = CameraPiPMenuAction(isSource: false, isActive: false, isLive: false)
        XCTAssertEqual(history, .startLive)
        XCTAssertEqual(history.title, "Start Live Picture in Picture")
        for isLive in [true, false] {
            let swap = CameraPiPMenuAction(isSource: false, isActive: true, isLive: isLive)
            XCTAssertEqual(swap, .swap)
            XCTAssertEqual(swap.title, "Swap Picture in Picture")
            XCTAssertEqual(swap.systemImage, "arrow.triangle.swap")
            XCTAssertNotNil(UIImage(systemName: swap.systemImage))
            let stop = CameraPiPMenuAction(isSource: true, isActive: true, isLive: isLive)
            XCTAssertEqual(stop, .stop)
            XCTAssertEqual(stop.title, "Stop Picture in Picture")
            XCTAssertEqual(stop.systemImage, "pip.exit")
        }
    }

#if DEBUG
    func testMirroringFixtureUnlocksOnlyCameraUIAndCannotReadOrWriteS3Credentials() async throws {
        XCTAssertFalse(CameraPiPTestFixture.isEnabled(environment: [:]))
        XCTAssertFalse(CameraPiPTestFixture.isEnabled(environment: [CameraPiPTestFixture.environmentVariable: "0"]))
        let environment = [CameraPiPTestFixture.environmentVariable: "1"]
        XCTAssertTrue(CameraPiPTestFixture.isEnabled(environment: environment))
        let access = CameraPiPTestFixture.makeAccessSession(environment: environment)
        access.enter()
        for _ in 0..<100 where access.isAuthenticating {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(access.isUnlocked)
        XCTAssertNil(access.unlockedCredentials)
        XCTAssertEqual(access.credentialPresence, .missing)
        do {
            try await access.unlockCredentials()
            XCTFail("A fixture must not authorize credential reads")
        } catch { XCTAssertEqual(error as? CameraAccessError, .biometryNotAvailable) }
        do {
            try await access.saveCredentials(.init(destinationID: "test", accessKeyID: "test",
                secretAccessKey: "test", encryptionPassword: nil))
            XCTFail("A fixture must not authorize credential writes")
        } catch { XCTAssertEqual(error as? CameraAccessError, .biometryNotAvailable) }
        XCTAssertNil(access.unlockedCredentials)
        access.lock()
        XCTAssertFalse(access.isUnlocked)
    }
#endif

    func testNativeControllerUsesLinearLiveSampleBufferSourceAndNeverStartsAutomatically() async throws {
        let owner = CameraPictureInPictureController()
        try XCTSkipUnless(owner.isSupported, "This simulator/device does not advertise native PiP support")
        let renderer = CameraH264Renderer()
        let native = owner.makeNativeController(renderer: renderer)
        XCTAssertTrue(native.contentSource?.sampleBufferDisplayLayer === renderer.layer)
        XCTAssertFalse(native.canStartPictureInPictureAutomaticallyFromInline)
        XCTAssertTrue(native.requiresLinearPlayback)
        let range = owner.pictureInPictureControllerTimeRangeForPlayback(native)
        XCTAssertTrue(range.duration.isPositiveInfinity)
        XCTAssertTrue(owner.pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(native))
    }

    func testPaneKeepsLivePiPSourceMountedWithoutCoveringHistory() {
        for isLive in [false, true] {
            let detached = CameraPiPPanePresentation(attached: false, isLive: isLive)
            XCTAssertFalse(detached.keepsSourceMounted)
            XCTAssertFalse(detached.sourceCoversContent)
        }

        let live = CameraPiPPanePresentation(attached: true, isLive: true)
        XCTAssertTrue(live.keepsSourceMounted)
        XCTAssertTrue(live.sourceCoversContent,
            "Live must expose AVKit's system Picture in Picture placeholder")

        let history = CameraPiPPanePresentation(attached: true, isLive: false)
        XCTAssertTrue(history.keepsSourceMounted,
            "History must not tear down the independent live PiP source")
        XCTAssertFalse(history.sourceCoversContent,
            "History video must remain visible in the main pane")

        let returnedLive = CameraPiPPanePresentation(attached: true, isLive: true)
        XCTAssertTrue(returnedLive.sourceCoversContent,
            "Returning to Live must reveal AVKit's PiP placeholder again")
    }

    func testMountedSourceDoesNotDisappearAcrossLiveHistoryLive() async throws {
        let state = CameraPiPSourceLayerTestState()
        let host = UIHostingController(rootView: CameraPiPSourceLayerTestHarness(state: state))
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.appearances, 1)
        XCTAssertEqual(state.disappearances, 0)

        for isLive in [false, true] {
            state.isLive = isLive
            try await Task.sleep(for: .milliseconds(50))
            host.view.layoutIfNeeded()
            XCTAssertEqual(state.appearances, 1)
            XCTAssertEqual(state.disappearances, 0,
                "Changing only the main viewer mode must not detach the live PiP source")
        }
    }

    func testRestorePreservesExistingViewerAndCameraGroup() {
        let origin = UUID()
        let plan = CameraPiPRestorationPlan(origin: origin, cameraID: "bedroom",
            viewers: [origin: ["living", "bedroom", "test"]])
        XCTAssertEqual(plan.viewerID, origin)
        XCTAssertFalse(plan.opensNewViewer)
    }

    func testViewerRegistryDoesNotRetainClosedScreens() {
        let controller = CameraPictureInPictureController()
        let id = UUID()
        var owner: NSObject? = NSObject()
        controller.registerViewer(id, cameras: ["bedroom", "living"], owner: owner!)
        XCTAssertEqual(controller.availableViewers[id], ["bedroom", "living"])
        owner = nil
        XCTAssertNil(controller.availableViewers[id])
    }

    func testClosedViewerRestoresToNewSingleCameraViewer() {
        let origin = UUID()
        let plan = CameraPiPRestorationPlan(origin: origin, cameraID: "bedroom", viewers: [:])
        XCTAssertNotEqual(plan.viewerID, origin)
        XCTAssertTrue(plan.opensNewViewer)
    }

    func testExplicitCloseRestoresNewViewerEvenWhileSwiftUIRetainsScreenModel() {
        let controller = CameraPictureInPictureController()
        let origin = UUID()
        let retainedScreen = NSObject()
        controller.registerViewer(origin, cameras: ["bedroom", "living"], owner: retainedScreen)
        controller.unregisterViewer(origin)
        let plan = CameraPiPRestorationPlan(origin: origin, cameraID: "bedroom",
            viewers: controller.availableViewers)
        XCTAssertNil(controller.availableViewers[origin])
        XCTAssertTrue(plan.opensNewViewer)
        XCTAssertNotEqual(plan.viewerID, origin)
        withExtendedLifetime(retainedScreen) {}
    }

    func testReopeningPiPCameraAfterClosingViewerRequestsInlinePlayback() {
        for reusesViewerID in [false, true] {
            var registry = CameraPiPViewerRegistry()
            let original = UUID(), owner = NSObject(), reopenedOwner = NSObject()
            XCTAssertEqual(registry.register(original, cameras: ["bedroom", "living"], owner: owner,
                pictureInPictureCameraID: nil, restoringViewerID: nil), .updated)
            registry.unregister(original)
            XCTAssertTrue(registry.available.isEmpty)
            let reopened = reusesViewerID ? original : UUID()
            XCTAssertEqual(registry.register(reopened, cameras: ["bedroom"], owner: reopenedOwner,
                pictureInPictureCameraID: "bedroom", restoringViewerID: nil), .resumesInlinePlayback)
            XCTAssertEqual(registry.available[reopened], ["bedroom"])
            withExtendedLifetime((owner, reopenedOwner)) {}
        }
    }

    func testForegroundingOrCoveringOriginalViewerDoesNotStopPiP() {
        var registry = CameraPiPViewerRegistry()
        let original = UUID(), owner = NSObject()
        _ = registry.register(original, cameras: ["bedroom", "living"], owner: owner,
            pictureInPictureCameraID: nil, restoringViewerID: nil)
        for _ in 0..<3 {
            XCTAssertEqual(registry.register(original, cameras: ["bedroom", "living"], owner: owner,
                pictureInPictureCameraID: "bedroom", restoringViewerID: nil), .updated)
        }
        XCTAssertEqual(registry.register(original, cameras: ["bedroom", "living", "third"], owner: owner,
            pictureInPictureCameraID: "bedroom", restoringViewerID: nil), .updated)
        withExtendedLifetime(owner) {}
    }

    func testOpeningDifferentCameraKeepsPiPUntilItsCameraIsAddedToViewer() {
        var registry = CameraPiPViewerRegistry()
        let viewer = UUID(), owner = NSObject()
        XCTAssertEqual(registry.register(viewer, cameras: ["living"], owner: owner,
            pictureInPictureCameraID: "bedroom", restoringViewerID: nil), .updated)
        XCTAssertEqual(registry.register(viewer, cameras: ["living", "bedroom"], owner: owner,
            pictureInPictureCameraID: "bedroom", restoringViewerID: nil), .resumesInlinePlayback)
        XCTAssertEqual(registry.register(viewer, cameras: ["living", "bedroom"], owner: owner,
            pictureInPictureCameraID: "bedroom", restoringViewerID: nil), .updated,
            "Repeated registration during the stop animation cannot restart the handoff")
        withExtendedLifetime(owner) {}
    }

    func testSystemFullScreenRestorationKeepsItsNativeStopCompletion() {
        var registry = CameraPiPViewerRegistry()
        let reopened = UUID(), owner = NSObject()
        XCTAssertEqual(registry.register(reopened, cameras: ["bedroom"], owner: owner,
            pictureInPictureCameraID: "bedroom", restoringViewerID: reopened), .updated)
        XCTAssertEqual(registry.available[reopened], ["bedroom"])
        withExtendedLifetime(owner) {}
    }

    func testExpiredViewerOwnerDoesNotHideAnExplicitReopen() {
        var registry = CameraPiPViewerRegistry()
        let id = UUID()
        var previous: NSObject? = NSObject()
        _ = registry.register(id, cameras: ["bedroom"], owner: previous!,
            pictureInPictureCameraID: nil, restoringViewerID: nil)
        previous = nil
        XCTAssertTrue(registry.available.isEmpty)
        let owner = NSObject()
        XCTAssertEqual(registry.register(id, cameras: ["bedroom"], owner: owner,
            pictureInPictureCameraID: "bedroom", restoringViewerID: nil), .resumesInlinePlayback)
        withExtendedLifetime(owner) {}
    }

    func testRemovedCameraDoesNotRestoreToUnrelatedPane() {
        let origin = UUID()
        let plan = CameraPiPRestorationPlan(origin: origin, cameraID: "bedroom",
            viewers: [origin: ["living"], UUID(): ["bedroom"]])
        XCTAssertNotEqual(plan.viewerID, origin)
        XCTAssertTrue(plan.opensNewViewer)
    }

    func testNowPlayingContainsOnlyCameraName() {
        let metadata = CameraPictureInPictureController.nowPlayingMetadata(cameraName: "Living Room")
        XCTAssertEqual(Set(metadata.keys), [MPMediaItemPropertyTitle])
        XCTAssertEqual(metadata[MPMediaItemPropertyTitle] as? String, "Living Room")
    }

    func testSilentAudioPolicyMixesAndFutureAudiblePolicyCanTakeFocus() {
        XCTAssertEqual(CameraPiPAudioPolicy.silentVideo.options, [.mixWithOthers])
        XCTAssertEqual(CameraPiPAudioPolicy.audibleVideo.options, [])
    }

    func testOnlyAlreadyActivePiPIsAllowedToContinueIntoBackground() {
        let phases: [CameraPictureInPictureController.Phase] = [.stopped, .preparing, .starting, .active, .stopping]
        for phase in phases {
            XCTAssertEqual(phase.mayContinueInBackground, phase == .active)
        }
    }

    func testForegroundAndBackgroundNeverCreatePiPOrRestoration() {
        let controller = CameraPictureInPictureController()
        controller.scenePhaseChanged(.inactive)
        controller.scenePhaseChanged(.background)
        controller.protectedDataWillBecomeUnavailable()
        controller.scenePhaseChanged(.active)
        XCTAssertEqual(controller.phase, .stopped)
        XCTAssertNil(controller.session)
        XCTAssertNil(controller.restoration)
        XCTAssertNil(controller.reopenedViewer)
        XCTAssertNil(controller.pendingSwap)
        XCTAssertTrue(controller.canStartOrSwap)
        controller.reset()
    }
}

@MainActor
private final class CameraPiPSourceLayerTestState: ObservableObject {
    @Published var isLive = true
    var appearances = 0
    var disappearances = 0
}

private struct CameraPiPSourceLayerTestHarness: View {
    @ObservedObject var state: CameraPiPSourceLayerTestState

    var body: some View {
        CameraPiPSourceLayer(
            presentation: CameraPiPPanePresentation(attached: true, isLive: state.isLive),
            sourceDidAppear: { state.appearances += 1 },
            sourceDidDisappear: { state.disappearances += 1 }
        ) {
            Color.black
        } source: {
            Color.red
        }
    }
}
#endif
