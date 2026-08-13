//
//  LiveDeviceControlsModelTests.swift
//  HomeBase-GUITests
//

import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

final class LiveDeviceControlsModelTests: XCTestCase {
    func testEmptyDescriptorsHaveNoPotentiallyReadableStandardControl() {
        XCTAssertFalse(
            LiveDeviceControlsModel.hasPotentiallyReadableStandardControl(
                in: []
            )
        )
    }

    func testCompatibilityControlsDoNotMakeStandardWatchViable() {
        let descriptor = control(
            metadata: [
                "compatibility": .bool(true),
                "readable": .bool(true),
            ]
        )

        XCTAssertFalse(
            LiveDeviceControlsModel.hasPotentiallyReadableStandardControl(
                in: [descriptor]
            )
        )
    }

    func testExplicitlyUnreadableStandardControlsDoNotMakeWatchViable() {
        let descriptor = control(metadata: ["readable": .bool(false)])

        XCTAssertFalse(
            LiveDeviceControlsModel.hasPotentiallyReadableStandardControl(
                in: [descriptor]
            )
        )
    }

    func testReadableStandardControlMakesWatchViable() {
        let descriptor = control(metadata: ["readable": .bool(true)])

        XCTAssertTrue(
            LiveDeviceControlsModel.hasPotentiallyReadableStandardControl(
                in: [descriptor]
            )
        )
    }

    func testMissingReadableMetadataDefersToStreamAPI() {
        let descriptor = control(metadata: [:])

        XCTAssertTrue(
            LiveDeviceControlsModel.hasPotentiallyReadableStandardControl(
                in: [descriptor]
            )
        )
    }

    private func control(
        metadata: [String: HBJSONValue]
    ) -> HBControlDescriptor {
        HBControlDescriptor(
            identifier: "Control",
            name: "Control",
            kind: "Test",
            metadata: metadata
        )
    }
}
