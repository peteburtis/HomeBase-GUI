//
//  TriggerConfigurationDocumentTests.swift
//  HomeBase-GUITests
//

import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

final class TriggerConfigurationDocumentTests: XCTestCase {
    func testSingleObjectTriggerRetainsSourceConditionsActionsAndUnknownContent()
        throws
    {
        let source = """
        {
          "Identifier": "Arrival",
          "Type": "When",
          "Conditions": [
            {"ControlValueGreaterThan": ["Sensor", "Presence", 0.5]}
          ],
          "Actions": [
            {"ControlSet": ["Lamp", "BinarySwitch", 1, {"Timing": 2}]}
          ],
          "Extension": {"Keep": true}
        }
        """
        let document = try RemoteJSONDocument(
            path: "triggers/nested/Arrival.json",
            source: source
        )

        let trigger = try TriggerConfigurationCatalog(documents: [document])
            .trigger(named: "arrival")

        XCTAssertEqual(trigger.source.originalSource, source)
        XCTAssertEqual(trigger.jsonPath, "$")
        XCTAssertEqual(trigger.identifier, "Arrival")
        XCTAssertEqual(trigger.triggerType, "When")
        XCTAssertEqual(trigger.kind, .when)
        XCTAssertEqual(trigger.conditions.count, 1)
        XCTAssertEqual(trigger.conditions[0].type, "ControlValueGreaterThan")
        XCTAssertEqual(
            trigger.conditions[0].payload,
            .array([.string("Sensor"), .string("Presence"), .number(0.5)])
        )
        XCTAssertEqual(trigger.actions.count, 1)
        XCTAssertEqual(trigger.actions[0].controlSet?.device, "Lamp")
        XCTAssertEqual(trigger.actions[0].controlSet?.trailingValues.count, 1)
        XCTAssertEqual(trigger.additionalFields.map(\.key), ["Extension"])
        XCTAssertTrue(trigger.occupiesEntireSourceFile)
    }

    func testArrayCatalogRecordsStableLocationsAndReportsMalformedMembers()
        throws
    {
        let document = try RemoteJSONDocument(
            path: "triggers/Grouped.json",
            source: """
            [
              {
                "Identifier": "First",
                "Type": "When",
                "Conditions": [],
                "Actions": []
              },
              42,
              {
                "Identifier": "Second",
                "Type": "While",
                "Conditions": [],
                "Actions": []
              }
            ]
            """
        )

        let catalog = TriggerConfigurationCatalog(documents: [document])

        XCTAssertEqual(catalog.triggers.map(\.identifier), ["First", "Second"])
        XCTAssertEqual(catalog.triggers.map(\.jsonPath), ["$[0]", "$[2]"])
        XCTAssertEqual(catalog.issues.count, 1)
        XCTAssertEqual(catalog.issues[0].jsonPath, "$[1]")
        XCTAssertFalse(catalog.triggers[0].occupiesEntireSourceFile)
    }

    func testDuplicateIdentifiersAreRejectedAsAmbiguous() throws {
        let first = try RemoteJSONDocument(
            path: "triggers/One.json",
            source: triggerSource(identifier: "Arrival")
        )
        let second = try RemoteJSONDocument(
            path: "triggers/nested/Two.json",
            source: triggerSource(identifier: "arrival")
        )
        let catalog = TriggerConfigurationCatalog(documents: [first, second])

        XCTAssertThrowsError(try catalog.trigger(named: "ARRIVAL")) { error in
            guard case TriggerConfigurationCatalog.LookupError.ambiguous(
                let name,
                let locations
            ) = error else {
                return XCTFail("Expected an ambiguous lookup, received \(error)")
            }
            XCTAssertEqual(name, "ARRIVAL")
            XCTAssertEqual(locations.count, 2)
        }
    }

