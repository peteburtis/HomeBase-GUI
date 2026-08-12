//
//  ControlValueTypeRegistryTests.swift
//  HomeBase-GUITests
//

import HomeBaseProtocol
import SwiftUI
import XCTest
@testable import HomeBase_GUI

@MainActor
final class ControlValueTypeRegistryTests: XCTestCase {
    func testStandardRegistrySelectsKnownKindsCaseInsensitively() {
        XCTAssertEqual(
            resolve("bInArYsWiTcH").plugin.identifier,
            "binary-switch"
        )
        XCTAssertEqual(
            resolve("UNITINTERVAL").plugin.identifier,
            "unit-interval"
        )
        XCTAssertEqual(
            resolve("color-v1:RGB+White+XY").plugin.identifier,
            "color-v1"
        )
    }

    func testUnknownAndUnsupportedSchemaVersionsUseFallback() {
        XCTAssertEqual(
            resolve("position-v1").plugin.identifier,
            "fallback"
        )
        XCTAssertEqual(
            resolve("color-v2:RGB+White+XY").plugin.identifier,
            "fallback"
        )
        XCTAssertEqual(
            resolve("color-v1:").plugin.identifier,
            "fallback"
        )
    }

    func testScalarRangeRequiresFiniteAscendingBounds() {
        XCTAssertEqual(
            schema(minimum: 0, maximum: 1).scalarRange,
            0 ... 1
        )
        XCTAssertNil(schema(minimum: 1, maximum: 1).scalarRange)
        XCTAssertNil(schema(minimum: 2, maximum: 1).scalarRange)
        XCTAssertNil(
            schema(minimum: -.infinity, maximum: 1).scalarRange
        )
    }

    func testCustomPluginCanAddATypeWithoutChangingTheRegistryHost() {
        let registry = ControlValueTypeRegistry(
            plugins: [
                AnyControlValueTypePlugin(
                    TestPlugin(
                        identifier: "position",
                        kind: "position-v1",
                        score: ControlValueTypeMatchSpecificity.exactSchema
                    )
                )
            ],
            fallback: AnyControlValueTypePlugin(
                TestPlugin(
                    identifier: "fallback",
                    kind: nil,
                    score: nil
                )
            )
        )

        let resolution = registry.resolve(
            ControlValueSchema(kind: "position-v1")
        )
        XCTAssertEqual(resolution.plugin.identifier, "position")
        XCTAssertFalse(resolution.isAmbiguous)
    }

    func testEqualBestMatchesAreReportedAndResolvedDeterministically() {
        let registry = ControlValueTypeRegistry(
            plugins: [
                AnyControlValueTypePlugin(
                    TestPlugin(identifier: "zeta", kind: "probe", score: 5)
                ),
                AnyControlValueTypePlugin(
                    TestPlugin(identifier: "alpha", kind: "probe", score: 5)
                ),
            ],
            fallback: AnyControlValueTypePlugin(
                TestPlugin(
                    identifier: "fallback",
                    kind: nil,
                    score: nil
                )
            )
        )

        let resolution = registry.resolve(ControlValueSchema(kind: "probe"))
        XCTAssertEqual(resolution.plugin.identifier, "alpha")
        XCTAssertEqual(resolution.competingIdentifiers, ["alpha", "zeta"])
        XCTAssertTrue(resolution.isAmbiguous)
    }

    func testColorPluginOwnsItsIntegratedStalenessPresentation() {
        let selected = ControlValueSnapshot(
            value: ["White": 2_700],
            displayText: "White(2700 K)",
            isStale: true
        )
        let selectedPlugin = resolve("color-v1:White").plugin
        XCTAssertTrue(selectedPlugin.presentsStaleness(for: selected))

        let invalid = ControlValueSnapshot(
            value: ["unexpected": true],
            displayText: "—",
            isStale: true
        )
        XCTAssertFalse(selectedPlugin.presentsStaleness(for: invalid))
    }

    func testColorPluginOffersStandaloneEditingForMixedAggregates() {
        let context = ControlValuePresentationContext(
            schema: ControlValueSchema(
                kind: "color-v1:RGB+White+XY",
                metadata: [
                    "readable": true,
                    "writable": true,
                    "structured": true,
                ]
            ),
            snapshot: ControlValueSnapshot(
                value: .null,
                displayText: "Mixed",
                aggregateState: .mixed,
                aggregateValues: [
                    ["RGB": [1, 0, 0]],
                    ["White": 2_700],
                ],
                aggregateValueCount: 2
            ),
            interaction: ControlValueInteraction(
                isEnabled: true,
                isUpdating: false,
                commit: { _, _ in },
                observations: {
                    AsyncThrowingStream { continuation in
                        continuation.finish()
                    }
                }
            ),
            accessibilityLabel: "Color",
            controlPath: "ColoredLights:Color"
        )
        let plugin = resolve("color-v1:RGB+White+XY").plugin

        XCTAssertTrue(plugin.supportsStandaloneEditing(context: context))
        XCTAssertNotNil(plugin.makeStandaloneEditor(context: context))
    }

