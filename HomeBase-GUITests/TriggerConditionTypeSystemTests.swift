//
//  TriggerConditionTypeSystemTests.swift
//  HomeBase-GUITests
//

import HomeBaseProtocol
import SwiftUI
import XCTest
@testable import HomeBase_GUI

@MainActor
final class TriggerConditionTypeSystemTests: XCTestCase {
    func testStandardRegistrySelectsStructuredCompare() throws {
        let raw: HBJSONValue = [
            "Compare": [
                ["ControlValue": ["HallSensor", "Motion"]],
                "==",
                1,
            ]
        ]
        let context = TriggerConditionPluginContext(rawValue: raw)
        let resolution = TriggerConditionTypeRegistry.standard.resolve(context)

        XCTAssertEqual(resolution.module.identifier, "Compare")
        XCTAssertEqual(
            resolution.module.presentation(for: context),
            TriggerConditionPluginPresentation(
                title: "Hall Sensor — Motion",
                detail: "Equals 1"
            )
        )
        guard case .compare(let comparison) = resolution.module.editingPlan(
            for: context
        ) else {
            return XCTFail("Expected the structured Compare plan")
        }
        XCTAssertEqual(comparison.device, "HallSensor")
        XCTAssertEqual(comparison.control, "Motion")
        XCTAssertEqual(comparison.literal, 1)
    }

    func testProjectedCompareRoundTripsAndPresentsModelState() throws {
        let raw: HBJSONValue = [
            "Compare": [
                [
                    "ControlValue": [
                        "Device": "Environment",
                        "Control": "MainRoomDaylightPhase",
                        "Projection": "MoDeL",
                    ]
                ],
                "==",
                3,
            ]
        ]

        let comparison = try XCTUnwrap(TriggerCompareCondition(raw))

        XCTAssertEqual(comparison.device, "Environment")
        XCTAssertEqual(comparison.control, "MainRoomDaylightPhase")
        XCTAssertEqual(comparison.projection, .model)
        XCTAssertEqual(comparison.rawValue, raw)
        XCTAssertEqual(
            TriggerConditionTypeRegistry.standard.presentation(for: raw),
            TriggerConditionPluginPresentation(
                title: "HomeBase target for Environment — Main Room Daylight Phase",
                detail: "Equals 3"
            )
        )
    }

    func testCompareOperandCatalogPresentsAllEngineOperandFormsSymmetrically() {
        XCTAssertEqual(
            TriggerCompareOperandPresentationRegistry.standard
                .registeredIdentifiers,
            ["number", "control-value", "scene-state"]
        )

        let cases: [(HBJSONValue, TriggerConditionPluginPresentation)] = [
            (
                [
                    "Compare": [
                        ["SceneState": "HallDayLights"],
                        "==",
                        1,
                    ]
                ],
                .init(title: "Hall Day Lights scene", detail: "Equals 1")
            ),
            (
                [
                    "Compare": [
                        0,
                        "<",
                        ["ControlValue": ["Sensor", "Level"]],
                    ]
                ],
                .init(title: "0", detail: "Is Less Than Sensor — Level")
            ),
            (
                [
                    "Compare": [
                        [
                            "ControlValue": [
                                "Device": "Lamp",
                                "Control": "Level",
                                "Projection": "model",
                            ]
                        ],
                        ">=",
                        ["SceneState": "Evening"],
                    ]
                ],
                .init(
                    title: "HomeBase target for Lamp — Level",
                    detail: "Is Greater Than or Equal To Evening scene"
                )
            ),
        ]

        for (raw, expected) in cases {
            XCTAssertEqual(
                TriggerConditionTypeRegistry.standard.presentation(for: raw),
                expected
            )
            XCTAssertNil(
                TriggerConditionTypeRegistry.standard.validationMessage(
                    for: raw
                )
            )
        }
    }

