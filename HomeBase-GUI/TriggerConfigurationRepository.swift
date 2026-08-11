//
//  TriggerConfigurationRepository.swift
//  HomeBase-GUI
//

import Foundation
import HomeBaseProtocol

protocol TriggerConfigurationRemoteClient: Sendable {
    func reactivate() async throws
    func listTopology() async throws -> HBTopologyListResult
    func listConfigurationFiles(
        at path: String?
    ) async throws -> HBConfigurationFileListResult
    func configurationFile(
        at path: String
    ) async throws -> HBConfigurationFileGetResult
    func setConfigurationFile(
        at path: String,
        contents: String
    ) async throws -> HBConfigurationFileSetResult
    func renameConfigurationFile(
        from sourcePath: String,
        to destinationPath: String
    ) async throws -> HBConfigurationFileRenameResult
    func deleteConfigurationFile(
        at path: String
    ) async throws -> HBConfigurationFileDeleteResult
    func reloadTrigger(named name: String) async throws
        -> HBTriggerReloadResult
    func listDevices(
        device: String?,
        recursive: Bool,
        includeValues: Bool,
        projection: HBControlStateProjection?
    ) async throws -> HBDeviceListResult
    func deviceDetails(
        named device: String,
        projection: HBControlStateProjection?
    ) async throws -> HBDeviceDescriptor
    func controlValue(
        _ control: String,
        projection: HBControlStateProjection
    ) async throws -> HBControlGetResult
}

extension HomeBaseWebSocketClient: TriggerConfigurationRemoteClient {}

struct TriggerConfigurationRecovery: Sendable {
    let savedPath: String
    let originalPath: String
    let originalSource: String
    let originalTriggerName: String
    let savedSourceRevision: String
}

struct TriggerConfigurationDeleteOutcome: Sendable {
    let path: String
    let deletedFile: Bool
    let reload: HBTriggerReloadResult
}

enum TriggerConfigurationDeleteError: LocalizedError, Sendable {
    case conflict(path: String)
    case invalidTriggerLocation(path: String, jsonPath: String)
    case reloadFailed(message: String)
    case rollbackFailed(reloadMessage: String, rollbackMessage: String)

    var errorDescription: String? {
        switch self {
        case .conflict(let path):
            "\(path) changed on the server after it was opened. Reload before deleting so another edit is not overwritten."
        case .invalidTriggerLocation(let path, let jsonPath):
            "The trigger no longer has a valid location at \(path) \(jsonPath). No file was changed."
        case .reloadFailed(let message):
            "HomeBase could not finish deleting the trigger, so the original file was restored. \(message)"
        case .rollbackFailed(let reloadMessage, let rollbackMessage):
            "The trigger file was changed, but HomeBase could not reload the deletion or restore the original state. Reload error: \(reloadMessage) Restore error: \(rollbackMessage)"
        }
    }
}

enum TriggerConfigurationSaveOutcome: Sendable {
    case unchanged(TriggerConfigurationDocument)
    case saved(
        trigger: TriggerConfigurationDocument,
        reload: HBTriggerReloadResult
    )
}

enum TriggerConfigurationSaveError: LocalizedError, Sendable {
    case conflict(path: String)
    case invalidDerivedFilename(identifier: String)
    case renameRollbackFailed(
        sourcePath: String,
        destinationPath: String,
        saveMessage: String,
        rollbackMessage: String
    )
    case fileAlreadyExists(path: String)
    case triggerAlreadyExists(identifier: String, path: String)
    case creationPreflightFailed(message: String)
    case creationReloadFailed(
        message: String,
        presumedTrigger: TriggerConfigurationDocument
    )
    case reloadFailed(
        message: String,
        recovery: TriggerConfigurationRecovery,
        presumedTrigger: TriggerConfigurationDocument
    )
    case verificationFailed(
        message: String,
        presumedTrigger: TriggerConfigurationDocument
    )

