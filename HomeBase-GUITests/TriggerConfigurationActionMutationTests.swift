//
//  TriggerConfigurationActionMutationTests.swift
//  HomeBase-GUITests
//

import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

final class TriggerConfigurationActionMutationTests: XCTestCase {
    func testGenericActionPatchChangesOnlySelectedNodeAndCanRevert()
        throws
    {
        let document = try RemoteJSONDocument(
            path: "triggers/Lighting.json",
            source: source
        )
        let trigger = try TriggerConfigurationCatalog(documents: [document])
            .trigger(named: "Lighting")
        var draft = TriggerConfigurationDraft(trigger: trigger)
        let original = draft.trigger.actions[1].rawValue
        let replacement: HBJSONValue = [
            "SceneApply": [
                "Identifier": "Late Evening",
                "FutureOption": ["Keep": true],
            ]
        ]

        try draft.setAction(at: 1, rawValue: replacement)

        XCTAssertEqual(
            draft.trigger.actions.map(\.rawValue),
            [
                ["ControlSet": ["Lamp", "BinarySwitch", 1, 7]],
                replacement,
                ["Wait": 2],
            ]
        )
        XCTAssertEqual(
            draft.trigger.fields["FutureTriggerField"],
            ["Opaque": [1, 2, 3]]
        )
        XCTAssertEqual(
            draft.root.arrayValue?.first,
            document.root.arrayValue?.first
        )

        try draft.setAction(at: 1, rawValue: original)

        XCTAssertFalse(draft.isDirty)
        XCTAssertFalse(draft.hasSemanticChanges)
        XCTAssertEqual(draft.root, document.root)
    }

    func testGenericAppendAndRemovePreserveOrderedProgram() throws {
        let document = try RemoteJSONDocument(
            path: "triggers/Lighting.json",
            source: source
        )
        let trigger = try TriggerConfigurationCatalog(documents: [document])
            .trigger(named: "Lighting")
        var draft = TriggerConfigurationDraft(trigger: trigger)
        let originalActions = draft.trigger.actions.map(\.rawValue)
        let appended: HBJSONValue = [
            "FutureAction": ["Nested": [true, false, nil]]
        ]

        let index = try draft.appendAction(appended)

        XCTAssertEqual(index, originalActions.count)
        XCTAssertEqual(
            Array(draft.trigger.actions.dropLast()).map(\.rawValue),
            originalActions
        )
        XCTAssertEqual(draft.trigger.actions.last?.rawValue, appended)

        try draft.removeAction(at: index)

        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(draft.root, document.root)
    }

    func testControlSetValuePatchPreservesPriorityAndTrailingValues() throws {
        let document = try RemoteJSONDocument(
            path: "triggers/Lighting.json",
            source: source
        )
        let trigger = try TriggerConfigurationCatalog(documents: [document])
            .trigger(named: "Lighting")
        var draft = TriggerConfigurationDraft(trigger: trigger)

        try draft.setControlValue(actionIndex: 0, value: 0)

        XCTAssertEqual(
            draft.trigger.actions[0].rawValue,
            ["ControlSet": ["Lamp", "BinarySwitch", 0, 7]]
        )
    }

    func testControlSetCommandPatchPreservesTransitionAndJSONShape() throws {
        let document = try RemoteJSONDocument(
            path: "triggers/Command.json",
            source: """
            {
              "Identifier": "Command",
              "Type": "When",
              "Conditions": [],
              "FutureTriggerField": {"Keep": true},
              "Actions": [
                {
                  "ControlSet": [
                    "Lamp",
                    "MultilevelSwitch",
                    [0.25, 3.5],
                    7,
                    {"FutureOption": [1, 2, 3]}
                  ]
                }
              ]
            }
            """
        )
        let trigger = try TriggerConfigurationCatalog(documents: [document])
            .trigger(named: "Command")
        var draft = TriggerConfigurationDraft(trigger: trigger)

        XCTAssertEqual(draft.trigger.actions[0].controlSet?.value, 0.25)

        try draft.setControlValue(actionIndex: 0, value: 0.8)

        XCTAssertEqual(draft.trigger.actions[0].controlSet?.value, 0.8)
        XCTAssertEqual(
            draft.trigger.actions[0].rawValue,
            [
                "ControlSet": [
                    "Lamp",
                    "MultilevelSwitch",
                    [0.8, 3.5],
                    7,
                    ["FutureOption": [1, 2, 3]],
                ]
            ]
        )
        XCTAssertEqual(
            draft.trigger.fields["FutureTriggerField"],
            ["Keep": true]
        )
    }

    func testInvalidGenericActionLeavesDraftClean() throws {
        let document = try RemoteJSONDocument(
            path: "triggers/Lighting.json",
            source: source
        )
        let trigger = try TriggerConfigurationCatalog(documents: [document])
            .trigger(named: "Lighting")
        var draft = TriggerConfigurationDraft(trigger: trigger)

        XCTAssertThrowsError(
            try draft.setAction(
                at: 1,
                rawValue: ["SceneApply": "Evening", "Future": true]
            )
        ) { error in
            XCTAssertEqual(
                error as? TriggerConfigurationDraft.MutationError,
                .invalidAction(1)
            )
        }
        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(draft.root, document.root)
    }

    private var source: String {
        """
        [
          {
            "Identifier": "Other",
            "Type": "When",
            "Conditions": [],
            "Actions": [{"FutureAction": {"Keep": true}}]
          },
          {
            "Identifier": "Lighting",
            "Type": "When",
            "Conditions": [],
            "FutureTriggerField": {"Opaque": [1, 2, 3]},
            "Actions": [
              {"ControlSet": ["Lamp", "BinarySwitch", 1, 7]},
              {"FutureAction": {"Nested": [1, {"Keep": true}]}},
              {"Wait": 2}
            ]
          }
        ]
        """
    }
}
