//
//  SceneConfigurationRepository.swift
//  HomeBase-GUI
//

import Foundation
import HomeBaseProtocol

protocol SceneLiveEditingRemoteClient: Sendable {
    func reactivate() async throws
    func currentSessionIdentifier() async -> UUID?
    func holdControl(
        _ control: String,
        at value: HBJSONValue,
        transitionSeconds: TimeInterval?,
        priority: Int?,
        lifetime: HBControlHoldLifetime?
    ) async throws -> HBControlHoldResult
    func releaseControlHold(token: String) async throws
        -> HBControlReleaseResult
}

protocol SceneConfigurationRemoteClient: SceneLiveEditingRemoteClient {
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
    func reloadScene(named name: String) async throws -> HBSceneReloadResult
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

extension HomeBaseWebSocketClient: SceneConfigurationRemoteClient {}

struct SceneConfigurationDeviceCatalog: Equatable, Sendable {
    let topology: HBTopologyListResult
    let devices: [HBDeviceDescriptor]
}

struct SceneConfigurationRecovery: Sendable {
    let savedPath: String
    let originalPath: String
    let originalSource: String
    let originalSceneName: String
    let savedSourceRevision: String
}

struct SceneConfigurationDeleteOutcome: Sendable {
    let path: String
    let deletedFile: Bool
    let reload: HBSceneReloadResult
}

enum SceneConfigurationDeleteError: LocalizedError, Sendable {
    case conflict(path: String)
    case invalidSceneLocation(path: String, jsonPath: String)
    case reloadFailed(message: String)
    case rollbackFailed(reloadMessage: String, rollbackMessage: String)

    var errorDescription: String? {
        switch self {
        case .conflict(let path):
            "\(path) changed on the server after it was opened. Reload before deleting so another edit is not overwritten."
        case .invalidSceneLocation(let path, let jsonPath):
            "The scene no longer has a valid location at \(path) \(jsonPath). No file was changed."
        case .reloadFailed(let message):
            "HomeBase could not finish deleting the scene, so the original file was restored. \(message)"
        case .rollbackFailed(let reloadMessage, let rollbackMessage):
            "The scene file was changed, but HomeBase could not reload the deletion or restore the original state. Reload error: \(reloadMessage) Restore error: \(rollbackMessage)"
        }
    }
}

enum SceneConfigurationSaveOutcome: Sendable {
    case unchanged(SceneConfigurationDocument)
    case saved(
        scene: SceneConfigurationDocument,
        reload: HBSceneReloadResult
    )
}

enum SceneConfigurationSaveError: LocalizedError, Sendable {
    case conflict(path: String)
    case invalidDerivedFilename(identifier: String)
    case renameRollbackFailed(
        sourcePath: String,
        destinationPath: String,
        saveMessage: String,
        rollbackMessage: String
    )
    case fileAlreadyExists(path: String)
    case sceneAlreadyExists(identifier: String, path: String)
    case creationPreflightFailed(message: String)
    case creationReloadFailed(
        message: String,
        presumedScene: SceneConfigurationDocument
    )
    case reloadFailed(
        message: String,
        recovery: SceneConfigurationRecovery,
        presumedScene: SceneConfigurationDocument
    )
    case verificationFailed(
        message: String,
        presumedScene: SceneConfigurationDocument
    )

    var errorDescription: String? {
        switch self {
        case .conflict(let path):
            "\(path) changed on the server after it was opened. Reload before saving so another edit is not overwritten."
        case .invalidDerivedFilename(let identifier):
            "A safe scene filename could not be derived from identifier \"\(identifier)\"."
        case .renameRollbackFailed(
            let sourcePath,
            let destinationPath,
            let saveMessage,
            let rollbackMessage
        ):
            "HomeBase renamed \(sourcePath) to \(destinationPath), but the edited contents could not be saved and the file could not be moved back. Save error: \(saveMessage) Rollback error: \(rollbackMessage) Reload the editor before making further changes."
        case .fileAlreadyExists(let path):
            "A configuration file already exists at \(path). No file was changed."
        case .sceneAlreadyExists(let identifier, let path):
            "A scene named \"\(identifier)\" already exists in \(path). No file was changed."
        case .creationPreflightFailed(let message):
            "The existing scene configuration could not be validated before creating this scene: \(message) No file was changed."
        case .creationReloadFailed(let message, _):
            "The scene file was created, but HomeBase could not load it: \(message)"
        case .reloadFailed(let message, _, _):
            "The file was saved, but HomeBase could not reload the scene: \(message)"
        case .verificationFailed(let message, _):
            "HomeBase saved and reloaded the scene, but the app could not verify the stored file: \(message)"
        }
    }
}

struct SceneConfigurationRepository: Sendable {
    let client: any SceneConfigurationRemoteClient