    var errorDescription: String? {
        switch self {
        case .conflict(let path):
            "\(path) changed on the server after it was opened. Reload before saving so another edit is not overwritten."
        case .invalidDerivedFilename(let identifier):
            "A safe trigger filename could not be derived from identifier \"\(identifier)\"."
        case .renameRollbackFailed(
            let sourcePath,
            let destinationPath,
            let saveMessage,
            let rollbackMessage
        ):
            "HomeBase renamed \(sourcePath) to \(destinationPath), but the edited contents could not be saved and the file could not be moved back. Save error: \(saveMessage) Rollback error: \(rollbackMessage) Reload the editor before making further changes."
        case .fileAlreadyExists(let path):
            "A configuration file already exists at \(path). No file was changed."
        case .triggerAlreadyExists(let identifier, let path):
            "A trigger named \"\(identifier)\" already exists in \(path). No file was changed."
        case .creationPreflightFailed(let message):
            "The existing trigger configuration could not be validated before creating this trigger: \(message) No file was changed."
        case .creationReloadFailed(let message, _):
            "The trigger file was created, but HomeBase could not load it: \(message)"
        case .reloadFailed(let message, _, _):
            "The file was saved, but HomeBase could not reload the trigger: \(message)"
        case .verificationFailed(let message, _):
            "HomeBase saved and reloaded the trigger, but the app could not verify the stored file: \(message)"
        }
    }
}

struct TriggerConfigurationRepository: Sendable {
    let client: any TriggerConfigurationRemoteClient

    func loadTrigger(named triggerName: String) async throws
        -> TriggerConfigurationDocument
    {
        try await client.reactivate()
        let paths = try await configurationPaths()

        var documents: [RemoteJSONDocument] = []
        var loadFailures: [String] = []
        for path in paths {
            do {
                documents.append(try await document(at: path))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                loadFailures.append("\(path): \(error.localizedDescription)")
            }
        }

        let catalog = TriggerConfigurationCatalog(documents: documents)
        do {
            return try catalog.trigger(named: triggerName)
        } catch {
            if loadFailures.isEmpty {
                throw error
            }
            throw TriggerConfigurationLoadingError(
                message: error.localizedDescription
                    + " Some trigger files could not be read: "
                    + loadFailures.joined(separator: "; ")
            )
        }
    }

    func save(
        _ draft: TriggerConfigurationDraft
    ) async throws -> TriggerConfigurationSaveOutcome {
        guard draft.isDirty else {
            return .unchanged(draft.trigger)
        }

        if draft.isNew {
            return try await create(draft)
        }

        if draft.identifierChanged,
           draft.derivesSourcePathFromIdentifier {
            guard draft.proposedSourcePath != nil else {
                throw TriggerConfigurationSaveError.invalidDerivedFilename(
                    identifier: draft.trigger.identifier ?? ""
                )
            }
        }

        let triggerName = draft.trigger.identifier
            ?? draft.original.identifier
            ?? ""
        let sourcePath = draft.original.source.path
        let rename = draft.sourceRename
        let savedPath = rename?.proposedPath ?? sourcePath
        let renderedSource = try draft.renderedSource()
        let presumedDocument = try RemoteJSONDocument(
            path: savedPath,
            source: renderedSource
        )
        let presumedTrigger = try TriggerConfigurationCatalog(
            documents: [presumedDocument]
        ).trigger(named: triggerName)

        try await client.reactivate()
        let current = try await document(at: sourcePath)
        guard current.sourceRevision == draft.original.source.sourceRevision else {
            throw TriggerConfigurationSaveError.conflict(path: sourcePath)
        }
        if draft.identifierChanged {
            try await requireAvailableIdentifier(
                triggerName,
                excluding: draft.original
            )
        }

        if let rename {
            _ = try await client.renameConfigurationFile(
                from: rename.originalPath,
                to: rename.proposedPath
            )
            do {
                _ = try await client.setConfigurationFile(
                    at: savedPath,
                    contents: renderedSource
                )
            } catch {
                let saveMessage = error.localizedDescription
                do {
                    _ = try await client.renameConfigurationFile(
                        from: rename.proposedPath,
                        to: rename.originalPath
                    )
                } catch {
                    throw TriggerConfigurationSaveError.renameRollbackFailed(
                        sourcePath: rename.originalPath,
                        destinationPath: rename.proposedPath,
                        saveMessage: saveMessage,
                        rollbackMessage: error.localizedDescription
                    )
                }
                throw error
            }
        } else {
            _ = try await client.setConfigurationFile(
                at: savedPath,
                contents: renderedSource
            )
        }

        let recovery = TriggerConfigurationRecovery(
            savedPath: savedPath,
            originalPath: sourcePath,
            originalSource: draft.original.source.originalSource,
            originalTriggerName: draft.original.identifier ?? triggerName,
            savedSourceRevision: presumedDocument.sourceRevision
        )
        let reload: HBTriggerReloadResult
        do {
            reload = try await reloadPresentTrigger(named: triggerName)
        } catch {
            throw TriggerConfigurationSaveError.reloadFailed(
                message: error.localizedDescription,
                recovery: recovery,
                presumedTrigger: presumedTrigger
            )
        }

        do {
            let verifiedDocument = try await document(at: savedPath)
            let verifiedTrigger = try TriggerConfigurationCatalog(
                documents: [verifiedDocument]
            ).trigger(named: reload.name)
            return .saved(trigger: verifiedTrigger, reload: reload)
        } catch {
            throw TriggerConfigurationSaveError.verificationFailed(
                message: error.localizedDescription,
                presumedTrigger: presumedTrigger
            )
        }
    }

