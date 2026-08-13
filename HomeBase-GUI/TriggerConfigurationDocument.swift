//
//  TriggerConfigurationDocument.swift
//  HomeBase-GUI
//

import Foundation
import HomeBaseProtocol

struct TriggerConfigurationDocument: Identifiable, Equatable, Sendable {
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

    /// The explicitly authored mode. A missing field is valid and means
    /// Trigger mode at the engine boundary.
    var configuredMode: String? {
        fields["Mode"]?.stringValue
    }

    var mode: HBTriggerMode? {
        let wireValue = configuredMode
            ?? TriggerModeUICatalog.defaultRegistration.wireValue
        return TriggerModeUICatalog.registration(forWireValue: wireValue)?.mode
    }

    var conditions: [TriggerConditionConfiguration] {
        guard let values = fields["Conditions"]?.arrayValue else { return [] }
        return values.enumerated().map {
            TriggerConditionConfiguration(
                index: $0.offset,
                rawValue: $0.element
            )
        }
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
                    && $0.key != "Mode"
                    && $0.key != "Conditions"
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

struct TriggerConditionConfiguration: Identifiable, Equatable, Sendable {
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
}

struct TriggerConfigurationSourceRename: Equatable, Sendable {
    let originalPath: String
    let proposedPath: String
}

/// A semantic draft of the complete source file containing one trigger.
/// Mutations replace only explicitly edited values in the parsed JSON tree.
/// The original source bytes remain untouched until a dirty draft is saved.
struct TriggerConfigurationDraft: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        case existingFile
        case newFile
    }

    enum MutationError: LocalizedError, Equatable {
        case invalidTriggerLocation
        case invalidTriggerMode
        case conditionsAreNotAnArray
        case missingCondition(Int)
        case invalidCondition(Int)
        case actionsAreNotAnArray
        case missingAction(Int)
        case invalidAction(Int)
        case actionIsNotControlSet(Int)
        case invalidControlTarget

        var errorDescription: String? {
            switch self {
            case .invalidTriggerLocation:
                "The trigger no longer has a valid location in its source file."
            case .invalidTriggerMode:
                "Trigger mode must be "
                    + TriggerModeUICatalog.supportedWireValueDescription
                    + "."
            case .conditionsAreNotAnArray:
                "The trigger's Conditions field is not an array."
            case .missingCondition(let index):
                "The trigger has no condition at index \(index)."
            case .invalidCondition(let index):
                "Condition \(index + 1) must be an object with exactly one nonempty key."
            case .actionsAreNotAnArray:
                "The trigger's Actions field is not an array."
            case .missingAction(let index):
                "The trigger has no action at index \(index)."
            case .invalidAction(let index):
                "Action \(index + 1) must be an object with exactly one nonempty key."
            case .actionIsNotControlSet(let index):
                "Action \(index + 1) is not an editable ControlSet action."
            case .invalidControlTarget:
                "A ControlSet action requires a device and control name."
            }
        }
    }

    let original: TriggerConfigurationDocument
    let origin: Origin
    private(set) var root: HBJSONValue

    init(
        trigger: TriggerConfigurationDocument,
        origin: Origin = .existingFile
    ) {
        original = trigger
        self.origin = origin
        root = trigger.source.root
    }

    static func newTrigger(
        identifier: String = "UntitledTrigger",
        mode: String = TriggerModeUICatalog.defaultRegistration.wireValue
    ) throws -> Self {
        guard TriggerModeUICatalog.registration(
            forWireValue: mode
        ) != nil else {
            throw MutationError.invalidTriggerMode
        }
        var fields: [String: HBJSONValue] = [
            "Identifier": .string(identifier),
            "Conditions": .array([]),
            "Actions": .array([]),
        ]
        if mode != TriggerModeUICatalog.defaultRegistration.wireValue {
            fields["Mode"] = .string(mode)
        }
        let root = HBJSONValue.object(fields)
        let source = try root.configurationJSONSource(prettyPrinted: true)
            + "\n"
        let document = try RemoteJSONDocument(
            path: "triggers/.untitled-trigger.json",
            source: source
        )
        let trigger = TriggerConfigurationDocument(
            source: document,
            rootIndex: nil,
            fields: root.objectValue ?? [:]
        )
        return Self(trigger: trigger, origin: .newFile)
    }

