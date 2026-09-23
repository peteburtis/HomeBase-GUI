//
//  CameraLiveVideoTests.swift
//  HomeBase-GUITests
//

import CoreMedia
import HomeBaseProtocol
import SwiftUI
import XCTest
@testable import HomeBase_GUI

#if os(iOS)
import UIKit
#endif

@MainActor
final class CameraLiveVideoTests: XCTestCase {
    func testCapabilityRequiresAvailabilityFlag() {
        XCTAssertNil(CameraLiveVideoCapability(metadata: [:]))
        XCTAssertNil(CameraLiveVideoCapability(metadata: [
            CameraLiveVideoCapability.availableMetadataKey: .bool(false),
        ]))
    }

    func testCapabilityRejectsExplicitlyUnsupportedCodec() {
        let capability = CameraLiveVideoCapability(metadata: [
            CameraLiveVideoCapability.availableMetadataKey: .bool(true),
            CameraLiveVideoCapability.codecsMetadataKey: .array([
                .string("h265"),
            ]),
        ])

        XCTAssertNil(capability)
    }

    func testCapabilitySelectsLowestAndHighestAdvertisedQualities() {
        let capability = CameraLiveVideoCapability(metadata: [
            CameraLiveVideoCapability.availableMetadataKey: .bool(true),
            CameraLiveVideoCapability.codecsMetadataKey: .array([
                .string("H264"),
            ]),
            CameraLiveVideoCapability.qualitiesMetadataKey: .array([
                .string("high"),
                .string("medium"),
            ]),
        ])

        XCTAssertEqual(capability?.previewQuality, .medium)
        XCTAssertEqual(capability?.fullScreenQuality, .high)
    }

    func testCapabilityDefaultsToAllQualitiesForOlderMetadata() {
        let capability = CameraLiveVideoCapability(metadata: [
            CameraLiveVideoCapability.availableMetadataKey: .bool(true),
        ])

        XCTAssertEqual(capability?.previewQuality, .low)
        XCTAssertEqual(capability?.fullScreenQuality, .high)
    }

    func testCapabilityUsesDefaultOnlyWhenServerAdvertisesStreamPolicy() {
        let capability = CameraLiveVideoCapability(metadata: [
            CameraLiveVideoCapability.availableMetadataKey: .bool(true),
            CameraLiveVideoCapability.streamPolicyMetadataKey: .object([
                "version": .integer(1),
            ]),
        ])

        XCTAssertTrue(capability?.supportsDefaultQuality == true)
        XCTAssertEqual(capability?.fullScreenQuality, .automatic)
    }

    func testVideoCatalogIncludesOnlyLiveH264CamerasInTopologyOrder() {
        let devices = [
            HBTopologyDeviceDescriptor(
                identifier: "light-1",
                addressableName: "Light1",
                displayName: "Light"
            ),
            HBTopologyDeviceDescriptor(
                identifier: "camera-2",
                addressableName: "Camera2",
                displayName: "Back Camera",
                metadata: [
                    CameraLiveVideoCapability.availableMetadataKey: true,
                    CameraLiveVideoCapability.codecsMetadataKey: ["h264"],
                    CameraLiveVideoCapability.qualitiesMetadataKey: [
                        "medium", "high",
                    ],
                ]
            ),
            HBTopologyDeviceDescriptor(
                identifier: "camera-1",
                addressableName: "Camera1",
                displayName: "Front Camera",
                metadata: [
                    CameraLiveVideoCapability.availableMetadataKey: true,
                    CameraLiveVideoCapability.codecsMetadataKey: ["h264"],
                ]
            ),
            HBTopologyDeviceDescriptor(
                identifier: "unsupported-camera",
                addressableName: "FutureCamera",
                displayName: "Future Camera",
                metadata: [
                    CameraLiveVideoCapability.availableMetadataKey: true,
                    CameraLiveVideoCapability.codecsMetadataKey: ["h265"],
                ]
            ),
        ]

        let cameras = CameraVideoCatalog.cameras(in: devices)

        XCTAssertEqual(cameras.map(\.id), ["camera-2", "camera-1"])
        XCTAssertEqual(
            cameras.map(\.capability.previewQuality),
            [.medium, .low]
        )
        XCTAssertEqual(
            cameras.map(\.capability.fullScreenQuality),
            [.high, .high]
        )
    }