    func testStandardPluginsOnlyOfferEditorsForCompatibleStaticValues() {
        let binary = editableContext(
            kind: "BinarySwitch",
            value: 1
        )
        XCTAssertTrue(
            resolve("BinarySwitch").plugin.supportsEditing(context: binary)
        )

        let dynamicBinary = editableContext(
            kind: "BinarySwitch",
            value: ["Cycle", [0, 1]]
        )
        XCTAssertFalse(
            resolve("BinarySwitch").plugin.supportsEditing(
                context: dynamicBinary
            )
        )

        let readOnlyBinary = editableContext(
            kind: "BinarySwitch",
            value: 1,
            writable: false
        )
        XCTAssertFalse(
            resolve("BinarySwitch").plugin.supportsEditing(
                context: readOnlyBinary
            )
        )
    }

    func testRawSceneValueParserValidatesScalarBoundsAndType() throws {
        let validator = SceneRawControlValueValidator(
            control: rawControl(
                kind: "Temperature",
                structured: false,
                minimum: -40,
                maximum: 125
            )
        )

        XCTAssertEqual(try validator.parse("21.5"), 21.5)
        XCTAssertThrowsError(try validator.parse("\"21.5\"")) { error in
            XCTAssertEqual(
                error as? SceneRawControlValueValidator.ValidationError,
                .expectedNumber(kind: "Temperature")
            )
        }
        XCTAssertThrowsError(try validator.parse("126")) { error in
            XCTAssertEqual(
                error as? SceneRawControlValueValidator.ValidationError,
                .aboveMaximum(125)
            )
        }
    }

    func testRawSceneValueParserAcceptsStructuredJSONWithoutGuessingShape()
        throws
    {
        let validator = SceneRawControlValueValidator(
            control: rawControl(
                kind: "position-v1",
                structured: true
            )
        )

        XCTAssertEqual(
            try validator.parse("{\"latitude\":47.6,\"longitude\":-122.3}"),
            ["latitude": 47.6, "longitude": -122.3]
        )
        XCTAssertThrowsError(try validator.parse("{not json}"))
    }

    func testRawSceneValueParserRejectsReadOnlyControls() {
        var control = rawControl(
            kind: "ReadOnlyProbe",
            structured: true
        )
        control.metadata["writable"] = false

        XCTAssertThrowsError(
            try SceneRawControlValueValidator(control: control).parse("null")
        ) { error in
            XCTAssertEqual(
                error as? SceneRawControlValueValidator.ValidationError,
                .notWritable
            )
        }
    }

    private func resolve(
        _ kind: String
    ) -> ControlValueTypeRegistry.Resolution {
        ControlValueTypeRegistry.standard.resolve(
            ControlValueSchema(kind: kind)
        )
    }

    private func schema(
        minimum: Double,
        maximum: Double
    ) -> ControlValueSchema {
        ControlValueSchema(
            kind: "UnitInterval",
            metadata: [
                "structured": false,
                "minimum": .number(minimum),
                "maximum": .number(maximum),
            ]
        )
    }

    private func editableContext(
        kind: String,
        value: HBJSONValue,
        writable: Bool = true
    ) -> ControlValuePresentationContext {
        ControlValuePresentationContext(
            schema: ControlValueSchema(
                kind: kind,
                metadata: [
                    "readable": true,
                    "writable": .bool(writable),
                    "structured": false,
                ]
            ),
            snapshot: ControlValueSnapshot(
                value: value,
                displayText: value.compactConfigurationJSON
            ),
            interaction: ControlValueInteraction(
                isEnabled: true,
                isUpdating: false,
                commit: { _, _ in },
                observations: {
                    AsyncThrowingStream { continuation in
                        continuation.finish()
                    }
                }
            ),
            accessibilityLabel: "Test Control",
            controlPath: "TestDevice:\(kind)"
        )
    }

    private func rawControl(
        kind: String,
        structured: Bool,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) -> HBControlDescriptor {
        var metadata: [String: HBJSONValue] = [
            "readable": true,
            "writable": true,
            "structured": .bool(structured),
        ]
        if let minimum { metadata["minimum"] = .number(minimum) }
        if let maximum { metadata["maximum"] = .number(maximum) }
        return HBControlDescriptor(
            identifier: kind,
            name: kind,
            kind: kind,
            metadata: metadata
        )
    }
}

@MainActor
private struct TestPlugin: ControlValueTypePlugin {
    let identifier: String
    let kind: String?
    let score: Int?

    func matchScore(for schema: ControlValueSchema) -> Int? {
        guard let kind,
              schema.kind.caseInsensitiveCompare(kind) == .orderedSame else {
            return nil
        }
        return score
    }

    func presentsStaleness(for snapshot: ControlValueSnapshot) -> Bool {
        false
    }

    func makeBody(context: ControlValuePresentationContext) -> some View {
        Text(context.snapshot.displayText)
    }
}
