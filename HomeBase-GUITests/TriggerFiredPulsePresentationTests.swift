//
//  TriggerFiredPulsePresentationTests.swift
//  HomeBase-GUITests
//

import XCTest
@testable import HomeBase_GUI

final class TriggerFiredPulsePresentationTests: XCTestCase {
    func testPulseAppearsQuickly() {
        XCTAssertEqual(
            TriggerFiredPulsePresentation.opacity(elapsed: 0),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TriggerFiredPulsePresentation.opacity(elapsed: 0.075),
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TriggerFiredPulsePresentation.opacity(elapsed: 0.15),
            1,
            accuracy: 0.001
        )
    }

    func testPulseFadesSlowlyAndEndsAtFiveSeconds() {
        XCTAssertGreaterThan(
            TriggerFiredPulsePresentation.opacity(elapsed: 1),
            0.8
        )
        XCTAssertEqual(
            TriggerFiredPulsePresentation.opacity(elapsed: 5),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TriggerFiredPulsePresentation.opacity(elapsed: 6),
            0,
            accuracy: 0.001
        )
    }

    func testFutureFireDoesNotAppear() {
        XCTAssertEqual(
            TriggerFiredPulsePresentation.opacity(elapsed: -0.1),
            0,
            accuracy: 0.001
        )
    }
}