    func testProjectedCompareMutationsPreserveReferenceShapeAndFields()
        throws
    {
        let raw: HBJSONValue = [
            "Compare": [
                [
                    "ControlValue": [
                        "Device": "Environment",
                        "Control": "DaylightPhase",
                        "Projection": "MoDeL",
                        "FutureField": ["Keep": true],
                    ]
                ],
                "==",
                2,
            ]
        ]
        let comparison = try XCTUnwrap(TriggerCompareCondition(raw))

        XCTAssertEqual(
            comparison.replacingLiteral(3).rawValue,
            [
                "Compare": [
                    [
                        "ControlValue": [
                            "Device": "Environment",
                            "Control": "DaylightPhase",
                            "Projection": "MoDeL",
                            "FutureField": ["Keep": true],
                        ]
                    ],
                    "==",
                    3,
                ]
            ]
        )
        XCTAssertEqual(
            comparison.replacingTarget(
                device: "Outside",
                control: "Sunlight"
            ).rawValue,
            [
                "Compare": [
                    [
                        "ControlValue": [
                            "Device": "Outside",
                            "Control": "Sunlight",
                            "Projection": "MoDeL",
                            "FutureField": ["Keep": true],
                        ]
                    ],
                    "==",
                    2,
                ]
            ]
        )
    }

    func testUnsupportedProjectedCompareUsesRawFallback() {
        let raw: HBJSONValue = [
            "Compare": [
                [
                    "ControlValue": [
                        "Device": "Environment",
                        "Control": "DaylightPhase",
                        "Projection": "presentation",
                    ]
                ],
                "==",
                2,
            ]
        ]

        XCTAssertEqual(
            TriggerConditionTypeRegistry.standard.editingPlan(for: raw),
            .raw
        )
    }

    func testMalformedOrFutureCompareUsesExactRawFallback() {
        let futureShape: HBJSONValue = [
            "Compare": [
                ["FutureOperand": ["Keep": true]],
                "==",
                1,
            ]
        ]

        XCTAssertEqual(
            TriggerConditionTypeRegistry.standard.editingPlan(
                for: futureShape
            ),
            .raw
        )
        XCTAssertEqual(
            TriggerConditionPluginContext(rawValue: futureShape).rawValue,
            futureShape
        )
    }

    func testCompareMutationChangesOnlyOwnedTupleValues() throws {
        let original: HBJSONValue = [
            "Compare": [
                ["ControlValue": ["Thermostat", "Temperature"]],
                ">=",
                68,
            ]
        ]
        let comparison = try XCTUnwrap(TriggerCompareCondition(original))
        let updated = comparison.replacingLiteral(70).rawValue

        XCTAssertEqual(
            updated,
            [
                "Compare": [
                    ["ControlValue": ["Thermostat", "Temperature"]],
                    ">=",
                    70,
                ]
            ]
        )
    }

    func testCompareRelationshipsUseNaturalLanguageAndPreserveEqualityAlias()
        throws
    {
        let expected: [(String, TriggerCompareCondition.Relationship, String)] = [
            ("=", .equals, "Equals"),
            ("==", .equals, "Equals"),
            ("!=", .doesNotEqual, "Does Not Equal"),
            ("<", .lessThan, "Is Less Than"),
            ("<=", .lessThanOrEqual, "Is Less Than or Equal To"),
            (">", .greaterThan, "Is Greater Than"),
            (">=", .greaterThanOrEqual, "Is Greater Than or Equal To"),
        ]

        for (rawOperator, relationship, title) in expected {
            let condition = try XCTUnwrap(
                TriggerCompareCondition([
                    "Compare": [
                        ["ControlValue": ["Sensor", "Value"]],
                        .string(rawOperator),
                        1,
                    ]
                ])
            )
            XCTAssertEqual(condition.relationship, relationship)
            XCTAssertEqual(condition.relationship.title, title)
        }

        let equality = try XCTUnwrap(
            TriggerCompareCondition([
                "Compare": [
                    ["ControlValue": ["Sensor", "Value"]],
                    "=",
                    1,
                ]
            ])
        )
        let reverted = equality
            .replacingRelationship(
                .doesNotEqual,
                preservingEqualityAlias: "="
            )
            .replacingRelationship(.equals, preservingEqualityAlias: "=")
        XCTAssertEqual(reverted.rawValue, equality.rawValue)
    }