    var trigger: TriggerConfigurationDocument {
        guard let fields = currentTriggerFields else {
            preconditionFailure(
                "A TriggerConfigurationDraft must retain its trigger location."
            )
        }
        return TriggerConfigurationDocument(
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
        trigger.identifier != original.identifier
    }

    var derivesSourcePathFromIdentifier: Bool {
        switch (original.source.root, original.rootIndex) {
        case (.object, nil):
            true
        case (.array(let triggers), .some(0)):
            triggers.count == 1
        default:
            false
        }
    }

    var proposedSourcePath: String? {
        guard (isNew || identifierChanged),
              derivesSourcePathFromIdentifier,
              let identifier = trigger.identifier,
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

    var sourceRename: TriggerConfigurationSourceRename? {
        guard !isNew,
              let proposedSourcePath,
              proposedSourcePath != original.source.path else {
            return nil
        }
        return TriggerConfigurationSourceRename(
            originalPath: original.source.path,
            proposedPath: proposedSourcePath
        )
    }

    mutating func setIdentifier(_ identifier: String) throws {
        try setTriggerField("Identifier", value: .string(identifier))
    }

    mutating func setMode(_ mode: String) throws {
        guard TriggerModeUICatalog.registration(
            forWireValue: mode
        ) != nil else {
            throw MutationError.invalidTriggerMode
        }

        let originalMode = original.configuredMode
            ?? TriggerModeUICatalog.defaultRegistration.wireValue
        if mode == originalMode {
            // Preserve whether the default was explicitly authored. This also
            // makes changing away and back a true semantic no-op.
            try setTriggerField("Mode", value: original.fields["Mode"])
        } else if mode == TriggerModeUICatalog.defaultRegistration.wireValue {
            try setTriggerField("Mode", value: nil)
        } else {
            try setTriggerField("Mode", value: .string(mode))
        }
    }

    mutating func setCondition(
        at index: Int,
        rawValue: HBJSONValue
    ) throws {
        try Self.validateCondition(rawValue, at: index)
        var fields = try requiredTriggerFields()
        guard var conditions = fields["Conditions"]?.arrayValue else {
            if fields["Conditions"] == nil {
                throw MutationError.missingCondition(index)
            }
            throw MutationError.conditionsAreNotAnArray
        }
        guard conditions.indices.contains(index) else {
            throw MutationError.missingCondition(index)
        }
        guard conditions[index] != rawValue else { return }
        conditions[index] = rawValue
        fields["Conditions"] = .array(conditions)
        try replaceTriggerFields(fields)
    }

    mutating func removeCondition(at index: Int) throws {
        var fields = try requiredTriggerFields()
        guard var conditions = fields["Conditions"]?.arrayValue else {
            if fields["Conditions"] == nil {
                throw MutationError.missingCondition(index)
            }
            throw MutationError.conditionsAreNotAnArray
        }
        guard conditions.indices.contains(index) else {
            throw MutationError.missingCondition(index)
        }
        conditions.remove(at: index)
        fields["Conditions"] = .array(conditions)
        try replaceTriggerFields(fields)
    }

    @discardableResult
    mutating func appendCondition(_ rawValue: HBJSONValue) throws -> Int {
        var fields = try requiredTriggerFields()
        var conditions: [HBJSONValue]
        if let conditionsValue = fields["Conditions"] {
            guard let existingConditions = conditionsValue.arrayValue else {
                throw MutationError.conditionsAreNotAnArray
            }
            conditions = existingConditions
        } else {
            conditions = []
        }
        let index = conditions.count
        try Self.validateCondition(rawValue, at: index)
        conditions.append(rawValue)
        fields["Conditions"] = .array(conditions)
        try replaceTriggerFields(fields)
        return index
    }

    mutating func setControlValue(
        actionIndex: Int,
        value: HBJSONValue
    ) throws {
        var fields = try requiredTriggerFields()
        guard var actions = fields["Actions"]?.arrayValue,
              actions.indices.contains(actionIndex) else {
            throw MutationError.missingAction(actionIndex)
        }
        guard var action = actions[actionIndex].objectValue,
              action.count == 1,
              var controlSet = action["ControlSet"]?.arrayValue,
              controlSet.count >= 3,
              let command = ControlCommandJSONLens(controlSet[2]) else {
            throw MutationError.actionIsNotControlSet(actionIndex)
        }

        let patchedCommand = command.replacingPrimaryValue(with: value)
        guard controlSet[2] != patchedCommand else { return }
        controlSet[2] = patchedCommand
        action["ControlSet"] = .array(controlSet)
        actions[actionIndex] = .object(action)
        fields["Actions"] = .array(actions)
        try replaceTriggerFields(fields)
    }

    mutating func setAction(
        at index: Int,
        rawValue: HBJSONValue
    ) throws {
        try Self.validateAction(rawValue, at: index)
        var fields = try requiredTriggerFields()
        guard var actions = fields["Actions"]?.arrayValue else {
            if fields["Actions"] == nil {
                throw MutationError.missingAction(index)
            }
            throw MutationError.actionsAreNotAnArray
        }
        guard actions.indices.contains(index) else {
            throw MutationError.missingAction(index)
        }
        guard actions[index] != rawValue else { return }
        actions[index] = rawValue
        fields["Actions"] = .array(actions)
        try replaceTriggerFields(fields)
    }

    mutating func removeAction(at index: Int) throws {
        var fields = try requiredTriggerFields()
        guard var actions = fields["Actions"]?.arrayValue else {
            if fields["Actions"] == nil {
                throw MutationError.missingAction(index)
            }
            throw MutationError.actionsAreNotAnArray
        }
        guard actions.indices.contains(index) else {
            throw MutationError.missingAction(index)
        }
        actions.remove(at: index)
        fields["Actions"] = .array(actions)
        try replaceTriggerFields(fields)
    }

    @discardableResult
    mutating func appendAction(_ rawValue: HBJSONValue) throws -> Int {
        var fields = try requiredTriggerFields()
        var actions: [HBJSONValue]
        if let actionsValue = fields["Actions"] {
            guard let existingActions = actionsValue.arrayValue else {
                throw MutationError.actionsAreNotAnArray
            }
            actions = existingActions
        } else {
            actions = []
        }

        let index = actions.count
        try Self.validateAction(rawValue, at: index)
        actions.append(rawValue)
        fields["Actions"] = .array(actions)
        try replaceTriggerFields(fields)
        return index
    }

    mutating func removeControlSet(actionIndex: Int) throws {
        let fields = try requiredTriggerFields()
        guard let actions = fields["Actions"]?.arrayValue else {
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

        try removeAction(at: actionIndex)
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

        return try appendAction(
            .object([
                "ControlSet": .array([
                    .string(device),
                    .string(control),
                    value,
                ])
            ])
        )
    }

    func renderedSource() throws -> String {
        try root.configurationJSONSource(prettyPrinted: true) + "\n"
    }

    private var currentTriggerFields: [String: HBJSONValue]? {
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

    private func requiredTriggerFields() throws -> [String: HBJSONValue] {
        guard let currentTriggerFields else {
            throw MutationError.invalidTriggerLocation
        }
        return currentTriggerFields
    }

    private mutating func replaceTriggerFields(
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
            throw MutationError.invalidTriggerLocation
        }
    }

    private mutating func setTriggerField(
        _ key: String,
        value: HBJSONValue?
    ) throws {
        var fields = try requiredTriggerFields()
        if let value {
            guard fields[key] != value else { return }
            fields[key] = value
        } else {
            guard fields.removeValue(forKey: key) != nil else { return }
        }
        try replaceTriggerFields(fields)
    }

    private static func validateCondition(
        _ rawValue: HBJSONValue,
        at index: Int
    ) throws {
        guard let object = rawValue.objectValue,
              object.count == 1,
              let key = object.keys.first,
              !key.isEmpty else {
            throw MutationError.invalidCondition(index)
        }
    }

    private static func validateAction(
        _ rawValue: HBJSONValue,
        at index: Int
    ) throws {
        guard let object = rawValue.objectValue,
              object.count == 1,
              let key = object.keys.first,
              !key.isEmpty else {
            throw MutationError.invalidAction(index)
        }
    }
}

struct TriggerConfigurationCatalog: Equatable, Sendable {
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
                "The configuration for trigger \"\(name)\" could not be found."
            case .ambiguous(let name, let locations):
                "Trigger \"\(name)\" appears more than once: "
                    + locations.joined(separator: ", ")
            }
        }
    }

    let triggers: [TriggerConfigurationDocument]
    let issues: [Issue]

    init(documents: [RemoteJSONDocument]) {
        var triggers: [TriggerConfigurationDocument] = []
        var issues: [Issue] = []

        for document in documents.sorted(by: { $0.path < $1.path }) {
            switch document.root {
            case .object(let fields):
                triggers.append(
                    TriggerConfigurationDocument(
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
                                    "Trigger arrays must contain JSON objects."
                            )
                        )
                        continue
                    }
                    triggers.append(
                        TriggerConfigurationDocument(
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
                            "A trigger file must contain an object or an array."
                    )
                )
            }
        }

        self.triggers = triggers
        self.issues = issues
    }

    func trigger(named name: String) throws -> TriggerConfigurationDocument {
        let exactMatches = triggers.filter { $0.identifier == name }
        if exactMatches.count == 1 {
            return exactMatches[0]
        }
        if exactMatches.count > 1 {
            throw ambiguousError(name: name, matches: exactMatches)
        }

        let matches = triggers.filter {
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
        matches: [TriggerConfigurationDocument]
    ) -> LookupError {
        LookupError.ambiguous(
            name: name,
            locations: matches.map {
                "\($0.source.path) \($0.jsonPath)"
            }
        )
    }
}
