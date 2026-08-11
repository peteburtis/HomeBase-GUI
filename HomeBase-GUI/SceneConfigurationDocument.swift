//
//  SceneConfigurationDocument.swift
//  HomeBase-GUI
//

import Foundation
import HomeBaseProtocol

struct SceneConfigurationDocument: Identifiable, Equatable, Sendable {
    let source: RemoteJSONDocument
    let rootIndex: Int?
    let fields: [String: HBJSONValue]

    var id: String {
        source.path + "\u{0}" + jsonPath
    }

    var jsonPath: String {
        rootIndex.map { "$[\($0)]" } ?? "$"
    }

    var identifier: String? {
        fields["Identifier"]?.stringValue
    }

    var priority: Int64? {
        fields["Priority"]?.integerValue
    }

    var timing: Double? {
        fields["Timing"]?.numberValue
    }

    var actions: [SceneActionConfiguration] {
        guard let values = fields["Actions"]?.arrayValue else { return [] }
        return values.enumerated().map {
            SceneActionConfiguration(index: $0.offset, rawValue: $0.element)
        }
    }

    var additionalFields: [(key: String, value: HBJSONValue)] {
        fields
            .filter {
                $0.key != "Identifier"
                    && $0.key != "Priority"
                    && $0.key != "Timing"
                    && $0.key != "Actions"
            }
            .sorted { left, right in
                let order = left.key.localizedCaseInsensitiveCompare(right.key)
                if order != .orderedSame {
                    return order == .orderedAscending
                }
                return left.key < right.key
            }
    }

    var occupiesEntireSourceFile: Bool {
        switch (source.root, rootIndex) {
        case (.object, nil):
            true
        case (.array(let values), .some(let index)):
            values.count == 1 && index == 0
        default:
            false
        }
    }
}

struct SceneActionConfiguration: Identifiable, Equatable, Sendable {
    let index: Int
    let rawValue: HBJSONValue

    var id: Int { index }

    var type: String? {
        guard let object = rawValue.objectValue, object.count == 1 else {
            return nil
        }
        return object.keys.first
    }

    var payload: HBJSONValue? {
        guard let type, let object = rawValue.objectValue else { return nil }
        return object[type]
    }

    var controlSet: SceneControlSetConfiguration? {
        SceneControlSetConfiguration(action: self)
    }
}

struct SceneControlSetConfiguration: Equatable, Sendable {
    let actionIndex: Int
    let device: String
    let control: String
    let value: HBJSONValue
    let trailingValues: [HBJSONValue]

    var controlPath: String {
        "\(device):\(control)"
    }

    init?(action: SceneActionConfiguration) {
        guard action.type == "ControlSet",
              let values = action.payload?.arrayValue,
              values.count >= 3,
              let device = values[0].stringValue,
              let control = values[1].stringValue else {
            return nil
        }
        actionIndex = action.index
        self.device = device
        self.control = control
        value = values[2]
        trailingValues = Array(values.dropFirst(3))
    }
}

struct SceneConfigurationSourceRename: Equatable, Sendable {
    let originalPath: String
    let proposedPath: String
}