    func testCompareLensPreservesEqualAliasAcrossUnrelatedMutation() throws {
        let original: HBJSONValue = [
            "Compare": [
                ["ControlValue": ["Sensor", "Presence"]],
                "=",
                1,
            ]
        ]
        let comparison = try XCTUnwrap(TriggerCompareCondition(original))

        XCTAssertEqual(comparison.rawValue, original)
        XCTAssertEqual(
            comparison.replacingLiteral(0).rawValue,
            [
                "Compare": [
                    ["ControlValue": ["Sensor", "Presence"]],
                    "=",
                    0,
                ]
            ]
        )
    }

    func testNoOpStructuredCompareCommitLeavesDraftClean() throws {
        let source = """
        {
          "Identifier": "Presence",
          "Mode": "Trigger",
          "Conditions": [
            {"Compare": [{"ControlValue": ["Sensor", "Presence"]}, "=", 1]}
          ],
          "Actions": [],
          "Extension": {"Keep": true}
        }
        """
        let document = try RemoteJSONDocument(
            path: "triggers/Presence.json",
            source: source
        )
        let trigger = try TriggerConfigurationCatalog(documents: [document])
            .trigger(named: "Presence")
        var draft = TriggerConfigurationDraft(trigger: trigger)
        let original = try XCTUnwrap(trigger.conditions.first?.rawValue)
        let comparison = try XCTUnwrap(TriggerCompareCondition(original))

        try draft.setCondition(at: 0, rawValue: comparison.rawValue)

        XCTAssertFalse(draft.hasSemanticChanges)
        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(draft.root, trigger.source.root)
    }

    func testProjectedCompareNoOpAndRevertLeaveDraftClean() throws {
        let source = """
        {
          "Identifier": "Daylight",
          "Mode": "Overlay",
          "Conditions": [
            {
              "Compare": [
                {
                  "ControlValue": {
                    "Device": "Environment",
                    "Control": "DaylightPhase",
                    "Projection": "MoDeL"
                  }
                },
                "==",
                3
              ]
            }
          ],
          "Actions": []
        }
        """
        let document = try RemoteJSONDocument(
            path: "triggers/Daylight.json",
            source: source
        )
        let trigger = try TriggerConfigurationCatalog(documents: [document])
            .trigger(named: "Daylight")
        var draft = TriggerConfigurationDraft(trigger: trigger)
        let original = try XCTUnwrap(trigger.conditions.first?.rawValue)
        let comparison = try XCTUnwrap(TriggerCompareCondition(original))

        try draft.setCondition(at: 0, rawValue: comparison.rawValue)
        XCTAssertFalse(draft.isDirty)

        let changed = comparison.replacingTarget(
            device: "Outside",
            control: "Sunlight"
        )
        let reverted = changed.replacingTarget(
            device: comparison.device,
            control: comparison.control
        )
        try draft.setCondition(at: 0, rawValue: reverted.rawValue)

        XCTAssertFalse(draft.hasSemanticChanges)
        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(draft.root, trigger.source.root)
    }

    func testIntegralCompareLiteralChangeAndRevertLeavesDraftClean() throws {
        let source = """
        {
          "Identifier": "Level",
          "Mode": "Overlay",
          "Conditions": [
            {"Compare": [{"ControlValue": ["Lamp", "Level"]}, "==", 1]}
          ],
          "Actions": []
        }
        """
        let document = try RemoteJSONDocument(
            path: "triggers/Level.json",
            source: source
        )
        let trigger = try TriggerConfigurationCatalog(documents: [document])
            .trigger(named: "Level")
        var draft = TriggerConfigurationDraft(trigger: trigger)
        let original = try XCTUnwrap(trigger.conditions.first?.rawValue)
        let comparison = try XCTUnwrap(TriggerCompareCondition(original))

        try draft.setCondition(
            at: 0,
            rawValue: comparison.replacingLiteral(.number(0.5)).rawValue
        )
        XCTAssertTrue(draft.isDirty)

        let reverted = comparison.replacingLiteral(
            triggerConditionJSONNumber(1)
        )
        try draft.setCondition(at: 0, rawValue: reverted.rawValue)

        XCTAssertFalse(draft.hasSemanticChanges)
        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(draft.root, trigger.source.root)
    }