    func testQualityMenuShowsDefaultBeforeAvailableTiersFromHighestToLowest() {
        XCTAssertEqual(
            CameraLiveQualityPresentation.options(
                in: [.low, .high],
                includesDefault: true
            ),
            [.automatic, .high, .low]
        )
        XCTAssertEqual(
            CameraLiveQualityPresentation.options(
                in: [.low, .high],
                includesDefault: false
            ),
            [.high, .low]
        )
        XCTAssertEqual(
            CameraLiveQualityPresentation.title(for: .automatic),
            "Default"
        )
        XCTAssertEqual(
            CameraLiveQualityPresentation.title(for: .low),
            "Low"
        )
        XCTAssertEqual(
            CameraLiveQualityPresentation.title(for: .medium),
            "Medium"
        )
        XCTAssertEqual(
            CameraLiveQualityPresentation.title(for: .high),
            "High"
        )
    }

    func testDefaultQualityOmitsConcreteProtocolQuality() {
        XCTAssertNil(CameraLiveQualitySelection.automatic.requestedQuality)
        XCTAssertEqual(CameraLiveQualitySelection.low.requestedQuality, .low)
        XCTAssertEqual(CameraLiveQualitySelection.medium.requestedQuality, .medium)
        XCTAssertEqual(CameraLiveQualitySelection.high.requestedQuality, .high)
    }

    func testAVCCValidationAcceptsRepeatedLengthPrefixedNALUnits() {
        let accessUnit = Data([
            0, 0, 0, 2, 0x65, 0x01,
            0, 0, 0, 1, 0x41,
        ])

        XCTAssertTrue(CameraH264Renderer.isValidAVCCAccessUnit(accessUnit))
    }

    func testAVCCValidationRejectsZeroOrTruncatedNALUnits() {
        XCTAssertFalse(CameraH264Renderer.isValidAVCCAccessUnit(Data([
            0, 0, 0, 0,
        ])))
        XCTAssertFalse(CameraH264Renderer.isValidAVCCAccessUnit(Data([
            0, 0, 0, 4, 0x65,
        ])))
    }

    func testDetailControlsDiscoverPartialCapabilitiesFromMetadata() {
        let privacy = liveControl(
            identifier: "Vendor.Privacy",
            kind: "BinarySwitch",
            value: 1,
            metadata: ["cameraPrivacy": true]
        )
        let pan = liveControl(
            identifier: "Vendor.HorizontalPosition",
            value: 0.25,
            metadata: axisMetadata(component: "PanTilt[0]")
        )
        let controls = CameraDetailControlSet(controls: [privacy, pan])

        XCTAssertEqual(controls.privacy?.id, privacy.id)
        XCTAssertEqual(controls.pan?.id, pan.id)
        XCTAssertNil(controls.tilt)
        XCTAssertNil(controls.zoom)
        XCTAssertTrue(controls.hasPanTilt)
        XCTAssertTrue(controls.hasAnyControl)
    }

    func testDetailControlsUseStandardSemanticFallbacks() {
        let tilt = liveControl(
            identifier: "PTZ.Tilt.Position",
            value: -0.5,
            metadata: axisMetadata()
        )
        let zoom = liveControl(
            identifier: "Manufacturer.Zoom",
            kind: "PTZ.Zoom.Position",
            value: 0.4,
            metadata: axisMetadata()
        )
        let privacy = liveControl(
            identifier: "Privacy.Enabled",
            kind: "BinarySwitch",
            value: 0
        )
        let controls = CameraDetailControlSet(
            controls: [tilt, zoom, privacy]
        )

        XCTAssertEqual(controls.tilt?.id, tilt.id)
        XCTAssertEqual(controls.zoom?.id, zoom.id)
        XCTAssertEqual(controls.privacy?.id, privacy.id)
        XCTAssertNil(controls.pan)
    }

