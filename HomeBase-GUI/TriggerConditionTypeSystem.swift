//
//  TriggerConditionTypeSystem.swift
//  HomeBase-GUI
//

import Foundation
import HomeBaseProtocol
import SwiftUI

/// Produces the most specific lossless JSON number representation available
/// for values coming from SwiftUI's floating-point controls.
func triggerConditionJSONNumber(_ number: Double) -> HBJSONValue {
    if let integer = Int64(exactly: number) {
        return .integer(integer)
    }
    return .number(number)
}

/// The source-independent input understood by trigger-condition modules.
/// Authored JSON and live trigger descriptors both adapt into this shape so
/// browsing and editing cannot drift into separate type-specific switches.
struct TriggerConditionPluginContext: Equatable, Sendable {
    let rawValue: HBJSONValue
    let type: String?
    let payload: HBJSONValue?
    let childCount: Int?
    let trueWhileInvalid: Bool

    init(
        rawValue: HBJSONValue,
        childCount: Int? = nil,
        trueWhileInvalid: Bool = false
    ) {
        self.rawValue = rawValue
        self.trueWhileInvalid = trueWhileInvalid
        guard let object = rawValue.objectValue,
              object.count == 1,
              let entry = object.first,
              !entry.key.isEmpty else {
            type = nil
            payload = nil
            self.childCount = childCount
            return
        }
        type = entry.key
        payload = entry.value
        self.childCount = childCount
    }

    init(descriptor: HBTriggerConditionDescriptor) {
        self.init(
            rawValue: .object([
                descriptor.type: descriptor.configuration
            ]),
            childCount: descriptor.children.count,
            trueWhileInvalid: descriptor.trueWhileInvalid
        )
    }

}

struct TriggerConditionPluginPresentation: Equatable, Sendable {
    let title: String
    let detail: String?
}

struct TriggerConditionCreationOption: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let systemImage: String
    let initialValue: HBJSONValue
}

enum TriggerConditionEditingPlan: Equatable, Sendable {
    case compare(TriggerCompareCondition)
    case timeOfDay(TriggerTimeOfDayCondition)
    case composite(TriggerCompositeCondition)
    case raw
}

struct TriggerConditionEditingContext {
    let rawValue: Binding<HBJSONValue>
    let repository: TriggerConfigurationRepository
}

/// The capabilities declared by one exact trigger-condition wire type.
/// Looking at `TriggerConditionTypeRegistry.standard` is therefore enough to
/// see which protocol forms have purpose-built client UI.
struct TriggerConditionModuleCapabilities: OptionSet, Equatable, Sendable {
    let rawValue: Int

    static let presentation = Self(rawValue: 1 << 0)
    static let editing = Self(rawValue: 1 << 1)
    static let creation = Self(rawValue: 1 << 2)
    static let children = Self(rawValue: 1 << 3)
}

/// A type-erased module for exactly one top-level condition key. Capabilities
/// are deliberately independent: a condition can have a readable summary
/// without appearing in creation menus or claiming a structured editor.
struct TriggerConditionTypeModule: Identifiable {
    let identifier: String
    let wireType: String?
    let creationOption: TriggerConditionCreationOption?

    var id: String { identifier }

    private let presentationImplementation: (@Sendable (
        TriggerConditionPluginContext
    ) -> TriggerConditionPluginPresentation?)?
    private let editingPlanImplementation: (@Sendable (
        TriggerConditionPluginContext
    ) -> TriggerConditionEditingPlan?)?
    private let validationImplementation: (@Sendable (
            TriggerConditionPluginContext,
            @Sendable (HBJSONValue) -> String?
    ) -> String?)?
    private let childrenImplementation:
        (@Sendable (TriggerConditionPluginContext) -> [HBJSONValue]?)?
    private let makeEditorRowsImplementation:
        (@MainActor (TriggerConditionEditingContext) -> AnyView?)?

    init(
        identifier: String,
        wireType: String?,
        creationOption: TriggerConditionCreationOption? = nil,
        presentation: (@Sendable (
            TriggerConditionPluginContext
        ) -> TriggerConditionPluginPresentation?)? = nil,
        editingPlan: (@Sendable (
            TriggerConditionPluginContext
        ) -> TriggerConditionEditingPlan?)? = nil,
        validation: (@Sendable (
            TriggerConditionPluginContext,
            @Sendable (HBJSONValue) -> String?
        ) -> String?)? = nil,
        children: (@Sendable (
            TriggerConditionPluginContext
        ) -> [HBJSONValue]?)? = nil,
        makeEditorRows: (@MainActor (
            TriggerConditionEditingContext
        ) -> AnyView?)? = nil
    ) {
        self.identifier = identifier
        self.wireType = wireType
        self.creationOption = creationOption
        presentationImplementation = presentation
        editingPlanImplementation = editingPlan
        validationImplementation = validation
        childrenImplementation = children
        makeEditorRowsImplementation = makeEditorRows
    }