    func testTimeOfDaySolarRangeUsesStructuredPresentation() throws {
        let raw: HBJSONValue = [
            "TimeOfDay": [
                ["Sunrise": -10],
                ["Sunset": -10],
            ]
        ]
        let condition = try XCTUnwrap(TriggerTimeOfDayCondition(raw))

        XCTAssertEqual(condition.rawValue, raw)
        XCTAssertNil(condition.validationMessage)
        XCTAssertEqual(
            TriggerConditionTypeRegistry.standard.presentation(for: raw),
            TriggerConditionPluginPresentation(
                title: "Time of Day",
                detail:
                    "From 10 minutes before sunrise until 10 minutes before sunset"
            )
        )
        guard case .timeOfDay(let plan) =
            TriggerConditionTypeRegistry.standard.editingPlan(for: raw)
        else {
            return XCTFail("Expected the structured Time of Day plan")
        }
        XCTAssertEqual(plan, condition)
    }

    func testTimeOfDayPreservesScalarAndSingleElementArrayForms() throws {
        let scalar: HBJSONValue = ["TimeOfDay": "08:30"]
        let array: HBJSONValue = ["TimeOfDay": ["08:30"]]

        XCTAssertEqual(
            try XCTUnwrap(TriggerTimeOfDayCondition(scalar)).rawValue,
            scalar
        )
        XCTAssertEqual(
            try XCTUnwrap(TriggerTimeOfDayCondition(array)).rawValue,
            array
        )
    }

    func testTimeOfDayEndToggleRestoresOriginalPayloadShape() throws {
        let scalar: HBJSONValue = ["TimeOfDay": "08:30"]
        let array: HBJSONValue = ["TimeOfDay": ["08:30"]]
        let temporaryEnd = TriggerTimeOfDayCondition.Expression(
            clock: "09:30"
        )

        for original in [scalar, array] {
            let condition = try XCTUnwrap(
                TriggerTimeOfDayCondition(original)
            )
            let reverted = condition
                .replacingEnd(temporaryEnd)
                .replacingEnd(nil)

            XCTAssertEqual(reverted.rawValue, original)
        }
    }

    func testTimeOfDayMutationChangesOnlySelectedExpression() throws {
        let original: HBJSONValue = [
            "TimeOfDay": [
                ["Sunrise": -10.5],
                "01:30+1",
            ]
        ]
        let condition = try XCTUnwrap(TriggerTimeOfDayCondition(original))
        let updatedStart = condition.start.replacingFunctionArgument(-15)

        XCTAssertEqual(
            condition.replacingStart(updatedStart).rawValue,
            [
                "TimeOfDay": [
                    ["Sunrise": -15],
                    "01:30+1",
                ]
            ]
        )
    }

    func testTimeOfDayClockValidationMatchesEngineGrammar() throws {
        let valid = try XCTUnwrap(
            TriggerTimeOfDayCondition(["TimeOfDay": "23:00+1"])
        )
        let invalid = try XCTUnwrap(
            TriggerTimeOfDayCondition(["TimeOfDay": "11 PM"])
        )

        XCTAssertNil(valid.validationMessage)
        XCTAssertNotNil(invalid.validationMessage)
    }

    func testTimeOfDayRejectsNonFiniteFunctionArguments() throws {
        let condition = TriggerTimeOfDayCondition(
            start: .init(function: "Sunrise", argument: .number(.infinity))
        )

        XCTAssertNotNil(condition.validationMessage)
        XCTAssertEqual(
            triggerConditionJSONNumber(Double(Int64.max)),
            .number(Double(Int64.max))
        )
    }

    func testNewTimeOfDayCreationUsesServerIndependentClockTimes() throws {
        let option = try XCTUnwrap(
            TriggerConditionTypeRegistry.standard.creationOptions.first {
                $0.id == "time-of-day"
            }
        )
        let condition = try XCTUnwrap(
            TriggerTimeOfDayCondition(option.initialValue)
        )

        XCTAssertEqual(condition.start.kind, .clock)
        XCTAssertEqual(condition.end?.kind, .clock)
    }