    func reloadCreatedTrigger(
        _ trigger: TriggerConfigurationDocument
    ) async throws -> TriggerConfigurationSaveOutcome {
        try await client.reactivate()
        return try await reloadCreatedTriggerAfterWrite(trigger)
    }

    func restore(
        _ recovery: TriggerConfigurationRecovery
    ) async throws -> TriggerConfigurationDocument {
        try await client.reactivate()
        let current = try await document(at: recovery.savedPath)
        let originalSourceRevision = RemoteJSONDocument.revision(
            for: recovery.originalSource
        )
        guard current.sourceRevision == recovery.savedSourceRevision
                || current.sourceRevision == originalSourceRevision else {
            throw TriggerConfigurationSaveError.conflict(path: recovery.savedPath)
        }

        if current.sourceRevision != originalSourceRevision {
            _ = try await client.setConfigurationFile(
                at: recovery.savedPath,
                contents: recovery.originalSource
            )
        }
        if recovery.savedPath != recovery.originalPath {
            _ = try await client.renameConfigurationFile(
                from: recovery.savedPath,
                to: recovery.originalPath
            )
        }
        let reload = try await reloadPresentTrigger(
            named: recovery.originalTriggerName
        )
        let restored = try await document(at: recovery.originalPath)
        return try TriggerConfigurationCatalog(documents: [restored])
            .trigger(named: reload.name)
    }

    func delete(
        _ trigger: TriggerConfigurationDocument
    ) async throws -> TriggerConfigurationDeleteOutcome {
        guard let triggerName = trigger.identifier, !triggerName.isEmpty else {
            throw TriggerConfigurationDeleteError.invalidTriggerLocation(
                path: trigger.source.path,
                jsonPath: trigger.jsonPath
            )
        }

        try await client.reactivate()
        let current = try await document(at: trigger.source.path)
        guard current.sourceRevision == trigger.source.sourceRevision else {
            throw TriggerConfigurationDeleteError.conflict(
                path: trigger.source.path
            )
        }

        let remainingSource = try sourceAfterRemoving(trigger)
        if let remainingSource {
            _ = try await client.setConfigurationFile(
                at: trigger.source.path,
                contents: remainingSource
            )
        } else {
            _ = try await client.deleteConfigurationFile(
                at: trigger.source.path
            )
        }

        let reload: HBTriggerReloadResult
        do {
            reload = try await reloadMissingTrigger(named: triggerName)
        } catch {
            let reloadMessage = error.localizedDescription
            do {
                _ = try await client.setConfigurationFile(
                    at: trigger.source.path,
                    contents: trigger.source.originalSource
                )
                _ = try await reloadPresentTrigger(named: triggerName)
            } catch {
                throw TriggerConfigurationDeleteError.rollbackFailed(
                    reloadMessage: reloadMessage,
                    rollbackMessage: error.localizedDescription
                )
            }
            throw TriggerConfigurationDeleteError.reloadFailed(
                message: reloadMessage
            )
        }

        return TriggerConfigurationDeleteOutcome(
            path: trigger.source.path,
            deletedFile: remainingSource == nil,
            reload: reload
        )
    }