    var capabilities: TriggerConditionModuleCapabilities {
        var result: TriggerConditionModuleCapabilities = []
        if presentationImplementation != nil { result.insert(.presentation) }
        if editingPlanImplementation != nil { result.insert(.editing) }
        if creationOption != nil { result.insert(.creation) }
        if childrenImplementation != nil { result.insert(.children) }
        return result
    }

    func presentation(
        for context: TriggerConditionPluginContext
    ) -> TriggerConditionPluginPresentation {
        presentationImplementation?(context) ?? rawPresentation(context)
    }

    func editingPlan(
        for context: TriggerConditionPluginContext
    ) -> TriggerConditionEditingPlan {
        editingPlanImplementation?(context) ?? .raw
    }

    func validationMessage(
        for context: TriggerConditionPluginContext,
        validateChild: @escaping @Sendable (HBJSONValue) -> String?
    ) -> String? {
        validationImplementation?(context, validateChild)
    }

    func children(
        for context: TriggerConditionPluginContext
    ) -> [HBJSONValue] {
        childrenImplementation?(context) ?? []
    }

    @MainActor
    func makeEditorRows(
        context: TriggerConditionEditingContext
    ) -> AnyView {
        makeEditorRowsImplementation?(context)
            ?? AnyView(TriggerRawConditionEditorRows(rawValue: context.rawValue))
    }
}

struct TriggerConditionTypeRegistry {
    struct Resolution {
        let module: TriggerConditionTypeModule
        let isFallback: Bool
    }

    /// The complete, ordered manifest of known engine condition wire types.
    let modules: [TriggerConditionTypeModule]
    let fallback: TriggerConditionTypeModule
    private let modulesByWireType: [String: TriggerConditionTypeModule]

    init(
        modules: [TriggerConditionTypeModule],
        fallback: TriggerConditionTypeModule
    ) {
        let identifiers = modules.map(\.identifier) + [fallback.identifier]
        precondition(
            Set(identifiers).count == identifiers.count,
            "Trigger-condition module identifiers must be unique."
        )
        let wireTypes = modules.compactMap(\.wireType)
        precondition(
            wireTypes.count == modules.count,
            "Known trigger-condition modules require an exact wire type."
        )
        precondition(
            Set(wireTypes).count == wireTypes.count,
            "Trigger-condition wire types must be unique."
        )
        precondition(
            fallback.wireType == nil,
            "The trigger-condition fallback cannot claim a wire type."
        )
        let creationIdentifiers = (modules + [fallback])
            .compactMap(\.creationOption?.id)
        precondition(
            Set(creationIdentifiers).count == creationIdentifiers.count,
            "Trigger-condition creation identifiers must be unique."
        )
        self.modules = modules
        self.fallback = fallback
        modulesByWireType = Dictionary(
            uniqueKeysWithValues: modules.compactMap { module in
                module.wireType.map { ($0, module) }
            }
        )
    }

    var creationOptions: [TriggerConditionCreationOption] {
        (modules + [fallback]).compactMap(\.creationOption)
    }

    func resolve(_ context: TriggerConditionPluginContext) -> Resolution {
        guard let type = context.type,
              let module = modulesByWireType[type] else {
            return Resolution(module: fallback, isFallback: true)
        }
        return Resolution(module: module, isFallback: false)
    }

    func presentation(
        for rawValue: HBJSONValue
    ) -> TriggerConditionPluginPresentation {
        let context = TriggerConditionPluginContext(rawValue: rawValue)
        return resolve(context).module.presentation(for: context)
    }

    func presentation(
        for descriptor: HBTriggerConditionDescriptor
    ) -> TriggerConditionPluginPresentation {
        let context = TriggerConditionPluginContext(descriptor: descriptor)
        let presentation = resolve(context).module.presentation(for: context)
        guard context.trueWhileInvalid,
              context.type != TriggerCompositeCondition.Kind.trueWhenInvalid
                .rawValue else {
            return presentation
        }
        let policy = "Keeps matching if the value is unavailable"
        return TriggerConditionPluginPresentation(
            title: presentation.title,
            detail: presentation.detail.map { "\($0) • \(policy)" }
                ?? policy
        )
    }

    func editingPlan(for rawValue: HBJSONValue) -> TriggerConditionEditingPlan {
        let context = TriggerConditionPluginContext(rawValue: rawValue)
        return resolve(context).module.editingPlan(for: context)
    }

    func children(of rawValue: HBJSONValue) -> [HBJSONValue] {
        let context = TriggerConditionPluginContext(rawValue: rawValue)
        return resolve(context).module.children(for: context)
    }