    func testDetailControlsOmitUnavailableCapabilities() {
        let readOnlyZoom = liveControl(
            identifier: "PTZ.Zoom.Position",
            value: 0.5,
            metadata: axisMetadata().merging(["writable": false]) {
                _, new in new
            }
        )
        let rangeLessPan = liveControl(
            identifier: "PTZ.Pan.Position",
            value: 0.1
        )
        let controls = CameraDetailControlSet(
            controls: [readOnlyZoom, rangeLessPan]
        )

        XCTAssertNil(controls.privacy)
        XCTAssertNil(controls.pan)
        XCTAssertNil(controls.tilt)
        XCTAssertNil(controls.zoom)
        XCTAssertFalse(controls.hasAnyControl)
    }

    func testDetailControlBooleanWritesPreserveWireRepresentation() {
        let boolean = liveControl(
            identifier: "Privacy.Enabled",
            kind: "BinarySwitch",
            value: .bool(false)
        )
        let number = liveControl(
            identifier: "Privacy.Enabled",
            kind: "BinarySwitch",
            value: .number(0)
        )
        let integer = liveControl(
            identifier: "Privacy.Enabled",
            kind: "BinarySwitch",
            value: .integer(0)
        )

        XCTAssertEqual(boolean.cameraOverlayBooleanWireValue(true), .bool(true))
        XCTAssertEqual(number.cameraOverlayBooleanWireValue(true), .number(1))
        XCTAssertEqual(integer.cameraOverlayBooleanWireValue(true), .integer(1))
    }

    func testPrivacyButtonIconReflectsPrivacyState() {
        XCTAssertEqual(
            CameraPrivacyButtonPresentation.systemImageName(
                privacyEnabled: false
            ),
            "eye"
        )
        XCTAssertEqual(
            CameraPrivacyButtonPresentation.systemImageName(
                privacyEnabled: true
            ),
            "eye.slash"
        )
    }

    func testDayNightModeUsesAdvertisedTapoChoicesAndWireValues() throws {
        let control = liveControl(
            identifier: "Tapo.Image.DayNightMode",
            value: .number(2),
            metadata: dayNightChoiceMetadata(values: [
                .number(10), .number(20), .number(2),
            ])
        )

        let target = try XCTUnwrap(CameraDayNightModeTarget(
            controls: [control]
        ))

        XCTAssertEqual(target.control.id, control.id)
        XCTAssertEqual(target.choices.map(\.mode), [
            .day, .night, .automatic,
        ])
        XCTAssertEqual(target.selectedMode, .automatic)
        XCTAssertEqual(target.wireValue(for: .day), .number(10))
        XCTAssertEqual(target.wireValue(for: .night), .number(20))
        XCTAssertEqual(target.wireValue(for: .automatic), .number(2))
    }

    func testDayNightModeSupportsSemanticMetadataAndStringValues() throws {
        let control = liveControl(
            identifier: "Vendor.Illumination",
            value: .string("infrared"),
            metadata: dayNightChoiceMetadata(values: [
                .string("visible"),
                .string("infrared"),
                .string("adaptive"),
            ]).merging([
                CameraDayNightModeTarget.semanticMetadataKey: true,
            ]) { _, new in new }
        )

        let target = try XCTUnwrap(CameraDayNightModeTarget(
            controls: [control]
        ))

        XCTAssertEqual(target.selectedMode, .night)
        XCTAssertEqual(
            target.wireValue(for: .automatic),
            .string("adaptive")
        )
    }

    func testDayNightModeRejectsUnrelatedChoiceControls() {
        let control = liveControl(
            identifier: "Tapo.Image.LightFrequency",
            value: .number(0),
            metadata: dayNightChoiceMetadata(values: [
                .number(0), .number(1), .number(2),
            ])
        )

        XCTAssertNil(CameraDayNightModeTarget(controls: [control]))
    }