    private func create(
        _ draft: TriggerConfigurationDraft
    ) async throws -> TriggerConfigurationSaveOutcome {
        guard let identifier = draft.trigger.identifier,
              let path = draft.proposedSourcePath else {
            throw TriggerConfigurationSaveError.invalidDerivedFilename(
                identifier: draft.trigger.identifier ?? ""
            )
        }

        let renderedSource = try draft.renderedSource()
        let presumedDocument = try RemoteJSONDocument(
            path: path,
            source: renderedSource
        )
        let presumedTrigger = try TriggerConfigurationCatalog(
            documents: [presumedDocument]
        ).trigger(named: identifier)

        try await client.reactivate()
        let paths = try await configurationPaths()

        if let existingPath = paths.first(where: {
            $0.caseInsensitiveCompare(path) == .orderedSame
        }) {
            throw TriggerConfigurationSaveError.fileAlreadyExists(
                path: existingPath
            )
        }

        var existingDocuments: [RemoteJSONDocument] = []
        for existingPath in paths {
            do {
                existingDocuments.append(try await document(at: existingPath))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw TriggerConfigurationSaveError.creationPreflightFailed(
                    message: "\(existingPath): \(error.localizedDescription)"
                )
            }
        }

        let catalog = TriggerConfigurationCatalog(documents: existingDocuments)
        if let issue = catalog.issues.first {
            throw TriggerConfigurationSaveError.creationPreflightFailed(
                message:
                    "\(issue.sourcePath) \(issue.jsonPath): \(issue.message)"
            )
        }
        if let duplicate = catalog.triggers.first(where: {
            $0.identifier?.caseInsensitiveCompare(identifier) == .orderedSame
        }) {
            throw TriggerConfigurationSaveError.triggerAlreadyExists(
                identifier: identifier,
                path: duplicate.source.path
            )
        }

        _ = try await client.setConfigurationFile(
            at: path,
            contents: renderedSource
        )
        return try await reloadCreatedTriggerAfterWrite(presumedTrigger)
    }

    private func reloadCreatedTriggerAfterWrite(
        _ presumedTrigger: TriggerConfigurationDocument
    ) async throws -> TriggerConfigurationSaveOutcome {
        let triggerName = presumedTrigger.identifier ?? ""
        let reload: HBTriggerReloadResult
        do {
            reload = try await reloadPresentTrigger(named: triggerName)
        } catch {
            throw TriggerConfigurationSaveError.creationReloadFailed(
                message: error.localizedDescription,
                presumedTrigger: presumedTrigger
            )
        }

        do {
            let verifiedDocument = try await document(
                at: presumedTrigger.source.path
            )
            let verifiedTrigger = try TriggerConfigurationCatalog(
                documents: [verifiedDocument]
            ).trigger(named: reload.name)
            return .saved(trigger: verifiedTrigger, reload: reload)
        } catch {
            throw TriggerConfigurationSaveError.verificationFailed(
                message: error.localizedDescription,
                presumedTrigger: presumedTrigger
            )
        }
    }

    func deviceDetails(named device: String) async throws
        -> HBDeviceDescriptor
    {
        try await client.reactivate()
        return try await client.deviceDetails(
            named: device,
            projection: .presentation
        )
    }