/// A semantic draft of the complete source file containing one scene.
/// Mutations replace only explicitly edited values in the parsed JSON tree.
/// The original source bytes remain untouched until a dirty draft is saved.
struct SceneConfigurationDraft: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        case existingFile
        case newFile
    }

    enum MutationError: LocalizedError, Equatable {
        case invalidSceneLocation
        case actionsAreNotAnArray
        case missingAction(Int)
        case actionIsNotControlSet(Int)
        case invalidControlTarget
        case invalidTiming

        var errorDescription: String? {
            switch self {
            case .invalidSceneLocation:
                "The scene no longer has a valid location in its source file."
            case .actionsAreNotAnArray:
                "The scene's Actions field is not an array."
            case .missingAction(let index):
                "The scene has no action at index \(index)."
            case .actionIsNotControlSet(let index):
                "Action \(index + 1) is not an editable ControlSet action."
            case .invalidControlTarget:
                "A ControlSet action requires a device and control name."
            case .invalidTiming:
                "Scene timing must be finite and nonnegative."
            }
        }
    }

    let original: SceneConfigurationDocument
    let origin: Origin
    private(set) var root: HBJSONValue

    init(
        scene: SceneConfigurationDocument,
        origin: Origin = .existingFile
    ) {
        original = scene
        self.origin = origin
        root = scene.source.root
    }

    static func newScene(
        identifier: String = "UntitledScene",
        priority: Int32 = 0,
        timing: Double = 1
    ) throws -> Self {
        let root = HBJSONValue.object([
            "Identifier": .string(identifier),
            "Priority": .integer(Int64(priority)),
            "Timing": .number(timing),
            "Actions": .array([]),
        ])
        let source = try root.configurationJSONSource(prettyPrinted: true)
            + "\n"
        let document = try RemoteJSONDocument(
            path: "scenes/.untitled-scene.json",
            source: source
        )
        let scene = SceneConfigurationDocument(
            source: document,
            rootIndex: nil,
            fields: root.objectValue ?? [:]
        )
        return Self(scene: scene, origin: .newFile)
    }

    var scene: SceneConfigurationDocument {
        guard let fields = currentSceneFields else {
            preconditionFailure(
                "A SceneConfigurationDraft must retain its scene location."
            )
        }
        return SceneConfigurationDocument(
            source: original.source,
            rootIndex: original.rootIndex,
            fields: fields
        )
    }

    var isDirty: Bool {
        isNew || hasSemanticChanges
    }

    var isNew: Bool {
        origin == .newFile
    }

    var hasSemanticChanges: Bool {
        root != original.source.root
    }

    var identifierChanged: Bool {
        scene.identifier != original.identifier
    }

    var derivesSourcePathFromIdentifier: Bool {
        switch (original.source.root, original.rootIndex) {
        case (.object, nil):
            true
        case (.array(let scenes), .some(0)):
            scenes.count == 1
        default:
            false
        }
    }

    var proposedSourcePath: String? {
        guard (isNew || identifierChanged),
              derivesSourcePathFromIdentifier,
              let identifier = scene.identifier,
              !identifier.isEmpty,
              !identifier.hasPrefix("."),
              !identifier.contains("/"),
              !identifier.utf8.contains(0) else {
            return nil
        }

        let directory = (original.source.path as NSString)
            .deletingLastPathComponent
        let filename = identifier + ".json"
        return directory.isEmpty ? filename : directory + "/" + filename
    }

    var sourceRename: SceneConfigurationSourceRename? {
        guard !isNew,
              let proposedSourcePath,
              proposedSourcePath != original.source.path else {
            return nil
        }
        return SceneConfigurationSourceRename(
            originalPath: original.source.path,
            proposedPath: proposedSourcePath
        )
    }

    mutating func setIdentifier(_ identifier: String) throws {
        try setSceneField("Identifier", value: .string(identifier))
    }

    mutating func setPriority(_ priority: Int32?) throws {
        try setSceneField(
            "Priority",
            value: priority.map { .integer(Int64($0)) }
        )
    }

    mutating func setTiming(_ timing: Double?) throws {
        if let timing, (!timing.isFinite || timing < 0) {
            throw MutationError.invalidTiming
        }
        try setSceneField("Timing", value: timing.map(HBJSONValue.number))
    }

    mutating func setControlValue(
        actionIndex: Int,
        value: HBJSONValue
    ) throws {
        var fields = try requiredSceneFields()
        guard var actions = fields["Actions"]?.arrayValue,
              actions.indices.contains(actionIndex) else {
            throw MutationError.missingAction(actionIndex)
        }
        guard var action = actions[actionIndex].objectValue,
              action.count == 1,
              var controlSet = action["ControlSet"]?.arrayValue,
              controlSet.count >= 3 else {
            throw MutationError.actionIsNotControlSet(actionIndex)
        }

        guard controlSet[2] != value else { return }
        controlSet[2] = value
        action["ControlSet"] = .array(controlSet)
        actions[actionIndex] = .object(action)
        fields["Actions"] = .array(actions)
        try replaceSceneFields(fields)
    }

    mutating func removeControlSet(actionIndex: Int) throws {
        var fields = try requiredSceneFields()
        guard var actions = fields["Actions"]?.arrayValue else {
            if fields["Actions"] == nil {
                throw MutationError.missingAction(actionIndex)
            }
            throw MutationError.actionsAreNotAnArray
        }
        guard actions.indices.contains(actionIndex) else {
            throw MutationError.missingAction(actionIndex)
        }
        guard SceneActionConfiguration(
            index: actionIndex,
            rawValue: actions[actionIndex]
        ).controlSet != nil else {
            throw MutationError.actionIsNotControlSet(actionIndex)
        }

        actions.remove(at: actionIndex)
        fields["Actions"] = .array(actions)
        try replaceSceneFields(fields)
    }

    @discardableResult
    mutating func appendControlSet(
        device: String,
        control: String,
        value: HBJSONValue
    ) throws -> Int {
        guard !device.isEmpty, !control.isEmpty else {
            throw MutationError.invalidControlTarget
        }

        var fields = try requiredSceneFields()
        var actions: [HBJSONValue]
        if let actionsValue = fields["Actions"] {
            guard let existingActions = actionsValue.arrayValue else {
                throw MutationError.actionsAreNotAnArray
            }
            actions = existingActions
        } else {
            actions = []
        }

        let actionIndex = actions.count
        actions.append(
            .object([
                "ControlSet": .array([
                    .string(device),
                    .string(control),
                    value,
                ])
            ])
        )
        fields["Actions"] = .array(actions)
        try replaceSceneFields(fields)
        return actionIndex
    }

    func renderedSource() throws -> String {
        try root.configurationJSONSource(prettyPrinted: true) + "\n"
    }

    private var currentSceneFields: [String: HBJSONValue]? {
        switch (root, original.rootIndex) {
        case (.object(let fields), nil):
            fields
        case (.array(let values), .some(let index))
            where values.indices.contains(index):
            values[index].objectValue
        default:
            nil
        }
    }

    private func requiredSceneFields() throws -> [String: HBJSONValue] {
        guard let currentSceneFields else {
            throw MutationError.invalidSceneLocation
        }
        return currentSceneFields
    }

    private mutating func replaceSceneFields(
        _ fields: [String: HBJSONValue]
    ) throws {
        switch (root, original.rootIndex) {
        case (.object, nil):
            root = .object(fields)
        case (.array(var values), .some(let index))
            where values.indices.contains(index):
            values[index] = .object(fields)
            root = .array(values)
        default:
            throw MutationError.invalidSceneLocation
        }
    }

    private mutating func setSceneField(
        _ key: String,
        value: HBJSONValue?
    ) throws {
        var fields = try requiredSceneFields()
        if let value {
            guard fields[key] != value else { return }
            fields[key] = value
        } else {
            guard fields.removeValue(forKey: key) != nil else { return }
        }
        try replaceSceneFields(fields)
    }
}

