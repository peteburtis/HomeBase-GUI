//
//  TriggerModeUICatalogTests.swift
//  HomeBase-GUITests
//

import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

final class TriggerModeUICatalogTests: XCTestCase {
    func testSupportedRegistrationsDefineWireDisplayAndProtocolMappings() {
        XCTAssertEqual(
            TriggerModeUICatalog.supported,
            [
                TriggerModeUIRegistration(
                    wireValue: "Trigger",
                    displayName: "Trigger",
                    mode: .trigger,
                    showsLastFired: true
                ),
                TriggerModeUIRegistration(
                    wireValue: "Overlay",
                    displayName: "Overlay",
                    mode: .overlay,
                    showsLastFired: false
                ),
            ]
        )
        XCTAssertEqual(
            TriggerModeUICatalog.supported.map(
                \.actionConfigurationContext
            ),
            [.trigger(.trigger), .trigger(.overlay)]
        )
        XCTAssertEqual(
            TriggerModeUICatalog.defaultRegistration.wireValue,
            "Trigger"
        )
        XCTAssertTrue(
            TriggerModeUICatalog.registration(for: .trigger).showsLastFired
        )
        XCTAssertFalse(
            TriggerModeUICatalog.registration(for: .overlay).showsLastFired
        )
    }

    func testWireLookupIsExactToPreserveConfigurationSpelling() {
        XCTAssertEqual(
            TriggerModeUICatalog.registration(forWireValue: "Trigger")?.mode,
            .trigger
        )
        XCTAssertEqual(
            TriggerModeUICatalog.registration(forWireValue: "Overlay")?.mode,
            .overlay
        )
        XCTAssertNil(
            TriggerModeUICatalog.registration(forWireValue: "trigger")
        )
        XCTAssertNil(
            TriggerModeUICatalog.registration(forWireValue: "Persistent")
        )
    }

    func testEditorContextLookupRemainsCaseInsensitiveWithTriggerFallback() {
        XCTAssertEqual(
            TriggerModeUICatalog.actionConfigurationContext(
                forEditorWireValue: "oVeRlAy"
            ),
            .trigger(.overlay)
        )
        XCTAssertEqual(
            TriggerModeUICatalog.actionConfigurationContext(
                forEditorWireValue: "unsupported"
            ),
            .trigger(.trigger)
        )
    }
}