    func validationMessage(for rawValue: HBJSONValue) -> String? {
        guard let object = rawValue.objectValue,
              object.count == 1,
              object.keys.first?.isEmpty == false else {
            return "A condition must be an object with exactly one nonempty key."
        }
        let context = TriggerConditionPluginContext(rawValue: rawValue)
        return resolve(context).module.validationMessage(
            for: context,
            validateChild: validationMessage
        )
    }
}

extension TriggerConditionTypeRegistry {
    static let standard = TriggerConditionTypeRegistry(
        modules: [
            // Structured presentation, editing, and creation.
            .compare,
            .timeOfDay,
            .composite(.and),
            .composite(.or),
            .composite(.xor),
            .composite(.trueWhenInvalid),

            // Human-readable presentation; raw JSON editing only.
            .legacyControlChange,
            .legacyControlComparison(
                "ControlValueGreaterThan",
                relationship: .greaterThan
            ),
            .legacyControlComparison(
                "ControlValueGreaterThanOrEqual",
                relationship: .greaterThanOrEqual
            ),
            .legacyControlComparison(
                "ControlValueLessThan",
                relationship: .lessThan
            ),
            .legacyControlComparison(
                "ControlValueLessThanOrEqual",
                relationship: .lessThanOrEqual
            ),
            .legacyControlComparison(
                "ControlValueEqual",
                relationship: .equals
            ),
            .legacyControlComparison(
                "ControlValueNotEqual",
                relationship: .doesNotEqual
            ),

            // Recognized engine forms without specialized client UI yet.
            .raw("DayOfWeek"),
            .delay,
            .raw("Sustain"),
            .invalid,
            .raw("ObservedWithin"),
            .raw("NotObservedWithin"),
            .raw("ObservedAfter"),
            .raw("SceneActivated"),
            .raw("SceneDeactivated"),
        ],
        fallback: .rawFallback
    )
}

/// The exact operand forms HomeBase accepts on either side of `Compare`.
/// Presentation support is intentionally broader than the structured editor:
/// every valid engine operand remains readable even when its authoring UI is
/// still the lossless JSON editor.
extension TriggerCompareOperandPresentationRegistry {
    static let standard = TriggerCompareOperandPresentationRegistry(
        modules: [
            .init(NumberCompareOperandPresentationModule()),
            .init(ControlValueCompareOperandPresentationModule()),
            .init(SceneStateCompareOperandPresentationModule()),
        ]
    )
}

struct TriggerCompareOperandPresentation: Equatable, Sendable {
    let text: String
}

private protocol TriggerCompareOperandPresentationModule: Sendable {
    var identifier: String { get }
    func presentation(
        for value: HBJSONValue
    ) -> TriggerCompareOperandPresentation?
}

private struct AnyTriggerCompareOperandPresentationModule: Sendable {
    let identifier: String
    private let presentationImplementation:
        @Sendable (HBJSONValue) -> TriggerCompareOperandPresentation?

    init<Module: TriggerCompareOperandPresentationModule>(_ module: Module) {
        identifier = module.identifier
        presentationImplementation = module.presentation
    }

    func presentation(
        for value: HBJSONValue
    ) -> TriggerCompareOperandPresentation? {
        presentationImplementation(value)
    }
}

struct TriggerCompareOperandPresentationRegistry: Sendable {
    private let modules: [AnyTriggerCompareOperandPresentationModule]

    private init(modules: [AnyTriggerCompareOperandPresentationModule]) {
        let identifiers = modules.map(\.identifier)
        precondition(
            Set(identifiers).count == identifiers.count,
            "Compare-operand presenter identifiers must be unique."
        )
        self.modules = modules
    }

    var registeredIdentifiers: [String] { modules.map(\.identifier) }

    func presentation(
        for value: HBJSONValue
    ) -> TriggerCompareOperandPresentation? {
        modules.lazy.compactMap { $0.presentation(for: value) }.first
    }
}

private struct NumberCompareOperandPresentationModule:
    TriggerCompareOperandPresentationModule
{
    let identifier = "number"

    func presentation(
        for value: HBJSONValue
    ) -> TriggerCompareOperandPresentation? {
        guard value.boolValue == nil,
              let number = value.numberValue,
              number.isFinite else { return nil }
        return TriggerCompareOperandPresentation(
            text: value.compactConfigurationJSON
        )
    }
}

