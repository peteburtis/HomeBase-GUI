//
//  CameraLiveVideoTests.swift
//  HomeBase-GUITests
//

import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

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
            afterScrollingBy: CGSize(width: 100, height: 50),
            in: CGSize(width: 200, height: 100)
        )

        XCTAssertEqual(target.canonicalControlPath, "Camera:PTZ.Position")
        XCTAssertEqual(position.pan, -0.75, accuracy: 0.000_001)
        XCTAssertEqual(position.tilt, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(target.payload(for: position), .object([
            "PanTilt": .array([
                .number(-0.75),
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

        XCTAssertEqual(position.pan, 1)
        XCTAssertEqual(position.tilt, -1)
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