    func testCompositeChildMutationPreservesUnknownSiblingsExactly() throws {
        let unknown: HBJSONValue = [
            "FutureCondition": [
                "Opaque": [1, 2, 3],
                "Keep": true,
            ]
        ]
        let raw: HBJSONValue = [
            "And": [
                [
                    "Compare": [
                        ["ControlValue": ["Sensor", "Luminance"]],
                        ">",
                        0.5,
                    ]
                ],
                unknown,
            ]
        ]
        let composite = try XCTUnwrap(TriggerCompositeCondition(raw))
        let editedCompare = try XCTUnwrap(
            TriggerCompareCondition(composite.children[0])
        ).replacingLiteral(0.75)
        let updated = composite.replacingChild(
            at: 0,
            with: editedCompare.rawValue
        )

        XCTAssertEqual(updated.children[1], unknown)
        XCTAssertEqual(
            TriggerConditionTypeRegistry.standard.children(of: updated.rawValue),
            updated.children
        )
    }

    func testTrueWhenInvalidComposesOneNestedEditor() throws {
        let child: HBJSONValue = ["DayOfWeek": [1, 2, 3, 4, 5]]
        let raw: HBJSONValue = ["TrueWhenInvalid": child]
        let composite = try XCTUnwrap(TriggerCompositeCondition(raw))

        XCTAssertEqual(composite.kind, .trueWhenInvalid)
        XCTAssertEqual(composite.children, [child])
        XCTAssertEqual(composite.rawValue, raw)
        XCTAssertEqual(
            TriggerConditionTypeRegistry.standard.presentation(for: raw),
            TriggerConditionPluginPresentation(
                title: "Match When Unavailable",
                detail: "Keeps matching while its value is unavailable"
            )
        )
    }

    func testInvalidConditionUsesPredicateLanguageInsteadOfWireName() {
        let raw: HBJSONValue = [
            "Invalid": ["TimeOfDay": ["CustomDawn": 45]]
        ]

        XCTAssertEqual(
            TriggerConditionTypeRegistry.standard.presentation(for: raw),
            TriggerConditionPluginPresentation(
                title: "Unavailable",
                detail: "Matches when the condition below is unavailable"
            )
        )
    }

    func testDelayConditionPresentsBothEdgesInNaturalLanguage() {
        let child: HBJSONValue = [
            "Compare": [
                ["ControlValue": ["Environment", "DaylightPhase"]],
                "==",
                2,
            ]
        ]

        let cases: [(HBJSONValue, String)] = [
            (
                ["Delay": [120, 0, child]],
                "Waits 2 minutes before matching; stops immediately"
            ),
            (
                ["Delay": [0, 30, child]],
                "Matches immediately; waits 30 seconds before stopping"
            ),
            (
                ["Delay": [3_600, 1, child, ["Future": true]]],
                "Waits 1 hour before matching; waits 1 second before stopping"
            ),
        ]

        for (raw, expectedDetail) in cases {
            XCTAssertEqual(
                TriggerConditionTypeRegistry.standard.presentation(for: raw),
                TriggerConditionPluginPresentation(
                    title: "Wait Before Matching",
                    detail: expectedDetail
                )
            )
        }
    }

    func testMalformedInvalidAndDelayConditionsRemainLosslesslyVisible() {
        let malformed: [HBJSONValue] = [
            ["Invalid": 42],
            ["Delay": [120, 0, "not a condition"]],
        ]

        for raw in malformed {
            let context = TriggerConditionPluginContext(rawValue: raw)
            XCTAssertEqual(
                TriggerConditionTypeRegistry.standard.presentation(for: raw),
                rawPresentation(context)
            )
        }
    }