private struct ControlValueCompareOperandPresentationModule:
    TriggerCompareOperandPresentationModule
{
    let identifier = "control-value"

    func presentation(
        for value: HBJSONValue
    ) -> TriggerCompareOperandPresentation? {
        guard let wrapper = value.objectValue,
              wrapper.count == 1,
              let configuration = wrapper["ControlValue"] else {
            return nil
        }

        let device: String
        let control: String
        let projection: TriggerCompareCondition.Projection
        if let path = configuration.arrayValue {
            guard path.count == 2,
                  let parsedDevice = nonemptyConditionString(path[0]),
                  let parsedControl = nonemptyConditionString(path[1]) else {
                return nil
            }
            device = parsedDevice
            control = parsedControl
            projection = .observed
        } else {
            guard let fields = configuration.objectValue,
                  fields.count == 3,
                  Set(fields.keys) == ["Device", "Control", "Projection"],
                  let deviceValue = fields["Device"],
                  let parsedDevice = nonemptyConditionString(deviceValue),
                  let controlValue = fields["Control"],
                  let parsedControl = nonemptyConditionString(controlValue),
                  let projectionName = fields["Projection"]?.stringValue,
                  let parsedProjection = TriggerCompareCondition.Projection(
                      rawValue: projectionName.lowercased()
                  ) else {
                return nil
            }
            device = parsedDevice
            control = parsedControl
            projection = parsedProjection
        }

        let target = naturalConditionTarget(device: device, control: control)
        return TriggerCompareOperandPresentation(
            text: projection == .model
                ? "HomeBase target for \(target)"
                : target
        )
    }
}

private struct SceneStateCompareOperandPresentationModule:
    TriggerCompareOperandPresentationModule
{
    let identifier = "scene-state"

    func presentation(
        for value: HBJSONValue
    ) -> TriggerCompareOperandPresentation? {
        guard let wrapper = value.objectValue,
              wrapper.count == 1,
              let sceneValue = wrapper["SceneState"],
              let scene = nonemptyConditionString(sceneValue) else {
            return nil
        }
        return TriggerCompareOperandPresentation(
            text: "\(humanizedConditionIdentifier(scene)) scene"
        )
    }
}

private struct TriggerComparePresentation: Equatable, Sendable {
    let left: TriggerCompareOperandPresentation
    let relationship: TriggerCompareCondition.Relationship
    let right: TriggerCompareOperandPresentation

    init?(_ rawValue: HBJSONValue) {
        let context = TriggerConditionPluginContext(rawValue: rawValue)
        let registry = TriggerCompareOperandPresentationRegistry.standard
        guard context.type == "Compare",
              let values = context.payload?.arrayValue,
              values.count == 3,
              let left = registry.presentation(for: values[0]),
              let operation = values[1].stringValue,
              let relationship = TriggerCompareCondition.Relationship(
                  protocolOperator: operation
              ),
              let right = registry.presentation(for: values[2]) else {
            return nil
        }
        self.left = left
        self.relationship = relationship
        self.right = right
    }
}


struct TriggerCompareCondition: Equatable, Sendable {
    static let supportedOperators = ["=", "==", "!=", "<", ">", "<=", ">="]

    enum Relationship: CaseIterable, Equatable, Identifiable, Sendable {
        case equals
        case doesNotEqual
        case lessThan
        case lessThanOrEqual
        case greaterThan
        case greaterThanOrEqual

        var id: Self { self }

        var title: String {
            switch self {
            case .equals: "Equals"
            case .doesNotEqual: "Does Not Equal"
            case .lessThan: "Is Less Than"
            case .lessThanOrEqual: "Is Less Than or Equal To"
            case .greaterThan: "Is Greater Than"
            case .greaterThanOrEqual: "Is Greater Than or Equal To"
            }
        }

        init?(protocolOperator: String) {
            switch protocolOperator {
            case "=", "==": self = .equals
            case "!=": self = .doesNotEqual
            case "<": self = .lessThan
            case "<=": self = .lessThanOrEqual
            case ">": self = .greaterThan
            case ">=": self = .greaterThanOrEqual
            default: return nil
            }
        }

        func protocolOperator(preservingEqualityAlias alias: String) -> String {
            switch self {
            case .equals: alias == "=" ? "=" : "=="
            case .doesNotEqual: "!="
            case .lessThan: "<"
            case .lessThanOrEqual: "<="
            case .greaterThan: ">"
            case .greaterThanOrEqual: ">="
            }
        }
    }

    enum Projection: String, Equatable, Sendable {
        case observed
        case model
    }

    let device: String
    let control: String
    let projection: Projection
    let comparisonOperator: String
    let literal: HBJSONValue

    private let reference: HBJSONValue

    init?(_ rawValue: HBJSONValue) {
        let context = TriggerConditionPluginContext(rawValue: rawValue)
        guard context.type == "Compare",
              let values = context.payload?.arrayValue,
              values.count == 3,
              let reference = values[0].objectValue,
              reference.count == 1,
              let referenceValue = reference["ControlValue"],
              let parsedReference = Self.parseReference(referenceValue),
              let comparisonOperator = values[1].stringValue,
              Self.supportedOperators.contains(comparisonOperator),
              values[2].numberValue != nil else {
            return nil
        }
        device = parsedReference.device
        control = parsedReference.control
        projection = parsedReference.projection
        self.comparisonOperator = comparisonOperator
        literal = values[2]
        self.reference = referenceValue
    }

