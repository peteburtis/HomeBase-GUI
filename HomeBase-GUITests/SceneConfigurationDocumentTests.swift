//
//  SceneConfigurationDocumentTests.swift
//  HomeBase-GUITests
//

import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

final class SceneConfigurationDocumentTests: XCTestCase {
    func testSingleObjectSceneRetainsSourceAndUnknownContent() throws {
        let source = """
        {
          "Identifier": "Evening",
          "Priority": 7,
          "Actions": [
            {"ControlSet": ["Lamp", "MultilevelSwitch", 0.5]},
            {"ModuleAction": {"FutureField": true}}
          ],
          "FutureTopLevelField": {"Nested": [1, 2, 3]}
        }
        """
        let document = try RemoteJSONDocument(
            path: "scenes/Evening.json",
            source: source
        )
        let catalog = SceneConfigurationCatalog(documents: [document])
        let scene = try catalog.scene(named: "Evening")

        XCTAssertEqual(scene.source.originalSource, source)
        XCTAssertEqual(scene.source.sourceRevision.count, 64)
        XCTAssertEqual(scene.jsonPath, "$")
        XCTAssertEqual(scene.identifier, "Evening")
        XCTAssertEqual(scene.actions.count, 2)
        XCTAssertEqual(scene.actions[0].type, "ControlSet")
        XCTAssertEqual(
            scene.actions[0].payload,
            ["Lamp", "MultilevelSwitch", 0.5]
        )
        XCTAssertEqual(scene.actions[1].type, "ModuleAction")
        XCTAssertEqual(
            scene.actions[1].payload,
            ["FutureField": true]
        )
        XCTAssertEqual(
            scene.fields["FutureTopLevelField"],
            ["Nested": [1, 2, 3]]
        )
        XCTAssertEqual(
            scene.additionalFields.map(\.key),
            ["FutureTopLevelField"]
        )
        XCTAssertTrue(catalog.issues.isEmpty)
    }

    func testArraySceneRecordsItsStableJSONLocation() throws {
        let document = try RemoteJSONDocument(
            path: "scenes/Lighting.json",
            source: """
            [
              {"Identifier":"Morning","Actions":[]},
              {"Identifier":"Evening","Actions":[{"Wait":5}]}
            ]
            """
        )
        let catalog = SceneConfigurationCatalog(documents: [document])

        let scene = try catalog.scene(named: "evening")
        XCTAssertEqual(scene.rootIndex, 1)
        XCTAssertEqual(scene.jsonPath, "$[1]")
        XCTAssertEqual(scene.actions.first?.type, "Wait")
        XCTAssertEqual(scene.actions.first?.payload, 5)
    }

    func testMalformedArrayMembersAreReportedWithoutHidingValidScenes()
        throws
    {
        let document = try RemoteJSONDocument(
            path: "scenes/Mixed.json",
            source: """
            [
              {"Identifier":"Valid","Actions":[]},
              "not a scene"
            ]
            """
        )
        let catalog = SceneConfigurationCatalog(documents: [document])

        XCTAssertEqual(try catalog.scene(named: "Valid").identifier, "Valid")
        XCTAssertEqual(catalog.issues.count, 1)
        XCTAssertEqual(catalog.issues.first?.jsonPath, "$[1]")
    }

    func testNonContainerRootIsReported() throws {
        let document = try RemoteJSONDocument(
            path: "scenes/Invalid.json",
            source: "42"
        )
        let catalog = SceneConfigurationCatalog(documents: [document])

        XCTAssertTrue(catalog.scenes.isEmpty)
        XCTAssertEqual(catalog.issues.first?.jsonPath, "$")
    }

    func testDuplicateIdentifiersAreRejectedAsAmbiguous() throws {
        let first = try RemoteJSONDocument(
            path: "scenes/First.json",
            source: """
            {"Identifier":"Evening","Actions":[]}
            """
        )
        let second = try RemoteJSONDocument(
            path: "scenes/Second.json",
            source: """
            {"Identifier":"evening","Actions":[]}
            """
        )
        let catalog = SceneConfigurationCatalog(documents: [first, second])

        XCTAssertThrowsError(try catalog.scene(named: "EVENING")) { error in
            guard case SceneConfigurationCatalog.LookupError.ambiguous(
                let name,
                let locations
            ) = error else {
                return XCTFail("Expected an ambiguous scene error")
            }
            XCTAssertEqual(name, "EVENING")
            XCTAssertEqual(
                locations,
                ["scenes/First.json $", "scenes/Second.json $"]
            )
        }
    }

    func testSourceRevisionChangesWithSourceFormatting() throws {
        let compact = try RemoteJSONDocument(
            path: "scenes/Scene.json",
            source: "{\"Identifier\":\"Scene\",\"Actions\":[]}"
        )
        let formatted = try RemoteJSONDocument(
            path: "scenes/Scene.json",
            source: """
            {
              "Identifier": "Scene",
              "Actions": []
            }
            """
        )

        XCTAssertEqual(compact.root, formatted.root)
        XCTAssertNotEqual(compact.sourceRevision, formatted.sourceRevision)
    }