    func testMalformedCompositeFallsBackWithoutRebuildingChildren() {
        let malformed: HBJSONValue = [
            "And": [
                ["Compare": [0, "==", 1]],
                42,
            ]
        ]

        XCTAssertEqual(
            TriggerConditionTypeRegistry.standard.editingPlan(for: malformed),
            .raw
        )
        XCTAssertEqual(
            TriggerConditionPluginContext(rawValue: malformed).rawValue,
            malformed
        )
    }

    func testLiveDescriptorPresentationUsesSameRegistry() {
        let descriptor = HBTriggerConditionDescriptor(
            path: "conditions.0",
            type: "Compare",
            configuration: [
                ["ControlValue": ["Sensor", "Presence"]],
                "!=",
                0,
            ],
            status: .satisfied,
            effectiveTruth: true,
            trueWhileInvalid: false,
            children: []
        )

        let presentation = TriggerConditionTypeRegistry.standard
            .presentation(for: descriptor)
        XCTAssertEqual(presentation.title, "Sensor — Presence")
        XCTAssertEqual(presentation.detail, "Does Not Equal 0")
    }

    func testLivePresentationSurfacesTrueWhileInvalidPolicy() {
        let descriptor = HBTriggerConditionDescriptor(
            path: "conditions.0",
            type: "Compare",
            configuration: [
                ["ControlValue": ["Sensor", "Presence"]],
                "==",
                1,
            ],
            status: .satisfied,
            effectiveTruth: true,
            trueWhileInvalid: true,
            children: []
        )

        XCTAssertEqual(
            TriggerConditionTypeRegistry.standard
                .presentation(for: descriptor),
            TriggerConditionPluginPresentation(
                title: "Sensor — Presence",
                detail:
                    "Equals 1 • Keeps matching if the value is unavailable"
            )
        )
    }

    func testControlValueChangePresentsArrayAndProjectedObjectForms() {
        let cases: [(HBJSONValue, String)] = [
            (
                ["ControlValueChange": ["HallSensor", "Motion"]],
                "Device-reported value changes"
            ),
            (
                ["ControlValueChange": ["HallSensor", "Motion", 1]],
                "Device-reported value changes to 1"
            ),
            (
                [
                    "ControlValueChange": [
                        "Device": "HallSensor",
                        "Control": "Motion",
                        "Projection": "observed",
                    ]
                ],
                "Device-reported value changes"
            ),
            (
                [
                    "ControlValueChange": [
                        "Device": "HallSensor",
                        "Control": "Motion",
                        "Projection": "MoDeL",
                        "Value": 0,
                    ]
                ],
                "HomeBase target changes to 0"
            ),
        ]

        for (raw, detail) in cases {
            XCTAssertEqual(
                TriggerConditionTypeRegistry.standard.presentation(for: raw),
                TriggerConditionPluginPresentation(
                    title: "Hall Sensor — Motion",
                    detail: detail
                )
            )
        }
    }

    func testMalformedControlValueChangeUsesRawPresentation() {
        let raw: HBJSONValue = [
            "ControlValueChange": [
                "Device": "HallSensor",
                "Control": "Motion",
                "Projection": "future",
            ]
        ]

        XCTAssertEqual(
            TriggerConditionTypeRegistry.standard.presentation(for: raw),
            TriggerConditionPluginPresentation(
                title: "Control Value Change",
                detail: raw.objectValue?["ControlValueChange"]?
                    .compactConfigurationJSON
            )
        )
    }

    func testCreationOptionsComeFromConditionModules() throws {
        let registry = TriggerConditionTypeRegistry.standard

        XCTAssertEqual(
            registry.creationOptions.map(\.id),
            [
                "compare",
                "time-of-day",
                "and",
                "or",
                "xor",
                "true-when-invalid",
                "raw-json",
            ]
        )

        let expectedPluginIdentifiers = [
            "compare": "Compare",
            "time-of-day": "TimeOfDay",
            "and": "And",
            "or": "Or",
            "xor": "Xor",
            "true-when-invalid": "TrueWhenInvalid",
            "raw-json": "raw-fallback",
        ]
        for option in registry.creationOptions {
            let resolution = registry.resolve(
                TriggerConditionPluginContext(rawValue: option.initialValue)
            )
            XCTAssertEqual(
                resolution.module.identifier,
                try XCTUnwrap(expectedPluginIdentifiers[option.id]),
                option.id
            )
        }
    }