    init(
        device: String,
        control: String,
        comparisonOperator: String = "==",
        literal: HBJSONValue = .integer(0)
    ) {
        self.device = device
        self.control = control
        projection = .observed
        self.comparisonOperator = comparisonOperator
        self.literal = literal
        reference = .array([
            .string(device),
            .string(control),
        ])
    }

    private init(
        device: String,
        control: String,
        projection: Projection,
        comparisonOperator: String,
        literal: HBJSONValue,
        reference: HBJSONValue
    ) {
        self.device = device
        self.control = control
        self.projection = projection
        self.comparisonOperator = comparisonOperator
        self.literal = literal
        self.reference = reference
    }

    var rawValue: HBJSONValue {
        .object([
            "Compare": .array([
                .object([
                    "ControlValue": reference
                ]),
                .string(comparisonOperator),
                literal,
            ])
        ])
    }

    var isValid: Bool {
        !device.isEmpty
            && !control.isEmpty
            && Self.supportedOperators.contains(comparisonOperator)
            && literal.numberValue != nil
    }

    var usesExplicitProjection: Bool {
        reference.objectValue != nil
    }

    var relationship: Relationship {
        Relationship(protocolOperator: comparisonOperator) ?? .equals
    }

    func replacingTarget(device: String, control: String) -> Self {
        Self(
            device: device,
            control: control,
            projection: projection,
            comparisonOperator: comparisonOperator,
            literal: literal,
            reference: replacingReferenceTarget(
                device: device,
                control: control
            )
        )
    }

    func replacingOperator(_ operation: String) -> Self {
        Self(
            device: device,
            control: control,
            projection: projection,
            comparisonOperator: operation,
            literal: literal,
            reference: reference
        )
    }

    func replacingRelationship(
        _ relationship: Relationship,
        preservingEqualityAlias alias: String
    ) -> Self {
        replacingOperator(
            relationship.protocolOperator(preservingEqualityAlias: alias)
        )
    }

    func replacingLiteral(_ value: HBJSONValue) -> Self {
        Self(
            device: device,
            control: control,
            projection: projection,
            comparisonOperator: comparisonOperator,
            literal: value,
            reference: reference
        )
    }

    private func replacingReferenceTarget(
        device: String,
        control: String
    ) -> HBJSONValue {
        if var fields = reference.objectValue {
            fields["Device"] = .string(device)
            fields["Control"] = .string(control)
            return .object(fields)
        }
        return .array([.string(device), .string(control)])
    }

    private static func parseReference(
        _ value: HBJSONValue
    ) -> (device: String, control: String, projection: Projection)? {
        if let path = value.arrayValue,
           path.count == 2,
           let device = path[0].stringValue,
           let control = path[1].stringValue {
            return (device, control, .observed)
        }
        guard let fields = value.objectValue,
              let device = fields["Device"]?.stringValue,
              let control = fields["Control"]?.stringValue,
              let projectionName = fields["Projection"]?.stringValue,
              let projection = Projection(
                rawValue: projectionName.lowercased()
              ) else {
            return nil
        }
        return (device, control, projection)
    }
}

