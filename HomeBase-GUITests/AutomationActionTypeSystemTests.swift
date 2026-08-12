//
//  AutomationActionTypeSystemTests.swift
//  HomeBase-GUITests
//

import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class AutomationActionTypeSystemTests: XCTestCase {
    func testStandardRegistryResolvesEveryBuiltInActionAndFallsBackToRawJSON() {
        XCTAssertEqual(BuiltInAutomationActionKind.allCases.count, 13)

        for kind in BuiltInAutomationActionKind.allCases {
            let resolution = AutomationActionTypeRegistry.standard.resolve(
                action(type: kind.rawValue, payload: .null)
            )

            XCTAssertEqual(
                resolution.plugin.identifier,
                kind.identifier,
                "Missing action presenter for \(kind.rawValue)"
            )
            XCTAssertFalse(resolution.isFallback)
        }

        let futureAction: HBJSONValue = [
            "FutureAction": ["Opaque": [1, 2, 3]]
        ]
        let futureResolution = AutomationActionTypeRegistry.standard.resolve(
            SceneActionConfiguration(index: 0, rawValue: futureAction)
        )
        XCTAssertEqual(futureResolution.plugin.identifier, "raw-json")
        XCTAssertTrue(futureResolution.isFallback)

        let ambiguousShape: HBJSONValue = ["Wait": 1, "Future": true]
        XCTAssertTrue(
            AutomationActionTypeRegistry.standard.resolve(
                SceneActionConfiguration(index: 0, rawValue: ambiguousShape)
            ).isFallback
        )
    }

    func testBuiltInActionCapabilitiesDoNotImplyCreationOrEditing() {
        let fullModuleIdentifiers: Set<String> = [
            "control-set", "wait", "scene-apply", "scene-activate",
        ]

        for kind in BuiltInAutomationActionKind.allCases {
            let plugin = AutomationActionTypeRegistry.standard.resolve(
                action(type: kind.rawValue, payload: .null)
            ).plugin
            let expected: AutomationActionUICapabilities =
                fullModuleIdentifiers.contains(kind.identifier)
                    ? [.presentation, .editing, .creation]
                    : [.presentation]
            XCTAssertEqual(
                plugin.capabilities,
                expected,
                "Unexpected capabilities for \(kind.rawValue)"
            )
        }

        XCTAssertEqual(
            AutomationActionTypeRegistry.standard.fallback.capabilities,
            [.presentation, .editing, .creation]
        )
    }

    func testCreationApplicabilityMatchesEngineActionContexts() {
        XCTAssertEqual(
            pluginIdentifiers(for: .scene),
            ["control-set", "wait", "scene-apply", "raw-json"]
        )
        XCTAssertEqual(
            pluginIdentifiers(for: .trigger(.when)),
            ["control-set", "wait", "scene-apply", "raw-json"]
        )
        XCTAssertEqual(
            pluginIdentifiers(for: .trigger(.while)),
            [
                "control-set",
                "wait",
                "scene-apply",
                "scene-activate",
                "raw-json",
            ]
        )

        for context in [
            AutomationActionConfigurationContext.scene,
            .trigger(.when),
            .trigger(.while),
        ] {
            XCTAssertTrue(
                AutomationActionTypeRegistry.standard
                    .creationPlugins(for: context)
                    .allSatisfy { $0.capabilities.contains(.creation) }
            )
        }
    }

    func testEveryBuiltInActionHasAHumanReadableGoldenPresentation() {
        let cases: [(
            type: String,
            payload: HBJSONValue,
            expected: AutomationActionPluginPresentation
        )] = [
            (
                "ControlSet",
                [
                    "HallLamp",
                    "MultilevelSwitch",
                    [0.64, 120],
                    2,
                    ["ClearsOverride": true],
                ],
                .init(
                    title: "Set Control",
                    detail: "HallLamp.MultilevelSwitch to 0.64 • "
                        + "2 min transition • P-2 • clears override"
                )
            ),
            (
                "ControlToggle",
                ["HallLamp", "BinarySwitch", 2],
                .init(
                    title: "Toggle Control",
                    detail: "HallLamp.BinarySwitch • P-2"
                )
            ),
            (
                "ControlHold",
                [
                    "HallLamp",
                    "MultilevelSwitch",
                    [0.64, 120],
                    "Night Light",
                    2,
                ],
                .init(
                    title: "Hold Control",
                    detail: "HallLamp.MultilevelSwitch at 0.64 as "
                        + "“Night Light” • 2 min transition • P-2"
                )
            ),
            (
                "ControlRelease",
                "Night Light",
                .init(title: "Release Hold", detail: "Night Light")
            ),
            (
                "Wait",
                120,
                .init(title: "Wait", detail: "2 min")
            ),
            (
                "SceneApply",
                ["Identifier": "Evening", "Priority": 2, "Timing": 120],
                .init(
                    title: "Apply Scene",
                    detail: "Evening • P-2 • 2 min transition"
                )
            ),
            (
                "SceneActivate",
                [
                    "Identifier": "Evening",
                    "Priority": 2,
                    "Timing": 120,
                    "ReleaseTiming": 0.5,
                ],
                .init(
                    title: "Activate Scene",
                    detail: "Evening • P-2 • 2 min transition • "
                        + "0.5 sec return"
                )
            ),
            (
                "SceneClear",
                ["Identifier": "Evening", "Timing": 10],
                .init(
                    title: "Deactivate Scene",
                    detail: "Evening • 10 sec transition"
                )
            ),
            (
                "SceneClearAll",
                ["Scope": "Global", "Excluding": ["Evening", "Night"]],
                .init(
                    title: "Deactivate Scenes",
                    detail: "All global scenes except Evening and Night"
                )
            ),
            (
                "SceneToggle",
                "Evening",
                .init(title: "Toggle Scene", detail: "Evening")
            ),
            (
                "SceneSetBetween",
                [
                    "StartScenes": [
                        "Evening2Lights", "BedroomEveningLights",
                    ],
                    "EndScenes": ["BedtimeLights"],
                    "Position": 0.366_666_666_7,
                    "Priority": 1,
                    "Timing": 120,
                ],
                .init(
                    title: "Blend Scenes",
                    detail: "36.7% from Evening2Lights + "
                        + "BedroomEveningLights toward BedtimeLights • "
                        + "P-1 • 2 min transition"
                )
            ),
            (
                "SequenceSet",
                [
                    "Identifier": "Sunset",
                    "Duration": 600,
                    "Priority": 2,
                    "Timing": 2,
                    "ReleaseTiming": 3,
                ],
                .init(
                    title: "Run Sequence",
                    detail: "Sunset • 10 min duration • P-2 • "
                        + "2 sec transition • 3 sec return"
                )
            ),
            (
                "TriggerReassert",
                true,
                .init(
                    title: "Reassert Triggers",
                    detail: "Rebuild the current trigger schedule"
                )
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(
                presentation(
                    for: action(
                        type: testCase.type,
                        payload: testCase.payload
                    )
                ),
                testCase.expected,
                "Unexpected presentation for \(testCase.type)"
            )
        }
    }

    func testUnknownActionUsesReadableTitleAndLosslessJSONDetail() {
        let unknown = action(
            type: "FutureAction",
            payload: ["Keep": true]
        )
        let fallback = presentation(for: unknown)
        XCTAssertEqual(fallback.title, "Future Action")
        XCTAssertEqual(fallback.detail, #"{"Keep":true}"#)
    }

    func testControlCommandArraysUseSecondElementAsTransition() {
        let cases: [(payload: HBJSONValue, detail: String)] = [
            (
                ["Lamp", "MultilevelSwitch", 0.64],
                "Lamp.MultilevelSwitch to 0.64"
            ),
            (
                ["Lamp", "MultilevelSwitch", [0.64]],
                "Lamp.MultilevelSwitch to 0.64"
            ),
            (
                ["Lamp", "MultilevelSwitch", [0.64, 120]],
                "Lamp.MultilevelSwitch to 0.64 • 2 min transition"
            ),
            (
                ["Lamp", "Color", ["White": 2_200]],
                "Lamp.Color to 2200 K white"
            ),
            (
                ["Lamp", "Color", [["White": 2_200], 3]],
                "Lamp.Color to 2200 K white • 3 sec transition"
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(
                presentation(
                    for: action(type: "ControlSet", payload: testCase.payload)
                ).detail,
                testCase.detail
            )
        }
    }

    func testOperandRegistryCatalogAndHumanReadablePresentations() {
        let registry = AutomationOperandPresentationRegistry.standard
        XCTAssertEqual(
            registry.registeredIdentifiers,
            ["underlying", "random", "cycle", "white", "rgb", "xy"]
        )

        let cases: [(HBJSONValue, AutomationOperandPresentation)] = [
            (
                ["Underlying": true],
                .init(
                    text: "the value beneath this automation",
                    kind: .underlying
                )
            ),
            (
                ["Random": ["Values": [0, 1]]],
                .init(text: "choose 0 and 1", kind: .random)
            ),
            (
                [
                    "Random": [
                        "Values": [["White": 2_200], ["White": 3_000]],
                        "Scope": "Leaf",
                    ]
                ],
                .init(
                    text: "choose 2200 K white and 3000 K white independently for each device",
                    kind: .random
                )
            ),
            (
                [
                    "Cycle": [
                        "Values": [0, 1],
                        "Order": "Random",
                        "Scope": "Leaf",
                        "Sustain": 2,
                        "Transition": "Sustain",
                    ]
                ],
                .init(
                    text: "cycle through 0 and 1 • in random order • "
                        + "independently for each device • hold each for "
                        + "2 sec • transitions match each hold",
                    kind: .cycle
                )
            ),
            (
                [
                    "Cycle": [
                        "Values": [0, 0.5, 1],
                        "Sustain": [
                            "Cycle": [
                                "Values": [1, 3],
                                "Order": "Random",
                            ]
                        ],
                    ]
                ],
                .init(
                    text: "cycle through 0, 0.5, and 1 • "
                        + "hold for 1 sec and 3 sec in random order",
                    kind: .cycle
                )
            ),
            (
                ["White": 2_200],
                .init(text: "2200 K white", kind: .literal)
            ),
            (
                ["RGB": [1, 0.5, 0]],
                .init(text: "RGB(100%, 50%, 0%)", kind: .literal)
            ),
            (
                ["XY": [0.25, 0.4]],
                .init(text: "XY(0.25, 0.4)", kind: .literal)
            ),
            (
                ["FutureFunction": ["Mode": "future"]],
                .init(
                    text: #"{"FutureFunction":{"Mode":"future"}}"#,
                    kind: .literal
                )
            ),
        ]

        for (value, expected) in cases {
            XCTAssertEqual(registry.presentation(for: value), expected)
        }
    }

    func testMalformedKnownOperandApplicationsAreRejected() {
        let malformed: [HBJSONValue] = [
            ["Underlying": false],
            ["Underlying": true, "Future": true],
            ["Random": ["Values": []]],
            [
                "Random": [
                    "Values": [["Underlying": true]],
                ]
            ],
            ["Cycle": ["Values": [1]]],
            ["Cycle": ["Values": [0, 1], "Order": "Shuffle"]],
            ["Cycle": ["Values": [0, 1], "Transition": "Fast"]],
        ]

        for value in malformed {
            XCTAssertNil(
                AutomationOperandPresentationRegistry.standard
                    .presentation(for: value),
                "Expected malformed operand to be rejected: "
                    + value.compactConfigurationJSON
            )
        }
    }

    func testMalformedKnownActionsFallBackToTheCompleteRawAction() {
        let malformed: [(type: String, payload: HBJSONValue)] = [
            ("ControlSet", ["Lamp", "Dimmer", [0.5, -1]]),
            ("ControlToggle", ["Lamp", "Switch", 1.5]),
            (
                "ControlHold",
                [
                    "Lamp",
                    "Dimmer",
                    ["Cycle": ["Values": [0, 1]]],
                    "Hold",
                ]
            ),
            ("ControlRelease", 7),
            ("Wait", -1),
            (
                "SceneApply",
                ["Identifier": "Evening", "ReleaseTiming": 2]
            ),
            (
                "SceneActivate",
                ["Identifier": "Evening", "Future": true]
            ),
            ("SceneClear", ["Identifier": "Evening", "Priority": 2]),
            ("SceneClearAll", ["Scope": "Local"]),
            ("SceneToggle", ["Identifier": "Evening", "Timing": 2]),
            (
                "SceneSetBetween",
                [
                    "StartScenes": ["Evening"],
                    "EndScenes": ["Night"],
                ]
            ),
            ("SequenceSet", ["Identifier": "Sunset", "Duration": -1]),
            ("TriggerReassert", false),
        ]

        for testCase in malformed {
            let malformedAction = action(
                type: testCase.type,
                payload: testCase.payload
            )
            let result = presentation(for: malformedAction)
            XCTAssertEqual(
                result.detail,
                malformedAction.rawValue.compactConfigurationJSON,
                "Malformed \(testCase.type) must expose the complete raw action"
            )
        }
    }

    func testCyclingControlSetRequiresSustainedContext() {
        let cycling = action(
            type: "ControlSet",
            payload: [
                "Lights",
                "Color",
                [
                    "Cycle": [
                        "Values": [["White": 2_200], ["White": 4_000]]
                    ]
                ],
            ]
        )
        let ordinary = action(
            type: "ControlSet",
            payload: ["Lights", "Dimmer", 0.5]
        )
        let plugin = AutomationActionTypeRegistry.standard.resolve(cycling)
            .plugin

        XCTAssertFalse(
            plugin.supports(action: cycling, in: .trigger(.when))
        )
        XCTAssertTrue(
            plugin.supports(action: cycling, in: .trigger(.while))
        )
        XCTAssertTrue(plugin.supports(action: cycling, in: .scene))
        XCTAssertTrue(
            plugin.supports(action: ordinary, in: .trigger(.when))
        )
    }

    func testPriorityPresentationUsesSharedUserIntentLabel() {
        XCTAssertEqual(
            AutomationPresentationFormat.priority(
                .integer(Int64(Int32.max))
            ),
            "P-User"
        )
        XCTAssertEqual(
            AutomationPresentationFormat.priority(Int64(7)),
            "P-7"
        )
    }

    func testSceneApplyPresentationDoesNotHideUnsupportedReleaseTiming() {
        let invalidSceneApply = action(
            type: "SceneApply",
            payload: [
                "Identifier": "Evening",
                "ReleaseTiming": 2,
            ]
        )

        let result = presentation(for: invalidSceneApply)

        XCTAssertEqual(result.title, "Apply Scene")
        XCTAssertEqual(
            result.detail,
            invalidSceneApply.rawValue.compactConfigurationJSON
        )
    }

    func testWaitConfigurationAcceptsOnlyFiniteNonnegativeNumbers() throws {
        let integer = try XCTUnwrap(
            AutomationWaitActionConfiguration(
                action: action(type: "Wait", payload: 5, index: 3)
            )
        )
        XCTAssertEqual(integer.actionIndex, 3)
        XCTAssertEqual(integer.duration, 5)

        XCTAssertEqual(
            AutomationWaitActionConfiguration(
                action: action(type: "Wait", payload: 0.25)
            )?.duration,
            0.25
        )
        XCTAssertNil(
            AutomationWaitActionConfiguration(
                action: action(type: "Wait", payload: -0.1)
            )
        )
        XCTAssertNil(
            AutomationWaitActionConfiguration(
                action: action(type: "Wait", payload: "1")
            )
        )
        XCTAssertNil(
            AutomationWaitActionConfiguration(
                action: action(
                    type: "Wait",
                    payload: .number(.infinity)
                )
            )
        )
        XCTAssertNil(
            AutomationWaitActionConfiguration(
                action: action(type: "FutureWait", payload: 1)
            )
        )
    }

    func testSceneApplyLensPreservesUnknownAndUnownedFields() throws {
        let original: HBJSONValue = [
            "SceneApply": [
                "Identifier": "Evening",
                "Priority": 7,
                "Timing": 2.5,
                "ReleaseTiming": 9,
                "FutureOptions": ["Mode": "soft", "Enabled": true],
            ]
        ]
        let configuration = try XCTUnwrap(
            AutomationSceneInvocationActionConfiguration(
                action: SceneActionConfiguration(
                    index: 4,
                    rawValue: original
                ),
                actionType: "SceneApply"
            )
        )

        XCTAssertEqual(configuration.actionIndex, 4)
        XCTAssertEqual(configuration.representation, .object)
        XCTAssertEqual(configuration.identifier, "Evening")
        XCTAssertEqual(
            configuration.actionValue(
                identifier: "Late Evening",
                priority: configuration.priority,
                timing: configuration.timing,
                releaseTiming: nil,
                supportsReleaseTiming: false
            ),
            [
                "SceneApply": [
                    "Identifier": "Late Evening",
                    "Priority": 7,
                    "Timing": 2.5,
                    "ReleaseTiming": 9,
                    "FutureOptions": ["Mode": "soft", "Enabled": true],
                ]
            ]
        )
    }

    func testSceneActivateLensChangesOwnedFieldWithoutLosingExtensions()
        throws
    {
        let original: HBJSONValue = [
            "SceneActivate": [
                "Identifier": "Motion Lighting",
                "Priority": -2,
                "Timing": 0.4,
                "ReleaseTiming": 3,
                "Extension": ["Curve": [0, 0.5, 1]],
            ]
        ]
        let configuration = try XCTUnwrap(
            AutomationSceneInvocationActionConfiguration(
                action: SceneActionConfiguration(index: 1, rawValue: original),
                actionType: "SceneActivate"
            )
        )

        XCTAssertEqual(
            configuration.actionValue(
                identifier: configuration.identifier,
                priority: configuration.priority,
                timing: configuration.timing,
                releaseTiming: 6,
                supportsReleaseTiming: true
            ),
            [
                "SceneActivate": [
                    "Identifier": "Motion Lighting",
                    "Priority": -2,
                    "Timing": 0.4,
                    "ReleaseTiming": 6,
                    "Extension": ["Curve": [0, 0.5, 1]],
                ]
            ]
        )
    }

    func testSceneInvocationLensPatchesOnlyRequestedField() throws {
        let original: HBJSONValue = .object([
            "SceneActivate": .object([
                "Identifier": .string(" Motion Lighting "),
                "Priority": .number(2.0),
                "Timing": .number(3.0),
                "ReleaseTiming": .number(4.0),
                "Extension": .object(["Keep": .bool(true)]),
            ])
        ])
        let configuration = try XCTUnwrap(
            AutomationSceneInvocationActionConfiguration(
                action: SceneActionConfiguration(index: 0, rawValue: original),
                actionType: "SceneActivate"
            )
        )

        XCTAssertEqual(
            configuration.actionValue(
                identifier: "Motion Lighting v2",
                priority: nil,
                timing: nil,
                releaseTiming: nil,
                supportsReleaseTiming: true,
                patching: [.identifier]
            ),
            .object([
                "SceneActivate": .object([
                    "Identifier": .string("Motion Lighting v2"),
                    "Priority": .number(2.0),
                    "Timing": .number(3.0),
                    "ReleaseTiming": .number(4.0),
                    "Extension": .object(["Keep": .bool(true)]),
                ])
            ])
        )
    }

    func testIdentifierRepresentationStaysCompactWithoutOverrides() throws {
        let configuration = try XCTUnwrap(
            AutomationSceneInvocationActionConfiguration(
                action: action(type: "SceneApply", payload: "Evening"),
                actionType: "SceneApply"
            )
        )

        XCTAssertEqual(configuration.representation, .identifier)
        XCTAssertEqual(
            configuration.actionValue(
                identifier: "Morning",
                priority: nil,
                timing: nil,
                releaseTiming: nil,
                supportsReleaseTiming: false
            ),
            ["SceneApply": "Morning"]
        )
    }

    private func pluginIdentifiers(
        for context: AutomationActionConfigurationContext
    ) -> [String] {
        AutomationActionTypeRegistry.standard.creationPlugins(for: context)
            .map(\.identifier)
    }

    private func presentation(
        for action: SceneActionConfiguration
    ) -> AutomationActionPluginPresentation {
        AutomationActionTypeRegistry.standard.resolve(action).plugin
            .presentation(for: action)
    }

    private func action(
        type: String,
        payload: HBJSONValue,
        index: Int = 0
    ) -> SceneActionConfiguration {
        SceneActionConfiguration(
            index: index,
            rawValue: .object([type: payload])
        )
    }
}