    func testInvalidJSONCannotBecomeADocument() {
        XCTAssertThrowsError(
            try RemoteJSONDocument(
                path: "scenes/Broken.json",
                source: "{"
            )
        )
    }

    func testDraftChangesOnlyTheSelectedControlSetValue() throws {
        let source = """
        [
          {
            "Identifier": "Morning",
            "Actions": [{"ControlSet": ["Lamp", "BinarySwitch", 0]}]
          },
          {
            "Identifier": "Evening",
            "Future": {"Preserve": true},
            "Actions": [
              {"ControlSet": ["Lamp", "MultilevelSwitch", 0.25, 7]},
              {"FutureAction": [1, 2, 3]}
            ]
          }
        ]
        """
        let document = try RemoteJSONDocument(
            path: "scenes/Lighting.json",
            source: source
        )
        let scene = try SceneConfigurationCatalog(documents: [document])
            .scene(named: "Evening")
        var draft = SceneConfigurationDraft(scene: scene)

        try draft.setControlValue(actionIndex: 0, value: 0.8)

        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(draft.scene.actions[0].controlSet?.value, 0.8)
        XCTAssertEqual(
            draft.scene.actions[0].controlSet?.trailingValues,
            [7]
        )
        XCTAssertEqual(
            draft.scene.fields["Future"],
            ["Preserve": true]
        )

        let rendered = try draft.renderedSource()
        let renderedDocument = try RemoteJSONDocument(
            path: "scenes/Lighting.json",
            source: rendered
        )
        let renderedCatalog = SceneConfigurationCatalog(
            documents: [renderedDocument]
        )
        XCTAssertEqual(
            try renderedCatalog.scene(named: "Morning").actions[0]
                .controlSet?.value,
            0
        )
        XCTAssertEqual(
            try renderedCatalog.scene(named: "Evening").actions[1]
                .rawValue,
            ["FutureAction": [1, 2, 3]]
        )
    }

    func testDraftBecomesCleanWhenValueReturnsToOriginal() throws {
        let document = try RemoteJSONDocument(
            path: "scenes/Evening.json",
            source: """
            {"Identifier":"Evening","Actions":[{"ControlSet":["Lamp","MultilevelSwitch",0.25]}]}
            """
        )
        let scene = try SceneConfigurationCatalog(documents: [document])
            .scene(named: "Evening")
        var draft = SceneConfigurationDraft(scene: scene)

        try draft.setControlValue(actionIndex: 0, value: 0.8)
        XCTAssertTrue(draft.isDirty)

        try draft.setControlValue(actionIndex: 0, value: 0.25)
        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(draft.root, document.root)
    }

    func testControlSetParsingRequiresStringTargetComponents() throws {
        let document = try RemoteJSONDocument(
            path: "scenes/InvalidTarget.json",
            source: """
            {"Identifier":"InvalidTarget","Actions":[{"ControlSet":[42,"BinarySwitch",1]}]}
            """
        )
        let scene = try SceneConfigurationCatalog(documents: [document])
            .scene(named: "InvalidTarget")

        XCTAssertNil(scene.actions.first?.controlSet)
    }

    func testDraftRemovesOnlyTheSelectedControlSet() throws {
        let document = try RemoteJSONDocument(
            path: "scenes/Evening.json",
            source: """
            {
              "Identifier": "Evening",
              "Preserved": {"Future": true},
              "Actions": [
                {"ControlSet": ["Lamp", "BinarySwitch", 1]},
                {"FutureAction": [1, 2, 3]},
                {"ControlSet": ["Lamp", "MultilevelSwitch", 0.5, 7]}
              ]
            }
            """
        )
        let scene = try SceneConfigurationCatalog(documents: [document])
            .scene(named: "Evening")
        var draft = SceneConfigurationDraft(scene: scene)

        try draft.removeControlSet(actionIndex: 0)

        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(draft.scene.actions.count, 2)
        XCTAssertEqual(
            draft.scene.actions[0].rawValue,
            ["FutureAction": [1, 2, 3]]
        )
        XCTAssertEqual(
            draft.scene.actions[1].controlSet?.control,
            "MultilevelSwitch"
        )
        XCTAssertEqual(
            draft.scene.actions[1].controlSet?.trailingValues,
            [7]
        )
        XCTAssertEqual(
            draft.scene.fields["Preserved"],
            ["Future": true]
        )
    }

    func testDraftAppendsAControlSetToASceneWithoutActions() throws {
        let document = try RemoteJSONDocument(
            path: "scenes/Evening.json",
            source: """
            {"Identifier":"Evening","Future":"preserved"}
            """
        )
        let scene = try SceneConfigurationCatalog(documents: [document])
            .scene(named: "Evening")
        var draft = SceneConfigurationDraft(scene: scene)

        let index = try draft.appendControlSet(
            device: "HallLamp",
            control: "MultilevelSwitch",
            value: 0.72
        )

        XCTAssertEqual(index, 0)
        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(draft.scene.actions.count, 1)
        XCTAssertEqual(draft.scene.actions[0].controlSet?.device, "HallLamp")
        XCTAssertEqual(
            draft.scene.actions[0].controlSet?.control,
            "MultilevelSwitch"
        )
        XCTAssertEqual(draft.scene.actions[0].controlSet?.value, 0.72)
        XCTAssertEqual(draft.scene.fields["Future"], "preserved")
    }