    func testDayNightModeUsesRequestedSymbols() {
        XCTAssertEqual(CameraDayNightMode.day.systemImageName, "sun.max")
        XCTAssertEqual(CameraDayNightMode.night.systemImageName, "moon")
        XCTAssertEqual(
            CameraDayNightMode.automatic.systemImageName,
            "sun.max.fill"
        )
    }

    func testRecordingArmsAfterDestinationPreparation() async throws {
        let destination = CameraRecordingDestinationStub()
        let controller = CameraLocalRecordingController(
            destination: destination
        )
        let ownerID = UUID()

        await controller.start()
        XCTAssertEqual(controller.state, .idle)

        let formatDescription = try makeH264FormatDescription()
        await controller.configure(
            ownerID: ownerID,
            generation: 1,
            formatDescription: formatDescription
        )
        await controller.start()

        XCTAssertEqual(destination.prepareCount, 1)
        XCTAssertEqual(controller.state, .waitingForKeyFrame)
        XCTAssertTrue(controller.isRecording)
        XCTAssertTrue(controller.locksStreamConfiguration)

        await controller.stopAndSave()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(destination.savedURLs.count, 0)
    }

    func testRecordingPreparationFailureIsPresented() async throws {
        let destination = CameraRecordingDestinationStub(
            preparationError: CameraRecordingDestinationError.permissionDenied
        )
        let controller = CameraLocalRecordingController(
            destination: destination
        )
        let ownerID = UUID()
        let formatDescription = try makeH264FormatDescription()
        await controller.configure(
            ownerID: ownerID,
            generation: 1,
            formatDescription: formatDescription
        )

        await controller.start()

        XCTAssertEqual(destination.prepareCount, 1)
        XCTAssertEqual(
            controller.errorMessage,
            CameraRecordingDestinationError.permissionDenied
                .localizedDescription
        )
        XCTAssertFalse(controller.isRecording)

        controller.dismissError()
        XCTAssertEqual(controller.state, .idle)
    }

    func testRecordingIgnoresEndFromSupersededPlayer() async throws {
        let controller = CameraLocalRecordingController(
            destination: CameraRecordingDestinationStub()
        )
        let firstOwnerID = UUID()
        let currentOwnerID = UUID()
        let formatDescription = try makeH264FormatDescription()
        await controller.configure(
            ownerID: firstOwnerID,
            generation: 1,
            formatDescription: formatDescription
        )
        await controller.configure(
            ownerID: currentOwnerID,
            generation: 1,
            formatDescription: formatDescription
        )

        await controller.streamDidEnd(ownerID: firstOwnerID)
        XCTAssertTrue(controller.isStreamAvailable)

        await controller.streamDidEnd(ownerID: currentOwnerID)
        XCTAssertFalse(controller.isStreamAvailable)
    }

    func testPermissionDialogInactivityDoesNotRestartLiveVideoTask() {
        XCTAssertFalse(CameraLiveVideoLifecycle.isSuspended(in: .active))
        XCTAssertFalse(CameraLiveVideoLifecycle.isSuspended(in: .inactive))
        XCTAssertTrue(CameraLiveVideoLifecycle.isSuspended(in: .background))

        let activeIdentity = CameraLiveVideoLifecycle.taskIdentity(
            retryID: 3,
            scenePhase: .active
        )
        XCTAssertEqual(
            activeIdentity,
            CameraLiveVideoLifecycle.taskIdentity(
                retryID: 3,
                scenePhase: .inactive
            )
        )
        XCTAssertNotEqual(
            activeIdentity,
            CameraLiveVideoLifecycle.taskIdentity(
                retryID: 3,
                scenePhase: .background
            )
        )
    }

