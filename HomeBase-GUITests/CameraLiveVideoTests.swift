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
}