struct SceneConfigurationCatalog: Equatable, Sendable {
    struct Issue: Identifiable, Equatable, Sendable {
        let sourcePath: String
        let jsonPath: String
        let message: String

        var id: String {
            sourcePath + "\u{0}" + jsonPath + "\u{0}" + message
        }
    }

    enum LookupError: LocalizedError, Equatable {
        case notFound(String)
        case ambiguous(name: String, locations: [String])

        var errorDescription: String? {
            switch self {
            case .notFound(let name):
                "The configuration for scene \"\(name)\" could not be found."
            case .ambiguous(let name, let locations):
                "Scene \"\(name)\" appears more than once: "
                    + locations.joined(separator: ", ")
            }
        }
    }

    let scenes: [SceneConfigurationDocument]
    let issues: [Issue]

    init(documents: [RemoteJSONDocument]) {
        var scenes: [SceneConfigurationDocument] = []
        var issues: [Issue] = []

        for document in documents.sorted(by: { $0.path < $1.path }) {
            switch document.root {
            case .object(let fields):
                scenes.append(
                    SceneConfigurationDocument(
                        source: document,
                        rootIndex: nil,
                        fields: fields
                    )
                )

            case .array(let values):
                for (index, value) in values.enumerated() {
                    guard let fields = value.objectValue else {
                        issues.append(
                            Issue(
                                sourcePath: document.path,
                                jsonPath: "$[\(index)]",
                                message:
                                    "Scene arrays must contain JSON objects."
                            )
                        )
                        continue
                    }
                    scenes.append(
                        SceneConfigurationDocument(
                            source: document,
                            rootIndex: index,
                            fields: fields
                        )
                    )
                }

            default:
                issues.append(
                    Issue(
                        sourcePath: document.path,
                        jsonPath: "$",
                        message:
                            "A scene file must contain an object or an array."
                    )
                )
            }
        }

        self.scenes = scenes
        self.issues = issues
    }

    func scene(named name: String) throws -> SceneConfigurationDocument {
        let exactMatches = scenes.filter { $0.identifier == name }
        if exactMatches.count == 1 {
            return exactMatches[0]
        }
        if exactMatches.count > 1 {
            throw ambiguousError(name: name, matches: exactMatches)
        }

        let matches = scenes.filter {
            $0.identifier?.caseInsensitiveCompare(name) == .orderedSame
        }
        guard !matches.isEmpty else {
            throw LookupError.notFound(name)
        }
        guard matches.count == 1 else {
            throw ambiguousError(name: name, matches: matches)
        }
        return matches[0]
    }

    private func ambiguousError(
        name: String,
        matches: [SceneConfigurationDocument]
    ) -> LookupError {
        LookupError.ambiguous(
            name: name,
            locations: matches.map {
                "\($0.source.path) \($0.jsonPath)"
            }
        )
    }
}