    func testCoveredPreviewSuspendsUntilVisibleAndForegrounded() {
        for phase: ScenePhase in [.active, .inactive, .background] {
            XCTAssertTrue(CameraLiveVideoLifecycle.isSuspended(in: phase, isStreamEnabled: false))
        }
        let visible = CameraLiveVideoLifecycle.taskIdentity(retryID: 0, scenePhase: .active)
        let covered = CameraLiveVideoLifecycle.taskIdentity(
            retryID: 0, scenePhase: .active, isStreamEnabled: false
        )
        XCTAssertNotEqual(visible, covered)
        XCTAssertEqual(covered, CameraLiveVideoLifecycle.taskIdentity(
            retryID: 0, scenePhase: .inactive, isStreamEnabled: false
        ))
        // Dismissing the cover in the background must not open a stream.
        XCTAssertEqual(covered, CameraLiveVideoLifecycle.taskIdentity(
            retryID: 0, scenePhase: .background, isStreamEnabled: true
        ))
        XCTAssertEqual(visible, CameraLiveVideoLifecycle.taskIdentity(
            retryID: 0, scenePhase: .active, isStreamEnabled: true
        ))
        // Full-screen players opt in independently of their covered previews.
        XCTAssertFalse(CameraLiveVideoLifecycle.isSuspended(in: .active))
    }

    func testVideoIsDisplayedOnlyWhileActivelyPlaying() {
        XCTAssertFalse(CameraLiveVideoModel.State.idle.displaysVideo)
        XCTAssertFalse(CameraLiveVideoModel.State.connecting.displaysVideo)
        XCTAssertFalse(
            CameraLiveVideoModel.State.waiting("Reconnecting").displaysVideo
        )
        XCTAssertTrue(CameraLiveVideoModel.State.playing.displaysVideo)
        XCTAssertFalse(
            CameraLiveVideoModel.State.ended(
                "Privacy enabled",
                retryable: true
            ).displaysVideo
        )
        XCTAssertFalse(
            CameraLiveVideoModel.State.failed("Disconnected").displaysVideo
        )
    }

    func testPrivacyRecoveryRequiresConfirmedOnToOffTransition() {
        XCTAssertTrue(CameraPrivacyStreamRecovery.shouldRequestRestart(
            from: true,
            to: false
        ))
        XCTAssertFalse(CameraPrivacyStreamRecovery.shouldRequestRestart(
            from: nil,
            to: false
        ))
        XCTAssertFalse(CameraPrivacyStreamRecovery.shouldRequestRestart(
            from: false,
            to: false
        ))
        XCTAssertFalse(CameraPrivacyStreamRecovery.shouldRequestRestart(
            from: true,
            to: true
        ))
    }

    func testPrivacyRecoveryIgnoresOptimisticPendingValue() {
        var privacy = liveControl(
            identifier: "Privacy.Enabled",
            kind: "BinarySwitch",
            value: .bool(true)
        )
        privacy.pendingValue = .bool(false)
        let controls = CameraDetailControlSet(controls: [privacy])

        XCTAssertEqual(privacy.cameraOverlayBooleanValue, false)
        XCTAssertEqual(controls.observedPrivacyEnabled, true)
    }