struct TriggerCompositeCondition: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case and = "And"
        case or = "Or"
        case xor = "Xor"
        case trueWhenInvalid = "TrueWhenInvalid"

        var title: String {
            switch self {
            case .and: "All of These"
            case .or: "Any of These"
            case .xor: "Exactly One of These"
            case .trueWhenInvalid: "Match When Unavailable"
            }
        }

        var creationIdentifier: String {
            switch self {
            case .and: "and"
            case .or: "or"
            case .xor: "xor"
            case .trueWhenInvalid: "true-when-invalid"
            }
        }

        var systemImage: String {
            switch self {
            case .and: "checklist"
            case .or: "list.bullet"
            case .xor: "1.circle"
            case .trueWhenInvalid: "exclamationmark.shield"
            }
        }
    }

    let kind: Kind
    let children: [HBJSONValue]

    init?(_ rawValue: HBJSONValue) {
        let context = TriggerConditionPluginContext(rawValue: rawValue)
        guard let type = context.type,
              let kind = Kind(rawValue: type),
              let payload = context.payload else {
            return nil
        }
        switch kind {
        case .and, .or, .xor:
            guard let children = payload.arrayValue,
                  children.allSatisfy(Self.isConditionObject) else {
                return nil
            }
            self.children = children
        case .trueWhenInvalid:
            guard Self.isConditionObject(payload) else { return nil }
            self.children = [payload]
        }
        self.kind = kind
    }

    init(kind: Kind, children: [HBJSONValue]) {
        self.kind = kind
        self.children = kind == .trueWhenInvalid
            ? Array(children.prefix(1))
            : children
    }

    var rawValue: HBJSONValue {
        switch kind {
        case .and, .or, .xor:
            .object([kind.rawValue: .array(children)])
        case .trueWhenInvalid:
            .object([kind.rawValue: children.first ?? Self.defaultChild])
        }
    }

    func replacingChild(at index: Int, with value: HBJSONValue) -> Self {
        guard children.indices.contains(index) else { return self }
        var updated = children
        updated[index] = value
        return Self(kind: kind, children: updated)
    }

    func appendingChild(_ value: HBJSONValue = defaultChild) -> Self {
        guard kind != .trueWhenInvalid || children.isEmpty else { return self }
        return Self(kind: kind, children: children + [value])
    }

    func removingChild(at index: Int) -> Self {
        guard children.indices.contains(index) else { return self }
        var updated = children
        updated.remove(at: index)
        return Self(kind: kind, children: updated)
    }

    static let defaultChild = TriggerCompareCondition(
        device: "",
        control: ""
    ).rawValue

    nonisolated private static func isConditionObject(
        _ value: HBJSONValue
    ) -> Bool {
        guard let object = value.objectValue,
              object.count == 1,
              object.keys.first?.isEmpty == false else {
            return false
        }
        return true
    }
}

extension TriggerConditionTypeModule {
    static let compare = TriggerConditionTypeModule(
        identifier: "Compare",
        wireType: "Compare",
        creationOption: TriggerConditionCreationOption(
            id: "compare",
            title: "Control Value",
            systemImage: "arrow.left.arrow.right",
            initialValue: TriggerCompareCondition(
                device: "",
                control: ""
            ).rawValue
        ),
        presentation: { context in
            guard let comparison = TriggerComparePresentation(context.rawValue)
            else { return nil }
            return TriggerConditionPluginPresentation(
                title: comparison.left.text,
                detail: "\(comparison.relationship.title) "
                    + comparison.right.text
            )
        },
        editingPlan: { context in
            TriggerCompareCondition(context.rawValue).map {
                .compare($0)
            } ?? .raw
        },
        validation: { context, _ in
            guard TriggerComparePresentation(context.rawValue) != nil else {
                return "This Compare condition does not have a supported configuration."
            }
            guard let comparison = TriggerCompareCondition(context.rawValue)
            else { return nil }
            if comparison.device.isEmpty || comparison.control.isEmpty {
                return "Choose a control."
            }
            guard comparison.literal.numberValue != nil else {
                return "Enter a numeric value."
            }
            return nil
        },
        makeEditorRows: { context in
            guard TriggerCompareCondition(context.rawValue.wrappedValue) != nil
            else { return nil }
            return AnyView(
                TriggerCompareConditionEditorRows(
                    rawValue: context.rawValue,
                    repository: context.repository
                )
            )
        }
    )

    static func composite(
        _ kind: TriggerCompositeCondition.Kind
    ) -> TriggerConditionTypeModule {
        TriggerConditionTypeModule(
            identifier: kind.rawValue,
            wireType: kind.rawValue,
            creationOption: TriggerConditionCreationOption(
                id: kind.creationIdentifier,
                title: kind.title,
                systemImage: kind.systemImage,
                initialValue: TriggerCompositeCondition(
                    kind: kind,
                    children: [TriggerCompositeCondition.defaultChild]
                ).rawValue
            ),
            presentation: { context in
                guard let composite = TriggerCompositeCondition(
                    context.rawValue
                ), composite.kind == kind else { return nil }
                let detail: String
                if kind == .trueWhenInvalid {
                    detail = "Keeps matching while its value is unavailable"
                } else {
                    let count = context.childCount
                        ?? composite.children.count
                    detail = "\(count) condition\(count == 1 ? "" : "s")"
                }
                return TriggerConditionPluginPresentation(
                    title: kind.title,
                    detail: detail
                )
            },
            editingPlan: { context in
                guard let composite = TriggerCompositeCondition(
                    context.rawValue
                ), composite.kind == kind else { return .raw }
                return .composite(composite)
            },
            validation: { context, validateChild in
                guard let composite = TriggerCompositeCondition(
                    context.rawValue
                ), composite.kind == kind else {
                    return "The “\(kind.title)” condition does not have a supported configuration."
                }
                for (index, child) in composite.children.enumerated() {
                    if let message = validateChild(child) {
                        return "Condition \(index + 1): \(message)"
                    }
                }
                return nil
            },
            children: { context in
                guard let composite = TriggerCompositeCondition(
                    context.rawValue
                ), composite.kind == kind else { return nil }
                return composite.children
            },
            makeEditorRows: { context in
                guard let composite = TriggerCompositeCondition(
                    context.rawValue.wrappedValue
                ), composite.kind == kind else { return nil }
                return AnyView(
                    TriggerCompositeConditionEditorRows(
                        rawValue: context.rawValue,
                        repository: context.repository
                    )
                )
            }
        )
    }

