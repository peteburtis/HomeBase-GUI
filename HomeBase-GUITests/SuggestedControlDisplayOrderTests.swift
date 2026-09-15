//
//  SuggestedControlDisplayOrderTests.swift
//  HomeBase-GUITests
//

import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

final class SuggestedControlDisplayOrderTests: XCTestCase {
    private struct Control: Equatable {
        let identifier: String
        let canonicalRank: Int
    }

    func testSuggestedControlsLeadAndUnlistedControlsKeepCanonicalOrder() {
        let controls = [
            Control(identifier: "Alpha", canonicalRank: 0),
            Control(identifier: "Beta", canonicalRank: 1),
            Control(identifier: "Gamma", canonicalRank: 2),
            Control(identifier: "Delta", canonicalRank: 3),
        ]
        let order = SuggestedControlDisplayOrder(
            metadata: [
                HBDeviceMetadataKeys.suggestedDisplayOrder: .array([
                    .string("Gamma"),
                    .string("Alpha"),
                ]),
            ]
        )

        XCTAssertEqual(
            order.sorted(
                controls,
                identifier: \.identifier,
                canonicalOrder: canonicalOrder
            ).map(\.identifier),
            ["Gamma", "Alpha", "Beta", "Delta"]
        )
    }

    func testUnknownMalformedDuplicateAndDifferentlyCasedEntriesAreHarmless() {
        let controls = [
            Control(identifier: "Alpha", canonicalRank: 0),
            Control(identifier: "Beta", canonicalRank: 1),
            Control(identifier: "Gamma", canonicalRank: 2),
        ]
        let order = SuggestedControlDisplayOrder(
            metadata: [
                HBDeviceMetadataKeys.suggestedDisplayOrder: .array([
                    .string("missing"),
                    .integer(7),
                    .string("gAmMa"),
                    .string("GAMMA"),
                ]),
            ]
        )

        XCTAssertEqual(
            order.sorted(
                controls,
                identifier: \.identifier,
                canonicalOrder: canonicalOrder
            ).map(\.identifier),
            ["Gamma", "Alpha", "Beta"]
        )
    }

    func testMissingOrNonArrayMetadataPreservesCanonicalOrder() {
        let controls = [
            Control(identifier: "Gamma", canonicalRank: 2),
            Control(identifier: "Alpha", canonicalRank: 0),
            Control(identifier: "Beta", canonicalRank: 1),
        ]

        for metadata: [String: HBJSONValue] in [
            [:],
            [HBDeviceMetadataKeys.suggestedDisplayOrder: .string("Alpha")],
        ] {
            XCTAssertEqual(
                SuggestedControlDisplayOrder(metadata: metadata).sorted(
                    controls,
                    identifier: \.identifier,
                    canonicalOrder: canonicalOrder
                ).map(\.identifier),
                ["Alpha", "Beta", "Gamma"]
            )
        }
    }

    private func canonicalOrder(_ left: Control, _ right: Control) -> Bool {
        left.canonicalRank < right.canonicalRank
    }
}
