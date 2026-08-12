//
//  TriggerKindUICatalogTests.swift
//  HomeBase-GUITests
//

import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

final class TriggerKindUICatalogTests: XCTestCase {
    func testSupportedRegistrationsDefineWireDisplayAndProtocolMappings() {
        XCTAssertEqual(
            TriggerKindUICatalog.supported,
            [
                TriggerKindUIRegistration(
                    wireValue: "When",
                    displayName: "When",
                    kind: .when,
                    showsLastFired: true
                ),
                TriggerKindUIRegistration(
                    wireValue: "While",
                    displayName: "While",
                    kind: .while,
                    showsLastFired: false
                ),
            ]
        )
        XCTAssertEqual(
            TriggerKindUICatalog.supported.map(
                \.actionConfigurationContext
            ),
            [.trigger(.when), .trigger(.while)]
        )
        XCTAssertEqual(
            TriggerKindUICatalog.defaultRegistration.wireValue,
            "When"
        )
        XCTAssertTrue(
            TriggerKindUICatalog.registration(for: .when).showsLastFired
        )
        XCTAssertFalse(
            TriggerKindUICatalog.registration(for: .while).showsLastFired
        )
    }

    func testWireLookupIsExactToPreserveConfigurationSpelling() {
        XCTAssertEqual(
            TriggerKindUICatalog.registration(forWireValue: "When")?.kind,
            .when
        )
        XCTAssertEqual(
            TriggerKindUICatalog.registration(forWireValue: "While")?.kind,
            .while
        )
        XCTAssertNil(
            TriggerKindUICatalog.registration(forWireValue: "when")
        )
        XCTAssertNil(
            TriggerKindUICatalog.registration(forWireValue: "Whenever")
        )
    }

    func testEditorContextLookupRemainsCaseInsensitiveWithWhenFallback() {
        XCTAssertEqual(
            TriggerKindUICatalog.actionConfigurationContext(
                forEditorWireValue: "wHiLe"
            ),
            .trigger(.while)
        )
        XCTAssertEqual(
            TriggerKindUICatalog.actionConfigurationContext(
                forEditorWireValue: "unsupported"
            ),
            .trigger(.when)
        )
    }
}