    func testStandardManifestEnumeratesEveryEngineWireTypeExactlyOnce() {
        let registry = TriggerConditionTypeRegistry.standard

        XCTAssertEqual(
            registry.modules.compactMap(\.wireType),
            [
                "Compare",
                "TimeOfDay",
                "And",
                "Or",
                "Xor",
                "TrueWhenInvalid",
                "ControlValueChange",
                "ControlValueGreaterThan",
                "ControlValueGreaterThanOrEqual",
                "ControlValueLessThan",
                "ControlValueLessThanOrEqual",
                "ControlValueEqual",
                "ControlValueNotEqual",
                "DayOfWeek",
                "Delay",
                "Sustain",
                "Invalid",
                "ObservedWithin",
                "NotObservedWithin",
                "ObservedAfter",
                "SceneActivated",
                "SceneDeactivated",
            ]
        )
        XCTAssertEqual(
            Set(registry.modules.compactMap(\.wireType)).count,
            registry.modules.count
        )
    }

    func testManifestMakesSpecializedCapabilitiesExplicit() throws {
        let modules = Dictionary(
            uniqueKeysWithValues: TriggerConditionTypeRegistry.standard.modules
                .compactMap { module in
                    module.wireType.map { ($0, module) }
                }
        )

        XCTAssertEqual(
            try XCTUnwrap(modules["Compare"]).capabilities,
            [.presentation, .editing, .creation]
        )
        XCTAssertEqual(
            try XCTUnwrap(modules["And"]).capabilities,
            [.presentation, .editing, .creation, .children]
        )
        XCTAssertEqual(
            try XCTUnwrap(modules["ControlValueChange"]).capabilities,
            [.presentation]
        )
        XCTAssertEqual(
            try XCTUnwrap(modules["Delay"]).capabilities,
            [.presentation]
        )
        XCTAssertEqual(
            try XCTUnwrap(modules["Invalid"]).capabilities,
            [.presentation]
        )
        XCTAssertEqual(
            try XCTUnwrap(modules["ObservedWithin"]).capabilities,
            []
        )
        XCTAssertEqual(
            TriggerConditionTypeRegistry.standard.fallback.capabilities,
            [.creation]
        )
    }

    func testKnownMalformedTypeDoesNotBecomeUnknownFallback() {
        let raw: HBJSONValue = [
            "Compare": ["FutureOperand": ["Keep": true]]
        ]
        let resolution = TriggerConditionTypeRegistry.standard.resolve(
            TriggerConditionPluginContext(rawValue: raw)
        )

        XCTAssertFalse(resolution.isFallback)
        XCTAssertEqual(resolution.module.wireType, "Compare")
        XCTAssertEqual(resolution.module.editingPlan(
            for: TriggerConditionPluginContext(rawValue: raw)
        ), .raw)
        XCTAssertEqual(
            TriggerConditionTypeRegistry.standard.validationMessage(for: raw),
            "This Compare condition does not have a supported configuration."
        )
    }

    func testMalformedTimeOfDayShowsAuthoredPayloadInRawPresentation() {
        let raw: HBJSONValue = ["TimeOfDay": ["Sunrise": "soon"]]

        let presentation = TriggerConditionTypeRegistry.standard.presentation(
            for: raw
        )
        XCTAssertEqual(presentation.title, "Time of Day")
        XCTAssertEqual(
            presentation.detail,
            raw.objectValue?["TimeOfDay"]?.compactConfigurationJSON
        )
        XCTAssertEqual(
            TriggerConditionTypeRegistry.standard.validationMessage(for: raw),
            "This Time of Day condition does not have a supported configuration."
        )
    }

    func testMalformedKnownCompositeCannotBeCommittedAsValid() {
        let raw: HBJSONValue = ["And": [42]]

        XCTAssertEqual(
            TriggerConditionTypeRegistry.standard.validationMessage(for: raw),
            "The “All of These” condition does not have a supported configuration."
        )
    }
}