    func testDraftChangesOnlySelectedConditionAndControlSet() throws {
        let originalSource = """
        {
          "Identifier": "Arrival",
          "Type": "When",
          "Conditions": [
            {"DayOfWeek": [1, 2, 3]},
            {"ControlValueEqual": ["Sensor", "Presence", 0]}
          ],
          "Actions": [
            {"ControlSet": ["Lamp", "BinarySwitch", 0]},
            {"ExtensionAction": {"Untouched": true}}
          ],
          "Extension": {"Keep": [1, 2, 3]}
        }
        """
        let originalDocument = try RemoteJSONDocument(
            path: "triggers/Arrival.json",
            source: originalSource
        )
        let original = try TriggerConfigurationCatalog(
            documents: [originalDocument]
        ).trigger(named: "Arrival")
        var draft = TriggerConfigurationDraft(trigger: original)

        try draft.setCondition(
            at: 1,
            rawValue: .object([
                "ControlValueEqual": .array([
                    .string("Sensor"),
                    .string("Presence"),
                    .integer(1),
                ])
            ])
        )
        try draft.setControlValue(actionIndex: 0, value: .integer(1))

        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(draft.trigger.conditions[0], original.conditions[0])
        XCTAssertEqual(draft.trigger.actions[1], original.actions[1])
        XCTAssertEqual(
            draft.trigger.additionalFields.first?.value,
            original.additionalFields.first?.value
        )

        let rendered = try RemoteJSONDocument(
            path: original.source.path,
            source: draft.renderedSource()
        )
        let saved = try TriggerConfigurationCatalog(documents: [rendered])
            .trigger(named: "Arrival")
        XCTAssertEqual(saved.conditions[1].payload?.arrayValue?[2], .integer(1))
        XCTAssertEqual(saved.actions[0].controlSet?.value, .integer(1))
        XCTAssertEqual(saved.actions[1], original.actions[1])
    }

    func testDraftBecomesCleanAfterChangesAreReverted() throws {
        let trigger = try makeTrigger()
        let originalCondition = try XCTUnwrap(trigger.conditions.first)
        let originalValue = try XCTUnwrap(trigger.actions.first?.controlSet?.value)
        var draft = TriggerConfigurationDraft(trigger: trigger)

        try draft.setIdentifier("Changed")
        try draft.setTriggerType("While")
        try draft.setCondition(
            at: 0,
            rawValue: .object(["DayOfWeek": .array([.integer(1)])])
        )
        try draft.setControlValue(actionIndex: 0, value: .integer(1))
        try draft.setIdentifier("Arrival")
        try draft.setTriggerType("When")
        try draft.setCondition(at: 0, rawValue: originalCondition.rawValue)
        try draft.setControlValue(actionIndex: 0, value: originalValue)

        XCTAssertFalse(draft.hasSemanticChanges)
        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(draft.root, trigger.source.root)
    }

    func testConditionMutationsValidateAndPreserveOtherConditions() throws {
        var draft = TriggerConfigurationDraft(trigger: try makeTrigger())

        XCTAssertThrowsError(
            try draft.setCondition(at: 0, rawValue: .object([:]))
        ) { error in
            XCTAssertEqual(
                error as? TriggerConfigurationDraft.MutationError,
                .invalidCondition(0)
            )
        }
        XCTAssertFalse(draft.isDirty)

        let index = try draft.appendCondition(
            .object(["SceneActivated": .string("Evening")])
        )
        XCTAssertEqual(index, 1)
        XCTAssertEqual(draft.trigger.conditions.map(\.type), [
            "ControlValueEqual", "SceneActivated",
        ])

        try draft.removeCondition(at: 1)
        XCTAssertFalse(draft.isDirty)
    }