    func loadScene(named sceneName: String) async throws
        -> SceneConfigurationDocument
    {
        try await client.reactivate()
        let listing = try await client.listConfigurationFiles(at: "scenes")
        let paths = listing.entries.compactMap { entry -> String? in
            guard entry.kind == .file,
                  (entry.path as NSString).pathExtension
                    .caseInsensitiveCompare("json") == .orderedSame else {
                return nil
            }
            return entry.path
        }.sorted()

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

        let catalog = SceneConfigurationCatalog(documents: documents)
        do {
            return try catalog.scene(named: sceneName)
        } catch {
            if loadFailures.isEmpty {
                throw error
            }
            throw SceneConfigurationLoadingError(
                message: error.localizedDescription
                    + " Some scene files could not be read: "
                    + loadFailures.joined(separator: "; ")
            )
        }
    }

    func save(
        _ draft: SceneConfigurationDraft
    ) async throws -> SceneConfigurationSaveOutcome {
        guard draft.isDirty else {
            return .unchanged(draft.scene)
        }

        if draft.isNew {
            return try await create(draft)
        }

        if draft.identifierChanged,
           draft.derivesSourcePathFromIdentifier {
            guard draft.proposedSourcePath != nil else {
                throw SceneConfigurationSaveError.invalidDerivedFilename(
                    identifier: draft.scene.identifier ?? ""
                )
            }
        }

        let sceneName = draft.scene.identifier
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
        let presumedScene = try SceneConfigurationCatalog(
            documents: [presumedDocument]
        ).scene(named: sceneName)

        try await client.reactivate()
        let current = try await document(at: sourcePath)
        guard current.sourceRevision == draft.original.source.sourceRevision else {
            throw SceneConfigurationSaveError.conflict(
                path: sourcePath
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
                    throw SceneConfigurationSaveError.renameRollbackFailed(
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

        let recovery = SceneConfigurationRecovery(
            savedPath: savedPath,
            originalPath: sourcePath,
            originalSource: draft.original.source.originalSource,
            originalSceneName: draft.original.identifier ?? sceneName,
            savedSourceRevision: presumedDocument.sourceRevision
        )
        let reload: HBSceneReloadResult
        do {
            reload = try await reloadPresentScene(named: sceneName)
        } catch {
            throw SceneConfigurationSaveError.reloadFailed(
                message: error.localizedDescription,
                recovery: recovery,
                presumedScene: presumedScene
            )
        }

        do {
            let verifiedDocument = try await document(
                at: savedPath
            )
            let verifiedScene = try SceneConfigurationCatalog(
                documents: [verifiedDocument]
            ).scene(named: reload.name)
            return .saved(scene: verifiedScene, reload: reload)
        } catch {
            throw SceneConfigurationSaveError.verificationFailed(
                message: error.localizedDescription,
                presumedScene: presumedScene
            )
        }
    }

    func reloadCreatedScene(
        _ scene: SceneConfigurationDocument
    ) async throws -> SceneConfigurationSaveOutcome {
        try await client.reactivate()
        return try await reloadCreatedSceneAfterWrite(scene)
    }

    func restore(
        _ recovery: SceneConfigurationRecovery
    ) async throws -> SceneConfigurationDocument {
        try await client.reactivate()
        let current = try await document(at: recovery.savedPath)
        let originalSourceRevision = RemoteJSONDocument.revision(
            for: recovery.originalSource
        )
        guard current.sourceRevision == recovery.savedSourceRevision
                || current.sourceRevision == originalSourceRevision else {
            throw SceneConfigurationSaveError.conflict(path: recovery.savedPath)
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
        let reload = try await reloadPresentScene(
            named: recovery.originalSceneName
        )
        let restored = try await document(at: recovery.originalPath)
        return try SceneConfigurationCatalog(documents: [restored])
            .scene(named: reload.name)
    }

    func delete(
        _ scene: SceneConfigurationDocument
    ) async throws -> SceneConfigurationDeleteOutcome {
        guard let sceneName = scene.identifier, !sceneName.isEmpty else {
            throw SceneConfigurationDeleteError.invalidSceneLocation(
                path: scene.source.path,
                jsonPath: scene.jsonPath
            )
        }

        try await client.reactivate()
        let current = try await document(at: scene.source.path)
        guard current.sourceRevision == scene.source.sourceRevision else {
            throw SceneConfigurationDeleteError.conflict(
                path: scene.source.path
            )
        }

        let remainingSource = try sourceAfterRemoving(scene)
        if let remainingSource {
            _ = try await client.setConfigurationFile(
                at: scene.source.path,
                contents: remainingSource
            )
        } else {
            _ = try await client.deleteConfigurationFile(
                at: scene.source.path
            )
        }

        let reload: HBSceneReloadResult
        do {
            reload = try await reloadMissingScene(named: sceneName)
        } catch {
            let reloadMessage = error.localizedDescription
            do {
                _ = try await client.setConfigurationFile(
                    at: scene.source.path,
                    contents: scene.source.originalSource
                )
                _ = try await reloadPresentScene(named: sceneName)
            } catch {
                throw SceneConfigurationDeleteError.rollbackFailed(
                    reloadMessage: reloadMessage,
                    rollbackMessage: error.localizedDescription
                )
            }
            throw SceneConfigurationDeleteError.reloadFailed(
                message: reloadMessage
            )
        }

        return SceneConfigurationDeleteOutcome(
            path: scene.source.path,
            deletedFile: remainingSource == nil,
            reload: reload
        )
    }

    private func create(
        _ draft: SceneConfigurationDraft
    ) async throws -> SceneConfigurationSaveOutcome {
        guard let identifier = draft.scene.identifier,
              let path = draft.proposedSourcePath else {
            throw SceneConfigurationSaveError.invalidDerivedFilename(
                identifier: draft.scene.identifier ?? ""
            )
        }

        let renderedSource = try draft.renderedSource()
        let presumedDocument = try RemoteJSONDocument(
            path: path,
            source: renderedSource
        )
        let presumedScene = try SceneConfigurationCatalog(
            documents: [presumedDocument]
        ).scene(named: identifier)

        try await client.reactivate()
        let listing = try await client.listConfigurationFiles(at: "scenes")
        let paths = listing.entries.compactMap { entry -> String? in
            guard entry.kind == .file,
                  (entry.path as NSString).pathExtension
                    .caseInsensitiveCompare("json") == .orderedSame else {
                return nil
            }
            return entry.path
        }.sorted()

        if let existingPath = paths.first(where: {
            $0.caseInsensitiveCompare(path) == .orderedSame
        }) {
            throw SceneConfigurationSaveError.fileAlreadyExists(
                path: existingPath
            )
        }

        var existingDocuments: [RemoteJSONDocument] = []
        for existingPath in paths {
            do {
                existingDocuments.append(
                    try await document(at: existingPath)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SceneConfigurationSaveError.creationPreflightFailed(
                    message:
                        "\(existingPath): \(error.localizedDescription)"
                )
            }
        }

        let catalog = SceneConfigurationCatalog(documents: existingDocuments)
        if let issue = catalog.issues.first {
            throw SceneConfigurationSaveError.creationPreflightFailed(
                message:
                    "\(issue.sourcePath) \(issue.jsonPath): \(issue.message)"
            )
        }
        if let duplicate = catalog.scenes.first(where: {
            $0.identifier?.caseInsensitiveCompare(identifier) == .orderedSame
        }) {
            throw SceneConfigurationSaveError.sceneAlreadyExists(
                identifier: identifier,
                path: duplicate.source.path
            )
        }

        _ = try await client.setConfigurationFile(
            at: path,
            contents: renderedSource
        )
        return try await reloadCreatedSceneAfterWrite(presumedScene)
    }

    private func reloadCreatedSceneAfterWrite(
        _ presumedScene: SceneConfigurationDocument
    ) async throws -> SceneConfigurationSaveOutcome {
        let sceneName = presumedScene.identifier ?? ""
        let reload: HBSceneReloadResult
        do {
            reload = try await reloadPresentScene(named: sceneName)
        } catch {
            throw SceneConfigurationSaveError.creationReloadFailed(
                message: error.localizedDescription,
                presumedScene: presumedScene
            )
        }

        do {
            let verifiedDocument = try await document(
                at: presumedScene.source.path
            )
            let verifiedScene = try SceneConfigurationCatalog(
                documents: [verifiedDocument]
            ).scene(named: reload.name)
            return .saved(scene: verifiedScene, reload: reload)
        } catch {
            throw SceneConfigurationSaveError.verificationFailed(
                message: error.localizedDescription,
                presumedScene: presumedScene
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

    private func document(at path: String) async throws
        -> RemoteJSONDocument
    {
        let result = try await client.configurationFile(at: path)
        guard result.path == path else {
            throw SceneConfigurationLoadingError(
                message: "HomeBase returned a different configuration file."
            )
        }
        return try RemoteJSONDocument(path: result.path, source: result.contents)
    }

    private func sourceAfterRemoving(
        _ scene: SceneConfigurationDocument
    ) throws -> String? {
        switch (scene.source.root, scene.rootIndex) {
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
            throw SceneConfigurationDeleteError.invalidSceneLocation(
                path: scene.source.path,
                jsonPath: scene.jsonPath
            )
        }
    }

    private func reloadPresentScene(
        named sceneName: String
    ) async throws -> HBSceneReloadResult {
        let result = try await client.reloadScene(named: sceneName)
        guard result.sceneStatus == .present else {
            throw SceneConfigurationLoadingError(
                message:
                    "The automation graph reloaded, but scene \"\(sceneName)\" is not present."
            )
        }
        return result
    }

    private func reloadMissingScene(
        named sceneName: String
    ) async throws -> HBSceneReloadResult {
        let result = try await client.reloadScene(named: sceneName)
        guard result.sceneStatus == .notPresent else {
            throw SceneConfigurationLoadingError(
                message:
                    "The automation graph reloaded, but scene \"\(sceneName)\" is still present."
            )
        }
        return result
    }
}

struct SceneConfigurationLoadingError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}
