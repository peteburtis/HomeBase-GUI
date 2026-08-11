//
//  SceneConfigurationRepository.swift
//  HomeBase-GUI
//

import Foundation
import HomeBaseProtocol

protocol SceneConfigurationRemoteClient: Sendable {
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
    let path: String
    let originalSource: String
    let originalSceneName: String
    let savedSourceRevision: String
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
    case fileRenameUnsupported(SceneConfigurationSourceRename)
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
        case .fileRenameUnsupported(let rename):
            "Saving requires renaming \(rename.originalPath) to \(rename.proposedPath), but HomeBase does not yet provide the file-delete operation needed to remove the old file safely. No file was changed."
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
            if let rename = draft.sourceRename {
                throw SceneConfigurationSaveError.fileRenameUnsupported(rename)
            }
        }

        let sceneName = draft.scene.identifier
            ?? draft.original.identifier
            ?? ""
        let renderedSource = try draft.renderedSource()
        let presumedDocument = try RemoteJSONDocument(
            path: draft.original.source.path,
            source: renderedSource
        )
        let presumedScene = try SceneConfigurationCatalog(
            documents: [presumedDocument]
        ).scene(named: sceneName)

        try await client.reactivate()
        let current = try await document(at: draft.original.source.path)
        guard current.sourceRevision == draft.original.source.sourceRevision else {
            throw SceneConfigurationSaveError.conflict(
                path: draft.original.source.path
            )
        }

        _ = try await client.setConfigurationFile(
            at: draft.original.source.path,
            contents: renderedSource
        )

        let recovery = SceneConfigurationRecovery(
            path: draft.original.source.path,
            originalSource: draft.original.source.originalSource,
            originalSceneName: draft.original.identifier ?? sceneName,
            savedSourceRevision: presumedDocument.sourceRevision
        )
        let reload: HBSceneReloadResult
        do {
            reload = try await client.reloadScene(named: sceneName)
        } catch {
            throw SceneConfigurationSaveError.reloadFailed(
                message: error.localizedDescription,
                recovery: recovery,
                presumedScene: presumedScene
            )
        }

        do {
            let verifiedDocument = try await document(
                at: draft.original.source.path
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
        let current = try await document(at: recovery.path)
        guard current.sourceRevision == recovery.savedSourceRevision else {
            throw SceneConfigurationSaveError.conflict(path: recovery.path)
        }

        _ = try await client.setConfigurationFile(
            at: recovery.path,
            contents: recovery.originalSource
        )
        let reload = try await client.reloadScene(
            named: recovery.originalSceneName
        )
        let restored = try await document(at: recovery.path)
        return try SceneConfigurationCatalog(documents: [restored])
            .scene(named: reload.name)
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
            reload = try await client.reloadScene(named: sceneName)
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
}

struct SceneConfigurationLoadingError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}
