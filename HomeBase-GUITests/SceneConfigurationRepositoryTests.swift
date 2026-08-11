//
//  SceneConfigurationRepositoryTests.swift
//  HomeBase-GUITests
//

import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class SceneConfigurationRepositoryTests: XCTestCase {
    func testUnchangedDraftPerformsNoRemoteOperations() async throws {
        let source = sceneSource(value: 0.25)
        let client = SceneConfigurationRemoteClientSpy(
            files: ["scenes/Evening.json": source]
        )
        let repository = SceneConfigurationRepository(client: client)
        let draft = try makeDraft(source: source)

        let outcome = try await repository.save(draft)

        guard case .unchanged(let scene) = outcome else {
            return XCTFail("Expected an unchanged save outcome")
        }
        XCTAssertEqual(scene.identifier, "Evening")
        XCTAssertTrue(client.events.isEmpty)
    }

    func testNewSceneCreatesReloadsAndVerifiesDerivedFile() async throws {
        let client = SceneConfigurationRemoteClientSpy(files: [:])
        let repository = SceneConfigurationRepository(client: client)
        let draft = try SceneConfigurationDraft.newScene()

        let outcome = try await repository.save(draft)

        guard case .saved(let scene, let reload) = outcome else {
            return XCTFail("Expected a saved outcome")
        }
        XCTAssertEqual(scene.identifier, "UntitledScene")
        XCTAssertEqual(scene.priority, 0)
        XCTAssertEqual(scene.timing, 1)
        XCTAssertEqual(scene.actions, [])
        XCTAssertEqual(reload.name, "UntitledScene")
        XCTAssertNotNil(client.files["scenes/UntitledScene.json"])
        XCTAssertEqual(
            client.events,
            [
                "reactivate",
                "list:scenes",
                "set:scenes/UntitledScene.json",
                "reload:UntitledScene",
                "get:scenes/UntitledScene.json",
            ]
        )
    }

    func testNewSceneWillNotOverwriteAnExistingDerivedFile() async throws {
        let existing = sceneSource(value: 0.25)
        let client = SceneConfigurationRemoteClientSpy(
            files: ["scenes/UntitledScene.json": existing]
        )
        let repository = SceneConfigurationRepository(client: client)
        let draft = try SceneConfigurationDraft.newScene()

        do {
            _ = try await repository.save(draft)
            XCTFail("Expected a file collision")
        } catch let error as SceneConfigurationSaveError {
            guard case .fileAlreadyExists(let path) = error else {
                return XCTFail("Expected a file collision, received \(error)")
            }
            XCTAssertEqual(path, "scenes/UntitledScene.json")
        }

        XCTAssertEqual(client.events, ["reactivate", "list:scenes"])
        XCTAssertEqual(client.files["scenes/UntitledScene.json"], existing)
    }

    func testNewSceneWillNotDuplicateAnIdentifierInAnotherFile()
        async throws
    {
        let existing = sceneSource(value: 0.25)
        let client = SceneConfigurationRemoteClientSpy(
            files: ["scenes/Lighting.json": existing]
        )
        let repository = SceneConfigurationRepository(client: client)
        let draft = try SceneConfigurationDraft.newScene(
            identifier: "Evening"
        )

        do {
            _ = try await repository.save(draft)
            XCTFail("Expected an identifier collision")
        } catch let error as SceneConfigurationSaveError {
            guard case .sceneAlreadyExists(
                let identifier,
                let path
            ) = error else {
                return XCTFail(
                    "Expected an identifier collision, received \(error)"
                )
            }
            XCTAssertEqual(identifier, "Evening")
            XCTAssertEqual(path, "scenes/Lighting.json")
        }

        XCTAssertEqual(
            client.events,
            [
                "reactivate",
                "list:scenes",
                "get:scenes/Lighting.json",
            ]
        )
        XCTAssertNil(client.files["scenes/Evening.json"])
    }

    func testNewSceneReloadFailureReportsThatTheFileWasCreated()
        async throws
    {
        let client = SceneConfigurationRemoteClientSpy(
            files: [:],
            reloadFailure: "Scene validation failed"
        )
        let repository = SceneConfigurationRepository(client: client)
        let draft = try SceneConfigurationDraft.newScene()

        do {
            _ = try await repository.save(draft)
            XCTFail("Expected a reload failure")
        } catch let error as SceneConfigurationSaveError {
            guard case .creationReloadFailed(
                let message,
                let presumedScene
            ) = error else {
                return XCTFail(
                    "Expected a creation reload failure, received \(error)"
                )
            }
            XCTAssertEqual(message, "Scene validation failed")
            XCTAssertEqual(presumedScene.identifier, "UntitledScene")
            XCTAssertEqual(
                presumedScene.source.path,
                "scenes/UntitledScene.json"
            )
        }

        XCTAssertNotNil(client.files["scenes/UntitledScene.json"])
        XCTAssertEqual(
            client.events,
            [
                "reactivate",
                "list:scenes",
                "set:scenes/UntitledScene.json",
                "reload:UntitledScene",
            ]
        )
    }

    func testDirtyDraftChecksWritesReloadsAndRereadsInOrder()
        async throws
    {
        let source = sceneSource(value: 0.25)
        let client = SceneConfigurationRemoteClientSpy(
            files: ["scenes/Evening.json": source]
        )
        let repository = SceneConfigurationRepository(client: client)
        var draft = try makeDraft(source: source)
        try draft.setControlValue(actionIndex: 0, value: 0.8)

        let outcome = try await repository.save(draft)

        guard case .saved(let scene, let reload) = outcome else {
            return XCTFail("Expected a saved outcome")
        }
        XCTAssertEqual(scene.actions[0].controlSet?.value, 0.8)
        XCTAssertEqual(reload.name, "Evening")
        XCTAssertEqual(
            client.events,
            [
                "reactivate",
                "get:scenes/Evening.json",
                "set:scenes/Evening.json",
                "reload:Evening",
                "get:scenes/Evening.json",
            ]
        )
    }

    func testChangedSourceIsRejectedBeforeWrite() async throws {
        let source = sceneSource(value: 0.25)
        let client = SceneConfigurationRemoteClientSpy(
            files: ["scenes/Evening.json": sceneSource(value: 0.5)]
        )
        let repository = SceneConfigurationRepository(client: client)
        var draft = try makeDraft(source: source)
        try draft.setControlValue(actionIndex: 0, value: 0.8)

        do {
            _ = try await repository.save(draft)
            XCTFail("Expected a source conflict")
        } catch let error as SceneConfigurationSaveError {
            guard case .conflict(let path) = error else {
                return XCTFail("Expected a conflict, received \(error)")
            }
            XCTAssertEqual(path, "scenes/Evening.json")
        }

        XCTAssertEqual(
            client.events,
            ["reactivate", "get:scenes/Evening.json"]
        )
    }

    func testRequiredFileRenameMovesWritesReloadsAndVerifiesDestination()
        async throws
    {
        let source = sceneSource(value: 0.25)
        let client = SceneConfigurationRemoteClientSpy(
            files: ["scenes/Evening.json": source]
        )
        let repository = SceneConfigurationRepository(client: client)
        var draft = try makeDraft(source: source)
        try draft.setIdentifier("LateEvening")

        let outcome = try await repository.save(draft)

        guard case .saved(let savedScene, let reload) = outcome else {
            return XCTFail("Expected a saved outcome")
        }
        XCTAssertEqual(savedScene.identifier, "LateEvening")
        XCTAssertEqual(
            savedScene.source.path,
            "scenes/LateEvening.json"
        )
        XCTAssertEqual(reload.name, "LateEvening")
        XCTAssertNil(client.files["scenes/Evening.json"])
        XCTAssertNotNil(client.files["scenes/LateEvening.json"])
        XCTAssertEqual(
            client.events,
            [
                "reactivate",
                "get:scenes/Evening.json",
                "rename:scenes/Evening.json:scenes/LateEvening.json",
                "set:scenes/LateEvening.json",
                "reload:LateEvening",
                "get:scenes/LateEvening.json",
            ]
        )
    }

    func testIdentifierChangeInSharedFileSavesWithoutRenamingFile()
        async throws
    {
        let source = """
        [
          {"Identifier":"Morning","Actions":[]},
          {"Identifier":"Evening","Actions":[]}
        ]
        """
        let client = SceneConfigurationRemoteClientSpy(
            files: ["scenes/Lighting.json": source]
        )
        let repository = SceneConfigurationRepository(client: client)
        let document = try RemoteJSONDocument(
            path: "scenes/Lighting.json",
            source: source
        )
        let scene = try SceneConfigurationCatalog(documents: [document])
            .scene(named: "Evening")
        var draft = SceneConfigurationDraft(scene: scene)
        try draft.setIdentifier("LateEvening")

        let outcome = try await repository.save(draft)

        guard case .saved(let savedScene, _) = outcome else {
            return XCTFail("Expected the shared scene file to save")
        }
        XCTAssertEqual(savedScene.identifier, "LateEvening")
        XCTAssertNotNil(client.files["scenes/Lighting.json"])
        XCTAssertNil(client.files["scenes/LateEvening.json"])
        XCTAssertEqual(
            client.events,
            [
                "reactivate",
                "get:scenes/Lighting.json",
                "set:scenes/Lighting.json",
                "reload:LateEvening",
                "get:scenes/Lighting.json",
            ]
        )
    }

    func testRenameWriteFailureMovesOriginalFileBack() async throws {
        let source = sceneSource(value: 0.25)
        let destinationPath = "scenes/LateEvening.json"
        let client = SceneConfigurationRemoteClientSpy(
            files: ["scenes/Evening.json": source],
            setFailurePaths: [destinationPath]
        )
        let repository = SceneConfigurationRepository(client: client)
        var draft = try makeDraft(source: source)
        try draft.setIdentifier("LateEvening")

        do {
            _ = try await repository.save(draft)
            XCTFail("Expected the destination write to fail")
        } catch let error as SceneConfigurationRemoteClientSpy.StubError {
            guard case .unavailable = error else {
                return XCTFail("Expected an unavailable error, received \(error)")
            }
        }

        XCTAssertEqual(client.files["scenes/Evening.json"], source)
        XCTAssertNil(client.files[destinationPath])
        XCTAssertEqual(
            client.events,
            [
                "reactivate",
                "get:scenes/Evening.json",
                "rename:scenes/Evening.json:scenes/LateEvening.json",
                "set:scenes/LateEvening.json",
                "rename:scenes/LateEvening.json:scenes/Evening.json",
            ]
        )
    }

    func testReloadFailureCarriesRevisionGuardedRecovery() async throws {
        let source = sceneSource(value: 0.25)
        let client = SceneConfigurationRemoteClientSpy(
            files: ["scenes/Evening.json": source],
            reloadFailure: "Scene validation failed"
        )
        let repository = SceneConfigurationRepository(client: client)
        var draft = try makeDraft(source: source)
        try draft.setControlValue(actionIndex: 0, value: 0.8)

        let recovery: SceneConfigurationRecovery
        do {
            _ = try await repository.save(draft)
            return XCTFail("Expected reload failure")
        } catch let error as SceneConfigurationSaveError {
            guard case .reloadFailed(
                let message,
                let carriedRecovery,
                let presumedScene
            ) = error else {
                return XCTFail("Expected reload failure, received \(error)")
            }
            XCTAssertEqual(message, "Scene validation failed")
            XCTAssertEqual(
                presumedScene.actions[0].controlSet?.value,
                0.8
            )
            recovery = carriedRecovery
        }

        XCTAssertEqual(recovery.originalSource, source)
        XCTAssertEqual(
            recovery.savedSourceRevision,
            RemoteJSONDocument.revision(
                for: client.files["scenes/Evening.json"] ?? ""
            )
        )
    }

    func testSuccessfulReloadMustReportSavedScenePresent() async throws {
        let source = sceneSource(value: 0.25)
        let client = SceneConfigurationRemoteClientSpy(
            files: ["scenes/Evening.json": source],
            reloadSceneStatus: .notPresent
        )
        let repository = SceneConfigurationRepository(client: client)
        var draft = try makeDraft(source: source)
        try draft.setControlValue(actionIndex: 0, value: 0.8)

        do {
            _ = try await repository.save(draft)
            XCTFail("Expected a missing-scene reload failure")
        } catch let error as SceneConfigurationSaveError {
            guard case .reloadFailed(let message, _, _) = error else {
                return XCTFail("Expected reload failure, received \(error)")
            }
            XCTAssertTrue(message.contains("is not present"))
        }
    }

    func testRecoveryRefusesToOverwriteASecondEdit() async throws {
        let source = sceneSource(value: 0.25)
        let saved = sceneSource(value: 0.8)
        let client = SceneConfigurationRemoteClientSpy(
            files: ["scenes/Evening.json": sceneSource(value: 0.6)]
        )
        let repository = SceneConfigurationRepository(client: client)
        let recovery = SceneConfigurationRecovery(
            savedPath: "scenes/Evening.json",
            originalPath: "scenes/Evening.json",
            originalSource: source,
            originalSceneName: "Evening",
            savedSourceRevision: RemoteJSONDocument.revision(for: saved)
        )

        do {
            _ = try await repository.restore(recovery)
            XCTFail("Expected a recovery conflict")
        } catch let error as SceneConfigurationSaveError {
            guard case .conflict = error else {
                return XCTFail("Expected a conflict, received \(error)")
            }
        }

        XCTAssertEqual(
            client.events,
            ["reactivate", "get:scenes/Evening.json"]
        )
        XCTAssertEqual(
            client.files["scenes/Evening.json"],
            sceneSource(value: 0.6)
        )
    }

    func testRenamedSceneReloadFailureCanRestoreOriginalFile() async throws {
        let source = sceneSource(value: 0.25)
        let client = SceneConfigurationRemoteClientSpy(
            files: ["scenes/Evening.json": source],
            reloadFailure: "Scene validation failed"
        )
        let repository = SceneConfigurationRepository(client: client)
        var draft = try makeDraft(source: source)
        try draft.setIdentifier("LateEvening")

        let recovery: SceneConfigurationRecovery
        do {
            _ = try await repository.save(draft)
            return XCTFail("Expected reload failure")
        } catch let error as SceneConfigurationSaveError {
            guard case .reloadFailed(
                _,
                let carriedRecovery,
                let presumedScene
            ) = error else {
                return XCTFail("Expected reload failure, received \(error)")
            }
            XCTAssertEqual(
                presumedScene.source.path,
                "scenes/LateEvening.json"
            )
            recovery = carriedRecovery
        }

        XCTAssertNil(client.files["scenes/Evening.json"])
        XCTAssertNotNil(client.files["scenes/LateEvening.json"])

        client.reloadFailure = nil
        let restored = try await repository.restore(recovery)

        XCTAssertEqual(restored.identifier, "Evening")
        XCTAssertEqual(restored.source.path, "scenes/Evening.json")
        XCTAssertEqual(client.files["scenes/Evening.json"], source)
        XCTAssertNil(client.files["scenes/LateEvening.json"])
        XCTAssertEqual(
            client.events,
            [
                "reactivate",
                "get:scenes/Evening.json",
                "rename:scenes/Evening.json:scenes/LateEvening.json",
                "set:scenes/LateEvening.json",
                "reload:LateEvening",
                "reactivate",
                "get:scenes/LateEvening.json",
                "set:scenes/LateEvening.json",
                "rename:scenes/LateEvening.json:scenes/Evening.json",
                "reload:Evening",
                "get:scenes/Evening.json",
            ]
        )
    }

    func testDeletingSoleSceneDeletesFileAndReloadsItsAbsence()
        async throws
    {
        let source = sceneSource(value: 0.25)
        let client = SceneConfigurationRemoteClientSpy(
            files: ["scenes/Evening.json": source],
            reloadSceneStatus: .notPresent
        )
        let repository = SceneConfigurationRepository(client: client)
        let scene = try makeDraft(source: source).original

        let outcome = try await repository.delete(scene)

        XCTAssertEqual(outcome.path, "scenes/Evening.json")
        XCTAssertTrue(outcome.deletedFile)
        XCTAssertEqual(outcome.reload.sceneStatus, .notPresent)
        XCTAssertNil(client.files["scenes/Evening.json"])
        XCTAssertEqual(
            client.events,
            [
                "reactivate",
                "get:scenes/Evening.json",
                "delete:scenes/Evening.json",
                "reload:Evening",
            ]
        )
    }

    func testDeletingSharedScenePreservesOtherScenesInTheFile()
        async throws
    {
        let source = """
        [
          {"Identifier":"Morning","Actions":[]},
          {"Identifier":"Evening","Actions":[]}
        ]
        """
        let path = "scenes/Lighting.json"
        let originalDocument = try RemoteJSONDocument(
            path: path,
            source: source
        )
        let scene = try SceneConfigurationCatalog(
            documents: [originalDocument]
        ).scene(named: "Evening")
        let client = SceneConfigurationRemoteClientSpy(
            files: [path: source],
            reloadSceneStatus: .notPresent
        )
        let repository = SceneConfigurationRepository(client: client)

        let outcome = try await repository.delete(scene)

        XCTAssertFalse(outcome.deletedFile)
        let remainingSource = try XCTUnwrap(client.files[path])
        let remainingDocument = try RemoteJSONDocument(
            path: path,
            source: remainingSource
        )
        let catalog = SceneConfigurationCatalog(
            documents: [remainingDocument]
        )
        XCTAssertEqual(catalog.scenes.map(\.identifier), ["Morning"])
        guard case .array(let remainingValues) = remainingDocument.root else {
            return XCTFail("Expected the shared file to remain an array")
        }
        XCTAssertEqual(remainingValues.count, 1)
        XCTAssertEqual(
            client.events,
            [
                "reactivate",
                "get:scenes/Lighting.json",
                "set:scenes/Lighting.json",
                "reload:Evening",
            ]
        )
    }

    func testDeletingSceneRejectsAChangedSourceBeforeMutation()
        async throws
    {
        let source = sceneSource(value: 0.25)
        let client = SceneConfigurationRemoteClientSpy(
            files: ["scenes/Evening.json": sceneSource(value: 0.5)],
            reloadSceneStatus: .notPresent
        )
        let repository = SceneConfigurationRepository(client: client)
        let scene = try makeDraft(source: source).original

        do {
            _ = try await repository.delete(scene)
            XCTFail("Expected a source conflict")
        } catch let error as SceneConfigurationDeleteError {
            guard case .conflict(let path) = error else {
                return XCTFail("Expected a conflict, received \(error)")
            }
            XCTAssertEqual(path, "scenes/Evening.json")
        }

        XCTAssertEqual(
            client.events,
            ["reactivate", "get:scenes/Evening.json"]
        )
        XCTAssertNotNil(client.files["scenes/Evening.json"])
    }

    func testFailedDeletionReloadRestoresTheOriginalFile()
        async throws
    {
        let source = sceneSource(value: 0.25)
        let client = SceneConfigurationRemoteClientSpy(
            files: ["scenes/Evening.json": source],
            reloadSceneStatus: .present
        )
        let repository = SceneConfigurationRepository(client: client)
        let scene = try makeDraft(source: source).original

        do {
            _ = try await repository.delete(scene)
            XCTFail("Expected the present-scene reload to fail")
        } catch let error as SceneConfigurationDeleteError {
            guard case .reloadFailed(let message) = error else {
                return XCTFail(
                    "Expected a restored reload failure, received \(error)"
                )
            }
            XCTAssertTrue(message.contains("is still present"))
        }

        XCTAssertEqual(client.files["scenes/Evening.json"], source)
        XCTAssertEqual(
            client.events,
            [
                "reactivate",
                "get:scenes/Evening.json",
                "delete:scenes/Evening.json",
                "reload:Evening",
                "set:scenes/Evening.json",
                "reload:Evening",
            ]
        )
    }

    func testCurrentValueUsesPresentationProjection() async throws {
        let expected = HBControlGetResult(
            control: "Lamp:MultilevelSwitch",
            value: 0.72,
            projection: .presentation,
            displayValue: "72%",
            valid: true
        )
        let client = SceneConfigurationRemoteClientSpy(
            files: [:],
            controlResult: expected
        )
        let repository = SceneConfigurationRepository(client: client)

        let result = try await repository.currentPresentedValue(
            for: "Lamp:MultilevelSwitch"
        )

        XCTAssertEqual(result, expected)
        XCTAssertEqual(
            client.events,
            [
                "reactivate",
                "control:Lamp:MultilevelSwitch:presentation",
            ]
        )
    }

    func testEditableDeviceCatalogRequestsTopologyAndPresentationValues()
        async throws
    {
        let expected = HBDeviceDescriptor(
            identifier: "LampIdentifier",
            addressableName: "Lamp",
            displayName: "Hall Lamp",
            moduleName: "Hue",
            controls: [
                HBControlDescriptor(
                    identifier: "MultilevelSwitch",
                    name: "Dimmer",
                    kind: "UnitInterval",
                    value: 0.72,
                    projection: .presentation,
                    metadata: [
                        "readable": true,
                        "writable": true,
                        "structured": false,
                        "minimum": 0,
                        "maximum": 1,
                    ]
                )
            ]
        )
        let expectedTopology = HBTopologyListResult(
            devices: [
                HBTopologyDeviceDescriptor(
                    identifier: "LampIdentifier",
                    addressableName: "Lamp",
                    displayName: "Hall Lamp"
                )
            ],
            rooms: [],
            groups: []
        )
        let client = SceneConfigurationRemoteClientSpy(
            files: [:],
            deviceListResult: HBDeviceListResult(
                devices: [expected],
                projection: .presentation
            ),
            topologyResult: expectedTopology
        )
        let repository = SceneConfigurationRepository(client: client)

        let catalog = try await repository.editableDeviceCatalog()

        XCTAssertEqual(catalog.devices, [expected])
        XCTAssertEqual(catalog.topology, expectedTopology)
        XCTAssertEqual(
            client.events,
            [
                "reactivate",
                "topology",
                "devices:*:recursive:values:presentation",
            ]
        )
    }

    private func makeDraft(source: String) throws
        -> SceneConfigurationDraft
    {
        let document = try RemoteJSONDocument(
            path: "scenes/Evening.json",
            source: source
        )
        let scene = try SceneConfigurationCatalog(documents: [document])
            .scene(named: "Evening")
        return SceneConfigurationDraft(scene: scene)
    }

    private func sceneSource(value: Double) -> String {
        """
        {
          "Identifier": "Evening",
          "Actions": [
            {"ControlSet": ["Lamp", "MultilevelSwitch", \(value)]}
          ],
          "Unknown": {"Preserved": true}
        }
        """
    }
}

