//
//  TriggerConfigurationRepositoryTests.swift
//  HomeBase-GUITests
//

import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class TriggerConfigurationRepositoryTests: XCTestCase {
    func testUnchangedDraftPerformsNoRemoteOperations() async throws {
        let source = triggerSource(conditionValue: 0)
        let client = TriggerConfigurationRemoteClientSpy(
            files: ["triggers/Arrival.json": source]
        )
        let repository = TriggerConfigurationRepository(client: client)
        let draft = try makeDraft(source: source)

        let outcome = try await repository.save(draft)

        guard case .unchanged(let trigger) = outcome else {
            return XCTFail("Expected an unchanged save outcome")
        }
        XCTAssertEqual(trigger.identifier, "Arrival")
        XCTAssertTrue(client.events.isEmpty)
    }

    func testChangingThenRevertingDraftPerformsNoRemoteOperations()
        async throws
    {
        let source = triggerSource(conditionValue: 0)
        let client = TriggerConfigurationRemoteClientSpy(
            files: ["triggers/Arrival.json": source]
        )
        let repository = TriggerConfigurationRepository(client: client)
        var draft = try makeDraft(source: source)
        let original = try XCTUnwrap(draft.trigger.conditions.first)

        try draft.setCondition(
            at: 0,
            rawValue: .object([
                "ControlValueEqual": .array([
                    .string("Sensor"), .string("Presence"), .integer(1),
                ])
            ])
        )
        try draft.setCondition(at: 0, rawValue: original.rawValue)

        let outcome = try await repository.save(draft)

        guard case .unchanged = outcome else {
            return XCTFail("Expected a reverted draft to be unchanged")
        }
        XCTAssertTrue(client.events.isEmpty)
    }

    func testLoadFindsTriggerInRecursiveListingAndIgnoresNonJSONFiles()
        async throws
    {
        let nestedPath = "triggers/lighting/Arrival.json"
        let client = TriggerConfigurationRemoteClientSpy(
            files: [nestedPath: triggerSource(conditionValue: 0)],
            additionalListEntries: [
                HBConfigurationFileListEntry(
                    path: "triggers/lighting",
                    kind: .directory
                ),
                HBConfigurationFileListEntry(
                    path: "triggers/notes.txt",
                    kind: .file
                ),
            ]
        )
        let repository = TriggerConfigurationRepository(client: client)

        let trigger = try await repository.loadTrigger(named: "arrival")

        XCTAssertEqual(trigger.identifier, "Arrival")
        XCTAssertEqual(trigger.source.path, nestedPath)
        XCTAssertEqual(
            client.events,
            ["reactivate", "list:triggers", "get:\(nestedPath)"]
        )
    }

    func testNewTriggerCreatesReloadsAndVerifiesDerivedFile() async throws {
        let client = TriggerConfigurationRemoteClientSpy(files: [:])
        let repository = TriggerConfigurationRepository(client: client)
        let draft = try TriggerConfigurationDraft.newTrigger()

        let outcome = try await repository.save(draft)

        guard case .saved(let trigger, let reload) = outcome else {
            return XCTFail("Expected a saved outcome")
        }
        XCTAssertEqual(trigger.identifier, "UntitledTrigger")
        XCTAssertEqual(trigger.triggerType, "When")
        XCTAssertEqual(trigger.conditions, [])
        XCTAssertEqual(trigger.actions, [])
        XCTAssertEqual(reload.name, "UntitledTrigger")
        XCTAssertNotNil(client.files["triggers/UntitledTrigger.json"])
        XCTAssertEqual(
            client.events,
            [
                "reactivate",
                "list:triggers",
                "set:triggers/UntitledTrigger.json",
                "reload:UntitledTrigger",
                "get:triggers/UntitledTrigger.json",
            ]
        )
    }

    func testNewTriggerWillNotDuplicateIdentifierInNestedFile()
        async throws
    {
        let nestedPath = "triggers/nested/Existing.json"
        let client = TriggerConfigurationRemoteClientSpy(
            files: [nestedPath: triggerSource(conditionValue: 0)]
        )
        let repository = TriggerConfigurationRepository(client: client)
        let draft = try TriggerConfigurationDraft.newTrigger(
            identifier: "arrival"
        )

        do {
            _ = try await repository.save(draft)
            XCTFail("Expected an identifier collision")
        } catch let error as TriggerConfigurationSaveError {
            guard case .triggerAlreadyExists(let identifier, let path) = error
            else {
                return XCTFail("Expected a duplicate, received \(error)")
            }
            XCTAssertEqual(identifier, "arrival")
            XCTAssertEqual(path, nestedPath)
        }

        XCTAssertEqual(
            client.events,
            ["reactivate", "list:triggers", "get:\(nestedPath)"]
        )
        XCTAssertNil(client.files["triggers/arrival.json"])
    }

    func testDirtyDraftChecksWritesReloadsAndRereadsInOrder()
        async throws
    {
        let path = "triggers/Arrival.json"
        let source = triggerSource(conditionValue: 0)
        let client = TriggerConfigurationRemoteClientSpy(files: [path: source])
        let repository = TriggerConfigurationRepository(client: client)
        var draft = try makeDraft(source: source)
        try draft.setCondition(
            at: 0,
            rawValue: .object([
                "ControlValueEqual": .array([
                    .string("Sensor"), .string("Presence"), .integer(1),
                ])
            ])
        )

        let outcome = try await repository.save(draft)

        guard case .saved(let trigger, let reload) = outcome else {
            return XCTFail("Expected a saved outcome")
        }
        XCTAssertEqual(trigger.conditions[0].payload?.arrayValue?[2], .integer(1))
        XCTAssertEqual(reload.triggerStatus, .present)
        XCTAssertEqual(
            client.events,
            [
                "reactivate",
                "get:\(path)",
                "set:\(path)",
                "reload:Arrival",
                "get:\(path)",
            ]
        )
    }

    func testChangedSourceIsRejectedBeforeWrite() async throws {
        let path = "triggers/Arrival.json"
        let source = triggerSource(conditionValue: 0)
        let client = TriggerConfigurationRemoteClientSpy(files: [path: source])
        let repository = TriggerConfigurationRepository(client: client)
        var draft = try makeDraft(source: source)
        try draft.setIdentifier("Arrived")
        client.files[path] = source.replacingOccurrences(
            of: "\"Extension\": true",
            with: "\"Extension\": false"
        )

        do {
            _ = try await repository.save(draft)
            XCTFail("Expected a revision conflict")
        } catch let error as TriggerConfigurationSaveError {
            guard case .conflict(let conflictPath) = error else {
                return XCTFail("Expected a conflict, received \(error)")
            }
            XCTAssertEqual(conflictPath, path)
        }

        XCTAssertEqual(client.events, ["reactivate", "get:\(path)"])
        XCTAssertNil(client.files["triggers/Arrived.json"])
    }

    func testIdentifierChangeRenamesWritesReloadsAndVerifiesDestination()
        async throws
    {
        let oldPath = "triggers/Arrival.json"
        let newPath = "triggers/Arrived.json"
        let source = triggerSource(conditionValue: 0)
        let client = TriggerConfigurationRemoteClientSpy(
            files: [oldPath: source]
        )
        let repository = TriggerConfigurationRepository(client: client)
        var draft = try makeDraft(source: source)
        try draft.setIdentifier("Arrived")

        let outcome = try await repository.save(draft)

        guard case .saved(let trigger, _) = outcome else {
            return XCTFail("Expected a saved outcome")
        }
        XCTAssertEqual(trigger.identifier, "Arrived")
        XCTAssertEqual(trigger.source.path, newPath)
        XCTAssertNil(client.files[oldPath])
        XCTAssertNotNil(client.files[newPath])
        XCTAssertEqual(
            client.events,
            [
                "reactivate",
                "get:\(oldPath)",
                "list:triggers",
                "get:\(oldPath)",
                "rename:\(oldPath):\(newPath)",
                "set:\(newPath)",
                "reload:Arrived",
                "get:\(newPath)",
            ]
        )
    }

    func testIdentifierChangeRejectsDuplicateBeforeMutation() async throws {
        let originalPath = "triggers/Arrival.json"
        let duplicatePath = "triggers/nested/Occupied.json"
        let originalSource = triggerSource(conditionValue: 0)
        let duplicateSource = triggerSource(
            identifier: "Occupied",
            conditionValue: 1
        )
        let client = TriggerConfigurationRemoteClientSpy(
            files: [
                originalPath: originalSource,
                duplicatePath: duplicateSource,
            ]
        )
        let repository = TriggerConfigurationRepository(client: client)
        var draft = try makeDraft(source: originalSource)
        try draft.setIdentifier("occupied")

        do {
            _ = try await repository.save(draft)
            XCTFail("Expected an identifier collision")
        } catch let error as TriggerConfigurationSaveError {
            guard case .triggerAlreadyExists(let identifier, let path) = error
            else {
                return XCTFail("Expected a duplicate, received \(error)")
            }
            XCTAssertEqual(identifier, "occupied")
            XCTAssertEqual(path, duplicatePath)
        }

        XCTAssertEqual(client.files[originalPath], originalSource)
        XCTAssertEqual(client.files[duplicatePath], duplicateSource)
        XCTAssertNil(client.files["triggers/occupied.json"])
        XCTAssertEqual(
            client.events,
            [
                "reactivate",
                "get:\(originalPath)",
                "list:triggers",
                "get:\(originalPath)",
                "get:\(duplicatePath)",
            ]
        )
    }

    func testSuccessfulReloadMustReportSavedTriggerPresent() async throws {
        let path = "triggers/Arrival.json"
        let source = triggerSource(conditionValue: 0)
        let client = TriggerConfigurationRemoteClientSpy(
            files: [path: source],
            reloadResponses: [.status(.notPresent)]
        )
        let repository = TriggerConfigurationRepository(client: client)
        var draft = try makeDraft(source: source)
        try draft.setTriggerType("While")

        do {
            _ = try await repository.save(draft)
            XCTFail("Expected reload presence validation to fail")
        } catch let error as TriggerConfigurationSaveError {
            guard case .reloadFailed(_, let recovery, let presumed) = error
            else {
                return XCTFail("Expected reload failure, received \(error)")
            }
            XCTAssertEqual(recovery.savedPath, path)
            XCTAssertEqual(presumed.triggerType, "While")
        }
        XCTAssertEqual(client.events.last, "reload:Arrival")
    }

    func testDeletingSoleTriggerDeletesFileAndReloadsItsAbsence()
        async throws
    {
        let path = "triggers/Arrival.json"
        let source = triggerSource(conditionValue: 0)
        let client = TriggerConfigurationRemoteClientSpy(
            files: [path: source],
            reloadResponses: [.status(.notPresent)]
        )
        let repository = TriggerConfigurationRepository(client: client)
        let trigger = try makeDraft(source: source).trigger

        let outcome = try await repository.delete(trigger)

        XCTAssertEqual(outcome.path, path)
        XCTAssertTrue(outcome.deletedFile)
        XCTAssertEqual(outcome.reload.triggerStatus, .notPresent)
        XCTAssertNil(client.files[path])
        XCTAssertEqual(
            client.events,
            [
                "reactivate",
                "get:\(path)",
                "delete:\(path)",
                "reload:Arrival",
            ]
        )
    }

    func testDeletingSharedTriggerPreservesOtherTriggersInFile()
        async throws
    {
        let path = "triggers/Grouped.json"
        let source = """
        [
          \(triggerSource(identifier: "Arrival", conditionValue: 0)),
          \(triggerSource(identifier: "Departure", conditionValue: 1))
        ]
        """
        let client = TriggerConfigurationRemoteClientSpy(
            files: [path: source],
            reloadResponses: [.status(.notPresent)]
        )
        let repository = TriggerConfigurationRepository(client: client)
        let document = try RemoteJSONDocument(path: path, source: source)
        let trigger = try TriggerConfigurationCatalog(documents: [document])
            .trigger(named: "Arrival")

        let outcome = try await repository.delete(trigger)

        XCTAssertFalse(outcome.deletedFile)
        let remainingSource = try XCTUnwrap(client.files[path])
        let remainingDocument = try RemoteJSONDocument(
            path: path,
            source: remainingSource
        )
        XCTAssertEqual(
            TriggerConfigurationCatalog(documents: [remainingDocument])
                .triggers.map(\.identifier),
            ["Departure"]
        )
        XCTAssertEqual(
            client.events,
            [
                "reactivate",
                "get:\(path)",
                "set:\(path)",
                "reload:Arrival",
            ]
        )
    }

    func testFailedDeletionReloadRestoresOriginalFileAndGraph()
        async throws
    {
        let path = "triggers/Arrival.json"
        let source = triggerSource(conditionValue: 0)
        let client = TriggerConfigurationRemoteClientSpy(
            files: [path: source],
            reloadResponses: [
                .failure("Graph reload failed"),
                .status(.present),
            ]
        )
        let repository = TriggerConfigurationRepository(client: client)
        let trigger = try makeDraft(source: source).trigger

        do {
            _ = try await repository.delete(trigger)
            XCTFail("Expected deletion reload failure")
        } catch let error as TriggerConfigurationDeleteError {
            guard case .reloadFailed(let message) = error else {
                return XCTFail("Expected a recovered reload failure, got \(error)")
            }
            XCTAssertTrue(message.contains("Graph reload failed"))
        }

        XCTAssertEqual(client.files[path], source)
        XCTAssertEqual(
            client.events,
            [
                "reactivate",
                "get:\(path)",
                "delete:\(path)",
                "reload:Arrival",
                "set:\(path)",
                "reload:Arrival",
            ]
        )
    }

    func testCurrentValueUsesPresentationProjection() async throws {
        let expected = HBControlGetResult(
            control: "Lamp:MultilevelSwitch",
            value: .number(0.7),
            projection: .presentation
        )
        let client = TriggerConfigurationRemoteClientSpy(
            files: [:],
            controlResult: expected
        )
        let repository = TriggerConfigurationRepository(client: client)

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

    private func makeDraft(source: String) throws
        -> TriggerConfigurationDraft
    {
        let document = try RemoteJSONDocument(
            path: "triggers/Arrival.json",
            source: source
        )
        let trigger = try TriggerConfigurationCatalog(documents: [document])
            .trigger(named: "Arrival")
        return TriggerConfigurationDraft(trigger: trigger)
    }

    private func triggerSource(
        identifier: String = "Arrival",
        conditionValue: Int
    ) -> String {
        """
        {
          "Identifier": "\(identifier)",
          "Type": "When",
          "Conditions": [
            {"ControlValueEqual": ["Sensor", "Presence", \(conditionValue)]}
          ],
          "Actions": [
            {"ControlSet": ["Lamp", "BinarySwitch", 0]}
          ],
          "Extension": true
        }
        """
    }
}

@MainActor
private final class TriggerConfigurationRemoteClientSpy:
    TriggerConfigurationRemoteClient
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

    enum ReloadResponse {
        case status(HBTriggerReloadTriggerStatus)
        case failure(String)
    }

    var files: [String: String]
    var events: [String] = []
    var reloadResponses: [ReloadResponse]
    let setFailurePaths: Set<String>
    let controlResult: HBControlGetResult?
    let deviceListResult: HBDeviceListResult?
    let topologyResult: HBTopologyListResult
    let additionalListEntries: [HBConfigurationFileListEntry]

    init(
        files: [String: String],
        reloadResponses: [ReloadResponse] = [.status(.present)],
        setFailurePaths: Set<String> = [],
        controlResult: HBControlGetResult? = nil,
        deviceListResult: HBDeviceListResult? = nil,
        topologyResult: HBTopologyListResult = HBTopologyListResult(
            devices: [],
            rooms: [],
            groups: []
        ),
        additionalListEntries: [HBConfigurationFileListEntry] = []
    ) {
        self.files = files
        self.reloadResponses = reloadResponses
        self.setFailurePaths = setFailurePaths
        self.controlResult = controlResult
        self.deviceListResult = deviceListResult
        self.topologyResult = topologyResult
        self.additionalListEntries = additionalListEntries
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
        let fileEntries = files.keys.sorted().map {
            HBConfigurationFileListEntry(path: $0, kind: .file)
        }
        return HBConfigurationFileListResult(
            path: path ?? "",
            entries: fileEntries + additionalListEntries
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

    func reloadTrigger(named name: String) async throws
        -> HBTriggerReloadResult
    {
        events.append("reload:\(name)")
        let response = reloadResponses.isEmpty
            ? ReloadResponse.status(.present)
            : reloadResponses.removeFirst()
        switch response {
        case .status(let status):
            return HBTriggerReloadResult(name: name, triggerStatus: status)
        case .failure(let message):
            throw StubError.unavailable(message)
        }
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