    func editableDeviceCatalog() async throws
        -> SceneConfigurationDeviceCatalog
    {
        try await client.reactivate()
        let topology = try await client.listTopology()
        let devices = try await client.listDevices(
            device: nil,
            recursive: true,
            includeValues: true,
            projection: .presentation
        ).devices
        return SceneConfigurationDeviceCatalog(
            topology: topology,
            devices: devices
        )
    }

    func currentPresentedValue(
        for controlPath: String
    ) async throws -> HBControlGetResult {
        try await client.reactivate()
        return try await client.controlValue(
            controlPath,
            projection: .presentation
        )
    }

    private func configurationPaths() async throws -> [String] {
        let listing = try await client.listConfigurationFiles(at: "triggers")
        return listing.entries.compactMap { entry -> String? in
            guard entry.kind == .file,
                  (entry.path as NSString).pathExtension
                    .caseInsensitiveCompare("json") == .orderedSame else {
                return nil
            }
            return entry.path
        }.sorted()
    }

    private func requireAvailableIdentifier(
        _ identifier: String,
        excluding original: TriggerConfigurationDocument
    ) async throws {
        var documents: [RemoteJSONDocument] = []
        for path in try await configurationPaths() {
            documents.append(try await document(at: path))
        }
        let catalog = TriggerConfigurationCatalog(documents: documents)
        if let duplicate = catalog.triggers.first(where: { candidate in
            candidate.identifier?.caseInsensitiveCompare(identifier)
                == .orderedSame
                && !sameLocation(candidate, original)
        }) {
            throw TriggerConfigurationSaveError.triggerAlreadyExists(
                identifier: identifier,
                path: duplicate.source.path
            )
        }
    }

    private func sameLocation(
        _ lhs: TriggerConfigurationDocument,
        _ rhs: TriggerConfigurationDocument
    ) -> Bool {
        lhs.source.path == rhs.source.path && lhs.rootIndex == rhs.rootIndex
    }

    private func document(at path: String) async throws
        -> RemoteJSONDocument
    {
        let result = try await client.configurationFile(at: path)
        guard result.path == path else {
            throw TriggerConfigurationLoadingError(
                message: "HomeBase returned a different configuration file."
            )
        }
        return try RemoteJSONDocument(path: result.path, source: result.contents)
    }

    private func sourceAfterRemoving(
        _ trigger: TriggerConfigurationDocument
    ) throws -> String? {
        switch (trigger.source.root, trigger.rootIndex) {
        case (.object, nil):
            return nil

        case (.array(var values), .some(let index))
            where values.indices.contains(index):
            if values.count == 1 {
                return nil
            }
            values.remove(at: index)
            return try HBJSONValue.array(values)
                .configurationJSONSource(prettyPrinted: true) + "\n"

        default:
            throw TriggerConfigurationDeleteError.invalidTriggerLocation(
                path: trigger.source.path,
                jsonPath: trigger.jsonPath
            )
        }
    }

    private func reloadPresentTrigger(
        named triggerName: String
    ) async throws -> HBTriggerReloadResult {
        let result = try await client.reloadTrigger(named: triggerName)
        guard result.triggerStatus == .present else {
            throw TriggerConfigurationLoadingError(
                message:
                    "The automation graph reloaded, but trigger \"\(triggerName)\" is not present."
            )
        }
        return result
    }

    private func reloadMissingTrigger(
        named triggerName: String
    ) async throws -> HBTriggerReloadResult {
        let result = try await client.reloadTrigger(named: triggerName)
        guard result.triggerStatus == .notPresent else {
            throw TriggerConfigurationLoadingError(
                message:
                    "The automation graph reloaded, but trigger \"\(triggerName)\" is still present."
            )
        }
        return result
    }
}

extension TriggerConfigurationRepository: AutomationControlRepository {}

struct TriggerConfigurationLoadingError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}