@MainActor
private final class SceneConfigurationRemoteClientSpy:
    SceneConfigurationRemoteClient
{
    enum StubError: LocalizedError {
        case missingFile(String)
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .missingFile(let path):
                "Missing file \(path)"
            case .unavailable(let message):
                message
            }
        }
    }

    var files: [String: String]
    var events: [String] = []
    var reloadFailure: String?
    var reloadSceneStatus: HBSceneReloadSceneStatus
    let setFailurePaths: Set<String>
    let controlResult: HBControlGetResult?
    let deviceListResult: HBDeviceListResult?
    let topologyResult: HBTopologyListResult

    init(
        files: [String: String],
        reloadFailure: String? = nil,
        reloadSceneStatus: HBSceneReloadSceneStatus = .present,
        setFailurePaths: Set<String> = [],
        controlResult: HBControlGetResult? = nil,
        deviceListResult: HBDeviceListResult? = nil,
        topologyResult: HBTopologyListResult = HBTopologyListResult(
            devices: [],
            rooms: [],
            groups: []
        )
    ) {
        self.files = files
        self.reloadFailure = reloadFailure
        self.reloadSceneStatus = reloadSceneStatus
        self.setFailurePaths = setFailurePaths
        self.controlResult = controlResult
        self.deviceListResult = deviceListResult
        self.topologyResult = topologyResult
    }

    func reactivate() async throws {
        events.append("reactivate")
    }

    func listTopology() async throws -> HBTopologyListResult {
        events.append("topology")
        return topologyResult
    }

    func listConfigurationFiles(
        at path: String?
    ) async throws -> HBConfigurationFileListResult {
        events.append("list:\(path ?? "")")
        return HBConfigurationFileListResult(
            path: path ?? "",
            entries: files.keys.sorted().map {
                HBConfigurationFileListEntry(path: $0, kind: .file)
            }
        )
    }

    func configurationFile(
        at path: String
    ) async throws -> HBConfigurationFileGetResult {
        events.append("get:\(path)")
        guard let contents = files[path] else {
            throw StubError.missingFile(path)
        }
        return HBConfigurationFileGetResult(path: path, contents: contents)
    }

    func setConfigurationFile(
        at path: String,
        contents: String
    ) async throws -> HBConfigurationFileSetResult {
        events.append("set:\(path)")
        if setFailurePaths.contains(path) {
            throw StubError.unavailable("Unable to write \(path)")
        }
        files[path] = contents
        return HBConfigurationFileSetResult(
            path: path,
            byteCount: contents.utf8.count
        )
    }

    func renameConfigurationFile(
        from sourcePath: String,
        to destinationPath: String
    ) async throws -> HBConfigurationFileRenameResult {
        events.append("rename:\(sourcePath):\(destinationPath)")
        guard let contents = files[sourcePath] else {
            throw StubError.missingFile(sourcePath)
        }
        guard files[destinationPath] == nil else {
            throw StubError.unavailable(
                "Destination file already exists: \(destinationPath)"
            )
        }
        files[sourcePath] = nil
        files[destinationPath] = contents
        return HBConfigurationFileRenameResult(
            sourcePath: sourcePath,
            destinationPath: destinationPath
        )
    }

    func deleteConfigurationFile(
        at path: String
    ) async throws -> HBConfigurationFileDeleteResult {
        events.append("delete:\(path)")
        guard files.removeValue(forKey: path) != nil else {
            throw StubError.missingFile(path)
        }
        return HBConfigurationFileDeleteResult(path: path)
    }

    func reloadScene(named name: String) async throws
        -> HBSceneReloadResult
    {
        events.append("reload:\(name)")
        if let reloadFailure {
            throw StubError.unavailable(reloadFailure)
        }
        return HBSceneReloadResult(name: name, sceneStatus: reloadSceneStatus)
    }

    func deviceDetails(
        named device: String,
        projection: HBControlStateProjection?
    ) async throws -> HBDeviceDescriptor {
        throw StubError.unavailable("No device fixture")
    }

    func listDevices(
        device: String?,
        recursive: Bool,
        includeValues: Bool,
        projection: HBControlStateProjection?
    ) async throws -> HBDeviceListResult {
        events.append(
            [
                "devices:\(device ?? "*")",
                recursive ? "recursive" : "shallow",
                includeValues ? "values" : "no-values",
                projection?.rawValue ?? "default",
            ].joined(separator: ":")
        )
        guard let deviceListResult else {
            throw StubError.unavailable("No device-list fixture")
        }
        return deviceListResult
    }

    func controlValue(
        _ control: String,
        projection: HBControlStateProjection
    ) async throws -> HBControlGetResult {
        events.append("control:\(control):\(projection.rawValue)")
        guard let controlResult else {
            throw StubError.unavailable("No control fixture")
        }
        return controlResult
    }
}