    static let legacyControlChange = TriggerConditionTypeModule(
        identifier: "ControlValueChange",
        wireType: "ControlValueChange",
        presentation: { context in
            guard let change = controlChangePresentation(context) else {
                return nil
            }
            var detail: String
            switch change.projection {
            case .observed:
                detail = "Device-reported value changes"
            case .model:
                detail = "HomeBase target changes"
            }
            if let value = change.expectedValue {
                detail += " to \(renderConditionOperand(value))"
            }
            return TriggerConditionPluginPresentation(
                title: naturalConditionTarget(
                    device: change.device,
                    control: change.control
                ),
                detail: detail
            )
        }
    )

    /// Matches exactly while its one nested condition cannot provide a valid
    /// value. “Invalid” is the engine's wire name; exposing that verbatim reads
    /// like an error state rather than a useful predicate in the trigger UI.
    static let invalid = TriggerConditionTypeModule(
        identifier: "Invalid",
        wireType: "Invalid",
        presentation: { context in
            guard let child = context.payload,
                  isTriggerConditionObject(child) else { return nil }
            return TriggerConditionPluginPresentation(
                title: "Unavailable",
                detail: "Matches when the condition below is unavailable"
            )
        }
    )

    /// Delay is authored as [on delay, off delay, nested condition]. The
    /// engine currently omits the nested condition from live descriptor
    /// children, but the two delays are still safe to present naturally.
    static let delay = TriggerConditionTypeModule(
        identifier: "Delay",
        wireType: "Delay",
        presentation: { context in
            guard let values = context.payload?.arrayValue,
                  values.count >= 3,
                  let onDelay = values[0].numberValue,
                  let offDelay = values[1].numberValue,
                  isTriggerConditionObject(values[2]) else { return nil }
            return TriggerConditionPluginPresentation(
                title: "Wait Before Matching",
                detail: delayConditionDescription(
                    onDelay: onDelay,
                    offDelay: offDelay
                )
            )
        }
    )

    static func legacyControlComparison(
        _ wireType: String,
        relationship: TriggerCompareCondition.Relationship
    ) -> TriggerConditionTypeModule {
        TriggerConditionTypeModule(
            identifier: wireType,
            wireType: wireType,
            presentation: { context in
                guard let values = legacyControlValues(context),
                      values.values.count == 3 else { return nil }
                return TriggerConditionPluginPresentation(
                    title: naturalConditionTarget(
                        device: values.device,
                        control: values.control
                    ),
                    detail: "\(relationship.title) "
                        + renderConditionOperand(values.values[2])
                )
            }
        )
    }

    static func raw(_ wireType: String) -> TriggerConditionTypeModule {
        TriggerConditionTypeModule(
            identifier: wireType,
            wireType: wireType
        )
    }

    static let rawFallback = TriggerConditionTypeModule(
        identifier: "raw-fallback",
        wireType: nil,
        creationOption: TriggerConditionCreationOption(
            id: "raw-json",
            title: "Raw JSON",
            systemImage: "curlybraces",
            initialValue: .object(["": .null])
        )
    )
}

private struct ControlChangePresentation {
    enum Projection {
        case observed
        case model
    }

    let device: String
    let control: String
    let projection: Projection
    let expectedValue: HBJSONValue?
}

private func controlChangePresentation(
    _ context: TriggerConditionPluginContext
) -> ControlChangePresentation? {
    guard let payload = context.payload else { return nil }
    if let values = payload.arrayValue {
        guard values.count == 2 || values.count == 3,
              let device = nonemptyConditionString(values[0]),
              let control = nonemptyConditionString(values[1]),
              values.count == 2 || validControlChangeValue(values[2]) else {
            return nil
        }
        let expectedValue: HBJSONValue?
        if values.count == 3 {
            expectedValue = values[2]
        } else {
            expectedValue = Optional.none
        }
        return ControlChangePresentation(
            device: device,
            control: control,
            projection: .observed,
            expectedValue: expectedValue
        )
    }

    guard let fields = payload.objectValue,
          fields.count == 3 || fields.count == 4,
          Set(fields.keys).isSubset(
              of: ["Device", "Control", "Projection", "Value"]
          ),
          let deviceValue = fields["Device"],
          let device = nonemptyConditionString(deviceValue),
          let controlValue = fields["Control"],
          let control = nonemptyConditionString(controlValue),
          let projectionValue = fields["Projection"]?.stringValue,
          let projection = controlChangeProjection(projectionValue),
          fields["Value"] == nil
              || validControlChangeValue(fields["Value"]!) else {
        return nil
    }
    return ControlChangePresentation(
        device: device,
        control: control,
        projection: projection,
        expectedValue: fields["Value"]
    )
}