    func testPanTiltGestureMapsScrollingToCanonicalPosition() throws {
        let controls = panTiltControls(
            pan: 0.25,
            tilt: -0.25,
            zoom: 0.5
        )
        let target = try XCTUnwrap(
            CameraPanTiltGestureTarget(controls: controls)
        )

        let position = target.position(
            afterScrollingBy: CGSize(width: 50, height: 50),
            in: CGSize(width: 200, height: 100)
        )

        XCTAssertEqual(target.canonicalControlPath, "Camera:PTZ.Position")
        XCTAssertEqual(position.pan, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(position.tilt, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(target.payload(for: position), .object([
            "PanTilt": .array([
                .number(0.75),
                .number(0.75),
            ]),
            "Zoom": .array([.number(0.5)]),
        ]))
    }

    func testPanTiltGestureClampsToDiscoveredRanges() throws {
        let target = try XCTUnwrap(CameraPanTiltGestureTarget(
            controls: panTiltControls(pan: 0, tilt: 0)
        ))

        let position = target.position(
            afterScrollingBy: CGSize(width: -10_000, height: -10_000),
            in: CGSize(width: 100, height: 100)
        )

        XCTAssertEqual(position.pan, -1)
        XCTAssertEqual(position.tilt, -1)
    }

    func testCameraOverlaySliderCanInvertOnlyItsPresentation() {
        let range = -2.0 ... 6.0

        XCTAssertEqual(
            CameraOverlaySliderDirection.normal.displayedValue(
                for: 1,
                in: range
            ),
            1
        )
        XCTAssertEqual(
            CameraOverlaySliderDirection.inverted.displayedValue(
                for: 1,
                in: range
            ),
            3
        )
        XCTAssertEqual(
            CameraOverlaySliderDirection.inverted.controlValue(
                for: 5,
                in: range
            ),
            -1
        )
    }

    func testPanTiltGestureOpeningPositionIgnoresOptimisticValues() throws {
        var controls = panTiltControls(pan: 0.1, tilt: -0.2)
        controls[0].pendingValue = .number(0.8)
        controls[1].pendingValue = .number(0.7)

        let target = try XCTUnwrap(
            CameraPanTiltGestureTarget(controls: controls)
        )

        XCTAssertEqual(target.position.pan, 0.8)
        XCTAssertEqual(target.position.tilt, 0.7)
        XCTAssertEqual(target.observedPosition.pan, 0.1)
        XCTAssertEqual(target.observedPosition.tilt, -0.2)
    }

    func testPanTiltGestureRequiresMatchingCanonicalAxes() {
        let controls = [
            liveControl(
                identifier: "PTZ.Pan.Position",
                value: .number(0),
                metadata: canonicalAxisMetadata(
                    component: "PanTilt[0]"
                )
            ),
            liveControl(
                identifier: "PTZ.Tilt.Position",
                value: .number(0),
                metadata: axisMetadata(component: "PanTilt[1]")
                    .merging([
                        "canonicalControl": .string("Other.Position"),
                    ]) { existing, _ in existing }
            ),
        ]

        XCTAssertNil(CameraPanTiltGestureTarget(controls: controls))
        XCTAssertNil(CameraPanTiltGestureTarget(controls: [controls[0]]))
    }

    func testZoomGestureMapsPinchOutToZoomIn() throws {
        let target = try XCTUnwrap(CameraZoomGestureTarget(
            controls: panTiltControls(pan: 0, tilt: 0, zoom: 0)
        ))

        XCTAssertEqual(
            target.value(afterMagnifyingBy: 2),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            target.value(afterMagnifyingBy: 0.5),
            -1,
            accuracy: 0.000_001
        )
    }

    func testZoomGestureRequiresAnAvailableZoomControl() {
        XCTAssertNil(CameraZoomGestureTarget(
            controls: panTiltControls(pan: 0, tilt: 0)
        ))
    }

#if os(iOS)
    func testCameraPresentationKeepsSystemOrientationAndAllowsPortraitAndLandscape() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let originalOrientation = scene.effectiveGeometry.interfaceOrientation
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let presenter = UIHostingController(rootView: Color.black)
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(100))
        defer {
            window.isHidden = true; window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        let endpoint = try XCTUnwrap(HomeBasePairingCode.endpoint(from: "homebasews://127.0.0.1:1"))
        let client = HomeBaseWebSocketClient(endpoint: endpoint)
        let camera = HBTopologyDeviceDescriptor(identifier: "orientation-test", addressableName: "OrientationTest", displayName: "Test Camera")
        let player = UIHostingController(rootView: CameraFullScreenLiveVideoView(device: camera, quality: .high, client: client)
            .environment(\.scenePhase, .background)) // Mount real UI without connecting to a camera/server.
        player.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in
            presenter.present(player, animated: false) { continuation.resume() }
        }
        try await Task.sleep(for: .milliseconds(250))
        for orientation: UIInterfaceOrientationMask in [.portrait, .landscapeLeft, .landscapeRight] {
            XCTAssertTrue(UIApplication.shared.supportedInterfaceOrientations(for: window).contains(orientation))
            XCTAssertTrue(player.supportedInterfaceOrientations.contains(orientation))
        }
        XCTAssertEqual(scene.effectiveGeometry.interfaceOrientation, originalOrientation, "Opening the player must not request rotation")
        await withCheckedContinuation { continuation in
            presenter.dismiss(animated: false) { continuation.resume() }
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(scene.effectiveGeometry.interfaceOrientation, originalOrientation, "Closing the player must not request rotation")
        await client.disconnect()
    }
#endif

    private func axisMetadata(
        component: String? = nil
    ) -> [String: HBJSONValue] {
        var metadata: [String: HBJSONValue] = [
            "minimum": -1,
            "maximum": 1,
        ]
        if let component {
            metadata["canonicalComponent"] = .string(component)
        }
        return metadata
    }

    private func dayNightChoiceMetadata(
        values: [HBJSONValue]
    ) -> [String: HBJSONValue] {
        precondition(values.count == 3)
        return [
            "choices": .array([
                .object(["value": values[0], "label": .string("day")]),
                .object(["value": values[1], "label": .string("night")]),
                .object(["value": values[2], "label": .string("auto")]),
            ]),
        ]
    }

    private func makeH264FormatDescription() throws
        -> CMVideoFormatDescription
    {
        var formatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 1_280,
            height: 720,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return formatDescription
    }

    private func panTiltControls(
        pan: Double,
        tilt: Double,
        zoom: Double? = nil
    ) -> [LiveDeviceControl] {
        var controls = [
            liveControl(
                identifier: "PTZ.Pan.Position",
                value: .number(pan),
                metadata: canonicalAxisMetadata(
                    component: "PanTilt[0]"
                )
            ),
            liveControl(
                identifier: "PTZ.Tilt.Position",
                value: .number(tilt),
                metadata: canonicalAxisMetadata(
                    component: "PanTilt[1]"
                )
            ),
        ]
        if let zoom {
            controls.append(liveControl(
                identifier: "PTZ.Zoom.Position",
                value: .number(zoom),
                metadata: canonicalAxisMetadata(component: "Zoom[0]")
            ))
        }
        return controls
    }

    private func canonicalAxisMetadata(
        component: String
    ) -> [String: HBJSONValue] {
        axisMetadata(component: component).merging([
            "canonicalControl": .string("PTZ.Position"),
        ]) { existing, _ in existing }
    }

    private func liveControl(
        identifier: String,
        kind: String? = nil,
        value: HBJSONValue,
        metadata: [String: HBJSONValue] = [:]
    ) -> LiveDeviceControl {
        let metadata = metadata.merging([
            "readable": true,
            "writable": true,
            "structured": false,
            "valid": true,
        ]) { existing, _ in existing }
        let kind = kind ?? identifier
        return LiveDeviceControl(
            descriptor: HBControlWatchStreamControl(
                control: "Camera:\(identifier)",
                deviceIdentifier: "Camera",
                controlIdentifier: identifier,
                displayName: identifier,
                kind: kind,
                metadata: metadata
            ),
            details: HBControlDescriptor(
                identifier: identifier,
                name: identifier,
                kind: kind,
                value: value,
                metadata: metadata
            ),
            value: value,
            valid: true
        )
    }
}

@MainActor
private final class CameraRecordingDestinationStub:
    CameraRecordingDestination
{
    let preparationError: Error?
    private(set) var prepareCount = 0
    private(set) var savedURLs: [URL] = []

    init(preparationError: Error? = nil) {
        self.preparationError = preparationError
    }

    func prepare() async throws {
        prepareCount += 1
        if let preparationError { throw preparationError }
    }

    func saveVideo(at fileURL: URL, creationDate: Date) async throws {
        savedURLs.append(fileURL)
    }
}
