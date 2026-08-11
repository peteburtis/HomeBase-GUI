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

    func testRequiredFileRenameFailsBeforeAnyRemoteOperation() async throws {
        let source = sceneSource(value: 0.25)
        let client = SceneConfigurationRemoteClientSpy(
            files: ["scenes/Evening.json": source]
        )
        let repository = SceneConfigurationRepository(client: client)
        var draft = try makeDraft(source: source)
        try draft.setIdentifier("LateEvening")

        do {
            _ = try await repository.save(draft)
            XCTFail("Expected an unsupported file rename")
        } catch let error as SceneConfigurationSaveError {
            guard case .fileRenameUnsupported(let rename) = error else {
                return XCTFail(
                    "Expected an unsupported file rename, received \(error)"
                )
            }
            XCTAssertEqual(rename.originalPath, "scenes/Evening.json")
            XCTAssertEqual(rename.proposedPath, "scenes/LateEvening.json")
        }

        XCTAssertTrue(client.events.isEmpty)
        XCTAssertEqual(client.files["scenes/Evening.json"], source)
        XCTAssertNil(client.files["scenes/LateEvening.json"])
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

    func testRecoveryRefusesToOverwriteASecondEdit() async throws {
        let source = sceneSource(value: 0.25)
        let saved = sceneSource(value: 0.8)
        let client = SceneConfigurationRemoteClientSpy(
            files: ["scenes/Evening.json": sceneSource(value: 0.6)]
        )
        let repository = SceneConfigurationRepository(client: client)
        let recovery = SceneConfigurationRecovery(
            path: "scenes/Evening.json",
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
    let reloadFailure: String?
    let controlResult: HBControlGetResult?
    let deviceListResult: HBDeviceListResult?
    let topologyResult: HBTopologyListResult

    init(
        files: [String: String],
        reloadFailure: String? = nil,
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
        files[path] = contents
        return HBConfigurationFileSetResult(
            path: path,
            byteCount: contents.utf8.count
        )
    }

    func reloadScene(named name: String) async throws
        -> HBSceneReloadResult
    {
        events.append("reload:\(name)")
        if let reloadFailure {
            throw StubError.unavailable(reloadFailure)
        }
        return HBSceneReloadResult(name: name)
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