private func controlChangeProjection(
    _ value: String
) -> ControlChangePresentation.Projection? {
    switch value.lowercased() {
    case "observed": .observed
    case "model": .model
    default: nil
    }
}

private func validControlChangeValue(_ value: HBJSONValue) -> Bool {
    guard value.boolValue == nil,
          let number = value.numberValue else { return false }
    return number.isFinite
}

private func nonemptyConditionString(_ value: HBJSONValue) -> String? {
    guard let string = value.stringValue, !string.isEmpty else { return nil }
    return string
}

private func legacyControlValues(
    _ context: TriggerConditionPluginContext
) -> (values: [HBJSONValue], device: String, control: String)? {
    guard let values = context.payload?.arrayValue,
          values.count >= 2,
          let device = values[0].stringValue,
          let control = values[1].stringValue else {
        return nil
    }
    return (values, device, control)
}

private func isTriggerConditionObject(_ value: HBJSONValue) -> Bool {
    guard let object = value.objectValue,
          object.count == 1,
          object.keys.first?.isEmpty == false else {
        return false
    }
    return true
}

private func delayConditionDescription(
    onDelay: Double,
    offDelay: Double
) -> String {
    let matching = onDelay == 0
        ? "Matches immediately"
        : "Waits \(naturalConditionDuration(onDelay)) before matching"
    let stopping = offDelay == 0
        ? "stops immediately"
        : "waits \(naturalConditionDuration(offDelay)) before stopping"
    return "\(matching); \(stopping)"
}

private func naturalConditionDuration(_ seconds: Double) -> String {
    if seconds.magnitude >= 3_600,
       seconds.truncatingRemainder(dividingBy: 3_600) == 0 {
        return naturalConditionUnit(seconds / 3_600, singular: "hour")
    }
    if seconds.magnitude >= 60,
       seconds.truncatingRemainder(dividingBy: 60) == 0 {
        return naturalConditionUnit(seconds / 60, singular: "minute")
    }
    return naturalConditionUnit(seconds, singular: "second")
}

private func naturalConditionUnit(
    _ value: Double,
    singular: String
) -> String {
    let amount = AutomationPresentationFormat.number(value)
    let unit = abs(value) == 1 ? singular : "\(singular)s"
    return "\(amount) \(unit)"
}

func rawPresentation(
    _ context: TriggerConditionPluginContext,
    title explicitTitle: String? = nil
) -> TriggerConditionPluginPresentation {
    let title = explicitTitle
        ?? context.type.map(humanizedConditionIdentifier)
        ?? "Unrecognized Condition"
    let detail: String?
    if let payload = context.payload, payload != .null {
        detail = truncatedConditionJSON(payload.compactConfigurationJSON)
    } else if context.type == nil {
        detail = truncatedConditionJSON(
            context.rawValue.compactConfigurationJSON
        )
    } else {
        detail = nil
    }
    return TriggerConditionPluginPresentation(title: title, detail: detail)
}

func humanizedConditionIdentifier(_ identifier: String) -> String {
    guard !identifier.isEmpty else { return identifier }
    var result = ""
    for character in identifier {
        if character == "_" || character == "-" {
            if result.last != " " { result.append(" ") }
            continue
        }
        if character.isUppercase,
           let last = result.last,
           last != " ",
           !last.isUppercase {
            result.append(" ")
        }
        result.append(character)
    }
    return result
}

func naturalConditionTarget(device: String, control: String) -> String {
    let deviceName = humanizedConditionIdentifier(device)
    let controlName = humanizedConditionIdentifier(control)
    guard !deviceName.isEmpty else { return controlName }
    guard !controlName.isEmpty else { return deviceName }
    return "\(deviceName) — \(controlName)"
}

private func renderConditionOperand(_ value: HBJSONValue) -> String {
    if let object = value.objectValue,
       object.count == 1,
       let entry = object.first {
        if entry.key == "ControlValue",
           let path = entry.value.arrayValue,
           path.count >= 2,
           let device = path[0].stringValue,
           let control = path[1].stringValue {
            return naturalConditionTarget(device: device, control: control)
        }
        if entry.key == "SceneState", let scene = entry.value.stringValue {
            return "scene \(scene)"
        }
    }
    if let string = value.stringValue { return string }
    return value.compactConfigurationJSON
}

private func truncatedConditionJSON(_ value: String) -> String {
    guard value.count > 220 else { return value }
    return String(value.prefix(217)) + "…"
}