    func testDraftWillNotRemoveAnUnknownActionAsAControlSet() throws {
        let document = try RemoteJSONDocument(
            path: "scenes/Evening.json",
            source: """
            {"Identifier":"Evening","Actions":[{"FutureAction":true}]}
            """
        )
        let scene = try SceneConfigurationCatalog(documents: [document])
            .scene(named: "Evening")
        var draft = SceneConfigurationDraft(scene: scene)

        XCTAssertThrowsError(
            try draft.removeControlSet(actionIndex: 0)
        ) { error in
            XCTAssertEqual(
                error as? SceneConfigurationDraft.MutationError,
                .actionIsNotControlSet(0)
            )
        }
        XCTAssertFalse(draft.isDirty)
    }

    func testDraftEditsIdentifierPriorityAndTimingSemantically() throws {
        let document = try RemoteJSONDocument(
            path: "scenes/Evening.json",
            source: """
            {
              "Identifier": "Evening",
              "Priority": 7,
              "Timing": 2.5,
              "Actions": [],
              "Discover": {"MinimumPriority": 3}
            }
            """
        )
        let scene = try SceneConfigurationCatalog(documents: [document])
            .scene(named: "Evening")
        var draft = SceneConfigurationDraft(scene: scene)

        try draft.setIdentifier("LateEvening")
        try draft.setPriority(-4)
        try draft.setTiming(6.25)

        XCTAssertEqual(draft.scene.identifier, "LateEvening")
        XCTAssertEqual(draft.scene.priority, -4)
        XCTAssertEqual(draft.scene.timing, 6.25)
        XCTAssertEqual(
            draft.scene.fields["Discover"],
            ["MinimumPriority": 3]
        )

        try draft.setPriority(nil)
        try draft.setTiming(nil)
        XCTAssertNil(draft.scene.fields["Priority"])
        XCTAssertNil(draft.scene.fields["Timing"])
    }

    func testSingleSceneFileRenameIsDerivedFromChangedIdentifier() throws {
        let document = try RemoteJSONDocument(
            path: "scenes/Evening.json",
            source: """
            {"Identifier":"Evening","Actions":[]}
            """
        )
        let scene = try SceneConfigurationCatalog(documents: [document])
            .scene(named: "Evening")
        var draft = SceneConfigurationDraft(scene: scene)

        try draft.setIdentifier("LateEvening")

        XCTAssertTrue(draft.derivesSourcePathFromIdentifier)
        XCTAssertEqual(
            draft.sourceRename,
            SceneConfigurationSourceRename(
                originalPath: "scenes/Evening.json",
                proposedPath: "scenes/LateEvening.json"
            )
        )
    }

    func testMultiSceneFileKeepsItsPathWhenIdentifierChanges() throws {
        let document = try RemoteJSONDocument(
            path: "scenes/Lighting.json",
            source: """
            [
              {"Identifier":"Morning","Actions":[]},
              {"Identifier":"Evening","Actions":[]}
            ]
            """
        )
        let scene = try SceneConfigurationCatalog(documents: [document])
            .scene(named: "Evening")
        var draft = SceneConfigurationDraft(scene: scene)

        try draft.setIdentifier("LateEvening")

        XCTAssertFalse(draft.derivesSourcePathFromIdentifier)
        XCTAssertNil(draft.proposedSourcePath)
        XCTAssertNil(draft.sourceRename)
        XCTAssertEqual(draft.original.source.path, "scenes/Lighting.json")
    }

    func testSingleSceneArrayCanDeriveItsFileName() throws {
        let document = try RemoteJSONDocument(
            path: "scenes/Evening.json",
            source: """
            [{"Identifier":"Evening","Actions":[]}]
            """
        )
        let scene = try SceneConfigurationCatalog(documents: [document])
            .scene(named: "Evening")
        var draft = SceneConfigurationDraft(scene: scene)

        try draft.setIdentifier("LateEvening")

        XCTAssertTrue(draft.derivesSourcePathFromIdentifier)
        XCTAssertEqual(
            draft.proposedSourcePath,
            "scenes/LateEvening.json"
        )
    }

    func testNewSceneDraftUsesUntitledDefaultsAndDerivedFilePath() throws {
        let draft = try SceneConfigurationDraft.newScene()

        XCTAssertTrue(draft.isNew)
        XCTAssertTrue(draft.isDirty)
        XCTAssertFalse(draft.hasSemanticChanges)
        XCTAssertEqual(draft.scene.identifier, "UntitledScene")
        XCTAssertEqual(draft.scene.priority, 0)
        XCTAssertEqual(draft.scene.timing, 1)
        XCTAssertEqual(draft.scene.actions, [])
        XCTAssertEqual(
            draft.proposedSourcePath,
            "scenes/UntitledScene.json"
        )
        XCTAssertNil(draft.sourceRename)
    }
}