    func testDraftAppendsAndRemovesControlSetWithoutChangingUnknownActions()
        throws
    {
        let document = try RemoteJSONDocument(
            path: "triggers/Arrival.json",
            source: """
            {
              "Identifier": "Arrival",
              "Type": "When",
              "Conditions": [],
              "Actions": [{"ExtensionAction": {"Keep": true}}]
            }
            """
        )
        let trigger = try TriggerConfigurationCatalog(documents: [document])
            .trigger(named: "Arrival")
        var draft = TriggerConfigurationDraft(trigger: trigger)

        let index = try draft.appendControlSet(
            device: "Lamp",
            control: "BinarySwitch",
            value: .integer(1)
        )

        XCTAssertEqual(index, 1)
        XCTAssertEqual(draft.trigger.actions[0], trigger.actions[0])
        XCTAssertEqual(draft.trigger.actions[1].controlSet?.controlPath,
                       "Lamp:BinarySwitch")

        try draft.removeControlSet(actionIndex: index)
        XCTAssertFalse(draft.isDirty)
    }

    func testMetadataAndDerivedPathRulesMirrorSourceShape() throws {
        var singleDraft = TriggerConfigurationDraft(trigger: try makeTrigger())
        try singleDraft.setIdentifier("Arrived")
        try singleDraft.setTriggerType("While")

        XCTAssertEqual(singleDraft.trigger.identifier, "Arrived")
        XCTAssertEqual(singleDraft.trigger.triggerType, "While")
        XCTAssertEqual(singleDraft.trigger.kind, .while)
        XCTAssertEqual(
            singleDraft.proposedSourcePath,
            "triggers/Arrived.json"
        )
        XCTAssertEqual(
            singleDraft.sourceRename,
            TriggerConfigurationSourceRename(
                originalPath: "triggers/Arrival.json",
                proposedPath: "triggers/Arrived.json"
            )
        )

        XCTAssertThrowsError(try singleDraft.setTriggerType("whenever"))
    }

    func testSharedFileDoesNotRenameWhenIdentifierChanges() throws {
        let document = try RemoteJSONDocument(
            path: "triggers/Grouped.json",
            source: "[\(triggerSource(identifier: "Arrival")),\(triggerSource(identifier: "Departure"))]"
        )
        let trigger = try TriggerConfigurationCatalog(documents: [document])
            .trigger(named: "Arrival")
        var draft = TriggerConfigurationDraft(trigger: trigger)

        try draft.setIdentifier("Arrived")

        XCTAssertFalse(draft.derivesSourcePathFromIdentifier)
        XCTAssertNil(draft.proposedSourcePath)
        XCTAssertNil(draft.sourceRename)
    }

    func testNewTriggerUsesSafeDefaultsAndDerivedFilePath() throws {
        let draft = try TriggerConfigurationDraft.newTrigger()

        XCTAssertTrue(draft.isNew)
        XCTAssertTrue(draft.isDirty)
        XCTAssertFalse(draft.hasSemanticChanges)
        XCTAssertEqual(draft.trigger.identifier, "UntitledTrigger")
        XCTAssertEqual(draft.trigger.triggerType, "When")
        XCTAssertEqual(draft.trigger.conditions, [])
        XCTAssertEqual(draft.trigger.actions, [])
        XCTAssertEqual(
            draft.proposedSourcePath,
            "triggers/UntitledTrigger.json"
        )
    }

    private func makeTrigger() throws -> TriggerConfigurationDocument {
        let document = try RemoteJSONDocument(
            path: "triggers/Arrival.json",
            source: """
            {
              "Identifier": "Arrival",
              "Type": "When",
              "Conditions": [
                {"ControlValueEqual": ["Sensor", "Presence", 0]}
              ],
              "Actions": [
                {"ControlSet": ["Lamp", "BinarySwitch", 0]}
              ],
              "Extension": true
            }
            """
        )
        return try TriggerConfigurationCatalog(documents: [document])
            .trigger(named: "Arrival")
    }

    private func triggerSource(identifier: String) -> String {
        """
        {
          "Identifier": "\(identifier)",
          "Type": "When",
          "Conditions": [],
          "Actions": []
        }
        """
    }
}
