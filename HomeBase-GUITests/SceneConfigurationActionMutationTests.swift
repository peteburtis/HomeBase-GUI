//
//  SceneConfigurationActionMutationTests.swift
//  HomeBase-GUITests
//

import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

final class SceneConfigurationActionMutationTests: XCTestCase {
    func testGenericSetChangesOnlySelectedActionAndRevertsCleanly() throws {
        let document = try RemoteJSONDocument(
            path: "scenes/Lighting.json",
            source: source
        )
        let scene = try SceneConfigurationCatalog(documents: [document])
            .scene(named: "Evening")
        var draft = SceneConfigurationDraft(scene: scene)
        let originalAction = try XCTUnwrap(
            draft.scene.actions[safe: 1]
        ).rawValue

        let replacement: HBJSONValue = [
            "SceneApply": [
                "Identifier": "Late Evening",
                "FutureOption": ["Keep": true],
            ]
        ]
        try draft.setAction(at: 1, rawValue: replacement)

        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(
            draft.scene.actions.map(\.rawValue),
            [
                ["ControlSet": ["Lamp", "BinarySwitch", 1]],
                replacement,
                ["Wait": 2],
            ]
        )
        XCTAssertEqual(
            draft.scene.fields["FutureSceneField"],
            ["Opaque": [1, 2, 3]]
        )
        XCTAssertEqual(
            draft.root.arrayValue?.first,
            document.root.arrayValue?.first
        )

        try draft.setAction(at: 1, rawValue: originalAction)

        XCTAssertFalse(draft.isDirty)
        XCTAssertFalse(draft.hasSemanticChanges)
        XCTAssertEqual(draft.root, document.root)
    }

    func testGenericAppendPreservesOrderAndRemovingAppendRevertsCleanly()
        throws
    {
        let document = try RemoteJSONDocument(
            path: "scenes/Lighting.json",
            source: source
        )
        let scene = try SceneConfigurationCatalog(documents: [document])
            .scene(named: "Evening")
        var draft = SceneConfigurationDraft(scene: scene)
        let originalActions = draft.scene.actions.map(\.rawValue)
        let appended: HBJSONValue = [
            "FutureAction": ["Nested": [true, false, nil]]
        ]

        let index = try draft.appendAction(appended)

        XCTAssertEqual(index, originalActions.count)
        XCTAssertEqual(
            Array(draft.scene.actions.dropLast()).map(\.rawValue),
            originalActions
        )
        XCTAssertEqual(draft.scene.actions.last?.rawValue, appended)
        XCTAssertEqual(
            draft.scene.fields["FutureSceneField"],
            ["Opaque": [1, 2, 3]]
        )
        XCTAssertEqual(
            draft.root.arrayValue?.first,
            document.root.arrayValue?.first
        )

        try draft.removeAction(at: index)

        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(draft.root, document.root)
    }

    func testGenericRemovePreservesRemainingOrderAndUnknownContent() throws {
        let document = try RemoteJSONDocument(
            path: "scenes/Lighting.json",
            source: source
        )
        let scene = try SceneConfigurationCatalog(documents: [document])
            .scene(named: "Evening")
        var draft = SceneConfigurationDraft(scene: scene)

        try draft.removeAction(at: 1)

        XCTAssertEqual(
            draft.scene.actions.map(\.rawValue),
            [
                ["ControlSet": ["Lamp", "BinarySwitch", 1]],
                ["Wait": 2],
            ]
        )
        XCTAssertEqual(
            draft.scene.fields["FutureSceneField"],
            ["Opaque": [1, 2, 3]]
        )
        XCTAssertEqual(
            draft.root.arrayValue?.first,
            document.root.arrayValue?.first
        )
    }

    func testControlSetCommandPatchPreservesTransitionAndJSONShape() throws {
        let document = try RemoteJSONDocument(
            path: "scenes/Command.json",
            source: """
            {
              "Identifier": "Command",
              "FutureSceneField": {"Keep": true},
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
        let scene = try SceneConfigurationCatalog(documents: [document])
            .scene(named: "Command")
        var draft = SceneConfigurationDraft(scene: scene)

        XCTAssertEqual(draft.scene.actions[0].controlSet?.value, 0.25)

        try draft.setControlValue(actionIndex: 0, value: 0.8)

        XCTAssertEqual(draft.scene.actions[0].controlSet?.value, 0.8)
        XCTAssertEqual(
            draft.scene.actions[0].rawValue,
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
            draft.scene.fields["FutureSceneField"],
            ["Keep": true]
        )
    }

    func testInvalidGenericActionDoesNotDirtyDraft() throws {
        let document = try RemoteJSONDocument(
            path: "scenes/Lighting.json",
            source: source
        )
        let scene = try SceneConfigurationCatalog(documents: [document])
            .scene(named: "Evening")
        var draft = SceneConfigurationDraft(scene: scene)

        XCTAssertThrowsError(
            try draft.setAction(
                at: 1,
                rawValue: ["SceneApply": "Evening", "Future": true]
            )
        ) { error in
            XCTAssertEqual(
                error as? SceneConfigurationDraft.MutationError,
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
            "Identifier": "Morning",
            "Actions": [{"FutureMorningAction": {"Keep": true}}],
            "MorningExtension": [1, 2, 3]
          },
          {
            "Identifier": "Evening",
            "FutureSceneField": {"Opaque": [1, 2, 3]},
            "Actions": [
              {"ControlSet": ["Lamp", "BinarySwitch", 1]},
              {"FutureAction": {"Nested": [1, {"Keep": true}]}},
              {"Wait": 2}
            ]
          }
        ]
        """
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
