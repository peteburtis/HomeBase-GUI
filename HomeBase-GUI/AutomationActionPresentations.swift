//
//  AutomationActionPresentations.swift
//  HomeBase-GUI
//

import Foundation
import HomeBaseProtocol

/// One place to audit every nested value/expression for which the client has
/// a human-readable presenter. Unknown literals remain losslessly visible as
/// JSON; malformed known applications invalidate the enclosing description.
extension AutomationOperandPresentationRegistry {
    static let standard = AutomationOperandPresentationRegistry(
        applicationPlugins: [
            AnyAutomationOperandPresentationPlugin(
                UnderlyingOperandPresentationPlugin()
            ),
            AnyAutomationOperandPresentationPlugin(
                RandomOperandPresentationPlugin()
            ),
            AnyAutomationOperandPresentationPlugin(
                CycleOperandPresentationPlugin()
            ),
        ],
        literalPlugins: [
            AnyAutomationOperandPresentationPlugin(
                WhiteOperandPresentationPlugin()
            ),
            AnyAutomationOperandPresentationPlugin(
                RGBOperandPresentationPlugin()
            ),
            AnyAutomationOperandPresentationPlugin(
                XYOperandPresentationPlugin()
            ),
        ]
    )
}

struct AutomationOperandPresentation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case literal
        case underlying
        case random
        case cycle
    }

    let text: String
    let kind: Kind
}

private protocol AutomationOperandPresentationPlugin: Sendable {
    var identifier: String { get }
    var applicationKey: String? { get }
    func presentation(
        for value: HBJSONValue
    ) -> AutomationOperandPresentation?
}

private struct AnyAutomationOperandPresentationPlugin: Sendable {
    let identifier: String
    let applicationKey: String?
    private let presentationImplementation:
        @Sendable (HBJSONValue) -> AutomationOperandPresentation?

    init<Plugin: AutomationOperandPresentationPlugin>(_ plugin: Plugin) {
        identifier = plugin.identifier
        applicationKey = plugin.applicationKey
        presentationImplementation = plugin.presentation
    }

    func presentation(
        for value: HBJSONValue
    ) -> AutomationOperandPresentation? {
        presentationImplementation(value)
    }
}

struct AutomationOperandPresentationRegistry: Sendable {
    private let applicationPlugins: [AnyAutomationOperandPresentationPlugin]
    private let literalPlugins: [AnyAutomationOperandPresentationPlugin]
    private let applicationKeys: Set<String>

    private init(
        applicationPlugins: [AnyAutomationOperandPresentationPlugin],
        literalPlugins: [AnyAutomationOperandPresentationPlugin]
    ) {
        let identifiers = (applicationPlugins + literalPlugins)
            .map(\.identifier)
        precondition(
            Set(identifiers).count == identifiers.count,
            "Automation-operand presenter identifiers must be unique."
        )
        let keys = applicationPlugins.compactMap(\.applicationKey)
        precondition(
            keys.count == applicationPlugins.count
                && Set(keys).count == keys.count,
            "Automation application presenters must claim unique keys."
        )
        self.applicationPlugins = applicationPlugins
        self.literalPlugins = literalPlugins
        applicationKeys = Set(keys)
    }

    var registeredIdentifiers: [String] {
        (applicationPlugins + literalPlugins).map(\.identifier)
    }

    /// Returns nil only when the value looks like a known operand application
    /// but does not satisfy that application's complete schema.
    func presentation(
        for value: HBJSONValue
    ) -> AutomationOperandPresentation? {
        if let fields = value.objectValue,
           !applicationKeys.isDisjoint(with: fields.keys) {
            guard fields.count == 1,
                  let key = fields.keys.first,
                  let plugin = applicationPlugins.first(where: {
                      $0.applicationKey == key
                  }) else {
                return nil
            }
            return plugin.presentation(for: value)
        }

        for plugin in literalPlugins {
            if let presentation = plugin.presentation(for: value) {
                return presentation
            }
        }
        return AutomationOperandPresentation(
            text: automationLiteralText(value),
            kind: .literal
        )
    }

    fileprivate func isLiteral(_ value: HBJSONValue) -> Bool {
        guard let fields = value.objectValue else { return true }
        return applicationKeys.isDisjoint(with: fields.keys)
    }
}

private struct UnderlyingOperandPresentationPlugin:
    AutomationOperandPresentationPlugin
{
    let identifier = "underlying"
    let applicationKey: String? = "Underlying"

    func presentation(
        for value: HBJSONValue
    ) -> AutomationOperandPresentation? {
        guard value == .object(["Underlying": .bool(true)]) else {
            return nil
        }
        return AutomationOperandPresentation(
            text: "the value beneath this automation",
            kind: .underlying
        )
    }
}

private struct RandomOperandPresentationPlugin:
    AutomationOperandPresentationPlugin
{
    let identifier = "random"
    let applicationKey: String? = "Random"

    func presentation(
        for value: HBJSONValue
    ) -> AutomationOperandPresentation? {
        guard let outer = value.objectValue,
              outer.count == 1,
              let fields = outer["Random"]?.objectValue,
              Set(fields.keys).isSubset(of: ["Values", "Scope"]),
              let values = fields["Values"]?.arrayValue,
              !values.isEmpty,
              values.allSatisfy(
                  AutomationOperandPresentationRegistry.standard.isLiteral
              ),
              let scope = automationScope(fields["Scope"]) else {
            return nil
        }
        guard let valueList = automationOperandValueList(values) else {
            return nil
        }
        var text = "choose \(valueList)"
        if scope == "Leaf" {
            text += " independently for each device"
        }
        return AutomationOperandPresentation(text: text, kind: .random)
    }
}

private struct CycleOperandPresentationPlugin:
    AutomationOperandPresentationPlugin
{
    let identifier = "cycle"
    let applicationKey: String? = "Cycle"

    func presentation(
        for value: HBJSONValue
    ) -> AutomationOperandPresentation? {
        guard let outer = value.objectValue,
              outer.count == 1,
              let fields = outer["Cycle"]?.objectValue,
              Set(fields.keys).isSubset(
                  of: ["Values", "Order", "Sustain", "Transition", "Scope"]
              ),
              let values = fields["Values"]?.arrayValue,
              values.count >= 2,
              values.allSatisfy(
                  AutomationOperandPresentationRegistry.standard.isLiteral
              ),
              let order = automationOrder(fields["Order"]),
              let scope = automationScope(fields["Scope"]),
              automationSustainIsValid(fields["Sustain"]),
              automationTransitionIsValid(fields["Transition"]) else {
            return nil
        }

        guard let valueList = automationOperandValueList(values) else {
            return nil
        }
        var parts = ["cycle through \(valueList)"]
        if order == "Random" {
            parts.append("in random order")
        }
        if scope == "Leaf" {
            parts.append("independently for each device")
        }
        if let sustain = fields["Sustain"] {
            if let seconds = sustain.numberValue {
                parts.append(
                    "hold each for \(AutomationPresentationFormat.duration(seconds))"
                )
            } else {
                guard let description = automationSustainDescription(sustain)
                else { return nil }
                parts.append(description)
            }
        }
        if let transition = fields["Transition"] {
            if transition.stringValue == "Sustain" {
                parts.append("transitions match each hold")
            } else if let seconds = transition.numberValue {
                parts.append(
                    "\(AutomationPresentationFormat.duration(seconds)) transitions"
                )
            }
        }
        return AutomationOperandPresentation(
            text: parts.joined(separator: " • "),
            kind: .cycle
        )
    }
}

private struct WhiteOperandPresentationPlugin:
    AutomationOperandPresentationPlugin
{
    let identifier = "white"
    let applicationKey: String? = nil

    func presentation(
        for value: HBJSONValue
    ) -> AutomationOperandPresentation? {
        guard let fields = value.objectValue,
              fields.count == 1,
              let kelvin = fields["White"]?.numberValue,
              kelvin.isFinite else {
            return nil
        }
        return AutomationOperandPresentation(
            text: "\(AutomationPresentationFormat.number(kelvin)) K white",
            kind: .literal
        )
    }
}

private struct RGBOperandPresentationPlugin:
    AutomationOperandPresentationPlugin
{
    let identifier = "rgb"
    let applicationKey: String? = nil

    func presentation(
        for value: HBJSONValue
    ) -> AutomationOperandPresentation? {
        guard let fields = value.objectValue,
              fields.count == 1,
              let components = fields["RGB"]?.arrayValue,
              components.count == 3 else {
            return nil
        }
        let numbers = components.compactMap(\.numberValue)
        guard numbers.count == 3,
              numbers.allSatisfy({ $0.isFinite }) else {
            return nil
        }
        let text = numbers.map {
            "\(AutomationPresentationFormat.number($0 * 100))%"
        }.joined(separator: ", ")
        return AutomationOperandPresentation(
            text: "RGB(\(text))",
            kind: .literal
        )
    }
}

private struct XYOperandPresentationPlugin:
    AutomationOperandPresentationPlugin
{
    let identifier = "xy"
    let applicationKey: String? = nil

    func presentation(
        for value: HBJSONValue
    ) -> AutomationOperandPresentation? {
        guard let fields = value.objectValue,
              fields.count == 1,
              let components = fields["XY"]?.arrayValue,
              components.count == 2 else {
            return nil
        }
        let numbers = components.compactMap(\.numberValue)
        guard numbers.count == 2,
              numbers.allSatisfy({ $0.isFinite }) else {
            return nil
        }
        return AutomationOperandPresentation(
            text: "XY(\(numbers.map { AutomationPresentationFormat.number($0) }.joined(separator: ", ")))",
            kind: .literal
        )
    }
}

/// Exact wire action types understood by the engine. This list and the UI
/// manifest in `AutomationActionTypeRegistry.standard` are intentionally
/// exhaustive and kept adjacent to the human presentation implementation.
enum BuiltInAutomationActionKind: String, CaseIterable, Sendable {
    case controlSet = "ControlSet"
    case controlToggle = "ControlToggle"
    case controlHold = "ControlHold"
    case controlRelease = "ControlRelease"
    case wait = "Wait"
    case sceneApply = "SceneApply"
    case sceneActivate = "SceneActivate"
    case sceneClear = "SceneClear"
    case sceneClearAll = "SceneClearAll"
    case sceneToggle = "SceneToggle"
    case sceneSetBetween = "SceneSetBetween"
    case sequenceSet = "SequenceSet"
    case triggerReassert = "TriggerReassert"

    var identifier: String {
        switch self {
        case .controlSet: "control-set"
        case .controlToggle: "control-toggle"
        case .controlHold: "control-hold"
        case .controlRelease: "control-release"
        case .wait: "wait"
        case .sceneApply: "scene-apply"
        case .sceneActivate: "scene-activate"
        case .sceneClear: "scene-clear"
        case .sceneClearAll: "scene-clear-all"
        case .sceneToggle: "scene-toggle"
        case .sceneSetBetween: "scene-set-between"
        case .sequenceSet: "sequence-set"
        case .triggerReassert: "trigger-reassert"
        }
    }

    var displayName: String {
        switch self {
        case .controlSet: "Set Control"
        case .controlToggle: "Toggle Control"
        case .controlHold: "Hold Control"
        case .controlRelease: "Release Hold"
        case .wait: "Wait"
        case .sceneApply: "Apply Scene"
        case .sceneActivate: "Activate Scene"
        case .sceneClear: "Deactivate Scene"
        case .sceneClearAll: "Deactivate Scenes"
        case .sceneToggle: "Toggle Scene"
        case .sceneSetBetween: "Blend Scenes"
        case .sequenceSet: "Run Sequence"
        case .triggerReassert: "Reassert Triggers"
        }
    }

    var systemImage: String {
        switch self {
        case .controlSet: "slider.horizontal.3"
        case .controlToggle: "switch.2"
        case .controlHold: "pin"
        case .controlRelease: "xmark.circle"
        case .wait: "clock"
        case .sceneApply: "sparkles"
        case .sceneActivate: "sparkles.rectangle.stack"
        case .sceneClear, .sceneClearAll: "sparkles.square.filled.on.square"
        case .sceneToggle: "arrow.triangle.2.circlepath"
        case .sceneSetBetween: "slider.horizontal.below.square.filled.and.square"
        case .sequenceSet: "list.number"
        case .triggerReassert: "arrow.clockwise"
        }
    }

    var applicability: AutomationActionApplicability {
        switch self {
        case .sceneActivate:
            .overlayMode
        case .sceneClear, .sceneClearAll, .sceneToggle:
            .triggerMode
        default:
            .all
        }
    }
}

@MainActor
struct BuiltInActionPresentationPlugin: AutomationActionPresentationPlugin {
    let kind: BuiltInAutomationActionKind

    init(_ kind: BuiltInAutomationActionKind) {
        self.kind = kind
    }

    var identifier: String { kind.identifier }
    var actionType: String? { kind.rawValue }
    var displayName: String { kind.displayName }
    var systemImage: String { kind.systemImage }
    var applicability: AutomationActionApplicability { kind.applicability }

    func presentation(
        for action: SceneActionConfiguration
    ) -> AutomationActionPluginPresentation {
        guard action.type == kind.rawValue,
              let detail = detail(for: action.payload) else {
            return AutomationActionPluginPresentation(
                title: displayName,
                detail: action.rawValue.compactConfigurationJSON
            )
        }
        return AutomationActionPluginPresentation(
            title: displayName,
            detail: detail
        )
    }

    private func detail(for payload: HBJSONValue?) -> String? {
        guard let payload else { return nil }
        switch kind {
        case .controlSet:
            return controlSetDetail(payload)
        case .controlToggle:
            return controlToggleDetail(payload)
        case .controlHold:
            return controlHoldDetail(payload)
        case .controlRelease:
            guard let name = payload.stringValue else { return nil }
            return name.isEmpty ? "Unnamed hold" : name
        case .wait:
            guard let seconds = finiteNonnegative(payload) else { return nil }
            return AutomationPresentationFormat.duration(seconds)
        case .sceneApply:
            return sceneInvocationDetail(
                payload,
                allowedFields: ["Identifier", "Priority", "Timing"]
            )
        case .sceneActivate:
            return sceneInvocationDetail(
                payload,
                allowedFields: [
                    "Identifier", "Priority", "Timing", "ReleaseTiming",
                ]
            )
        case .sceneClear:
            return sceneInvocationDetail(
                payload,
                allowedFields: ["Identifier", "Timing"]
            )
        case .sceneClearAll:
            return sceneClearAllDetail(payload)
        case .sceneToggle:
            return sceneInvocationDetail(
                payload,
                allowedFields: ["Identifier"]
            )
        case .sceneSetBetween:
            return sceneSetBetweenDetail(payload)
        case .sequenceSet:
            return sequenceSetDetail(payload)
        case .triggerReassert:
            guard payload.boolValue == true else { return nil }
            return "Rebuild the current trigger schedule"
        }
    }
}

private struct AutomationControlCommandPresentation {
    let value: AutomationOperandPresentation
    let transition: Double?
}

private struct AutomationControlActionOptions {
    let clearsOverride: Bool
    let deactivatesConflictingScenes: Bool

    var detailParts: [String] {
        var parts: [String] = []
        if clearsOverride { parts.append("clears override") }
        if deactivatesConflictingScenes {
            parts.append("deactivates conflicting scenes")
        }
        return parts
    }
}

private func controlSetDetail(_ payload: HBJSONValue) -> String? {
    guard let values = payload.arrayValue,
          (3 ... 5).contains(values.count),
          let device = nonemptyString(values[0]),
          let control = nonemptyString(values[1]),
          let command = controlCommand(values[2]),
          let trailing = controlTrailing(Array(values.dropFirst(3))),
          !((command.value.kind == .random || command.value.kind == .cycle)
              && (trailing.options.clearsOverride
                  || trailing.options.deactivatesConflictingScenes)) else {
        return nil
    }
    var parts = [
        "\(device).\(control) "
            + (command.value.kind == .underlying ? "back to " : "to ")
            + command.value.text,
    ]
    appendCommandMetadata(
        command,
        priority: trailing.priority,
        options: trailing.options,
        to: &parts
    )
    return parts.joined(separator: " • ")
}

private func controlToggleDetail(_ payload: HBJSONValue) -> String? {
    guard let values = payload.arrayValue,
          (2 ... 3).contains(values.count),
          let device = nonemptyString(values[0]),
          let control = nonemptyString(values[1]),
          values.count < 3 || validPriority(values[2]) else {
        return nil
    }
    var parts = ["\(device).\(control)"]
    if values.count == 3 {
        parts.append(AutomationPresentationFormat.priority(values[2]))
    }
    return parts.joined(separator: " • ")
}

private func controlHoldDetail(_ payload: HBJSONValue) -> String? {
    guard let values = payload.arrayValue,
          (4 ... 6).contains(values.count),
          let device = nonemptyString(values[0]),
          let control = nonemptyString(values[1]),
          let command = controlCommand(values[2]),
          command.value.kind != .cycle,
          let name = values[3].stringValue,
          let trailing = controlTrailing(Array(values.dropFirst(4))),
          !(command.value.kind == .random
              && (trailing.options.clearsOverride
                  || trailing.options.deactivatesConflictingScenes)) else {
        return nil
    }
    var parts = [
        "\(device).\(control) at \(command.value.text) as “\(name)”",
    ]
    appendCommandMetadata(
        command,
        priority: trailing.priority,
        options: trailing.options,
        to: &parts
    )
    return parts.joined(separator: " • ")
}

private func controlCommand(
    _ value: HBJSONValue
) -> AutomationControlCommandPresentation? {
    let primary: HBJSONValue
    let transition: Double?
    if let values = value.arrayValue {
        guard (1 ... 2).contains(values.count) else { return nil }
        primary = values[0]
        if values.count == 2 {
            guard let parsed = finiteNonnegative(values[1]) else { return nil }
            transition = parsed
        } else {
            transition = nil
        }
    } else {
        primary = value
        transition = nil
    }
    guard let presentation = AutomationOperandPresentationRegistry.standard
        .presentation(for: primary) else {
        return nil
    }
    return AutomationControlCommandPresentation(
        value: presentation,
        transition: transition
    )
}

private func controlTrailing(
    _ values: [HBJSONValue]
) -> (priority: HBJSONValue?, options: AutomationControlActionOptions)? {
    guard values.count <= 2 else { return nil }
    var priority: HBJSONValue?
    var optionsValue: HBJSONValue?
    if let first = values.first {
        if first.objectValue != nil {
            guard values.count == 1 else { return nil }
            optionsValue = first
        } else {
            guard validPriority(first) else { return nil }
            priority = first
            if values.count == 2 { optionsValue = values[1] }
        }
    }
    guard let options = controlOptions(optionsValue) else { return nil }
    return (priority, options)
}

private func controlOptions(
    _ value: HBJSONValue?
) -> AutomationControlActionOptions? {
    guard let value else {
        return AutomationControlActionOptions(
            clearsOverride: false,
            deactivatesConflictingScenes: false
        )
    }
    guard let fields = value.objectValue,
          Set(fields.keys).isSubset(
              of: ["ClearsOverride", "DeactivatesConflictingScenes"]
          ),
          fields["ClearsOverride"] == nil
              || fields["ClearsOverride"]?.boolValue != nil,
          fields["DeactivatesConflictingScenes"] == nil
              || fields["DeactivatesConflictingScenes"]?.boolValue != nil else {
        return nil
    }
    return AutomationControlActionOptions(
        clearsOverride: fields["ClearsOverride"]?.boolValue ?? false,
        deactivatesConflictingScenes:
            fields["DeactivatesConflictingScenes"]?.boolValue ?? false
    )
}

private func appendCommandMetadata(
    _ command: AutomationControlCommandPresentation,
    priority: HBJSONValue?,
    options: AutomationControlActionOptions,
    to parts: inout [String]
) {
    if let transition = command.transition {
        parts.append(
            "\(AutomationPresentationFormat.duration(transition)) transition"
        )
    }
    if let priority {
        parts.append(AutomationPresentationFormat.priority(priority))
    }
    parts.append(contentsOf: options.detailParts)
}

private func sceneInvocationDetail(
    _ payload: HBJSONValue,
    allowedFields: Set<String>
) -> String? {
    if let identifier = nonemptyString(payload) { return identifier }
    guard let fields = payload.objectValue,
          Set(fields.keys).isSubset(of: allowedFields),
          let identifierValue = fields["Identifier"],
          let identifier = nonemptyString(identifierValue),
          fields["Priority"] == nil || validPriority(fields["Priority"]!),
          fields["Timing"] == nil
              || finiteNonnegative(fields["Timing"]!) != nil,
          fields["ReleaseTiming"] == nil
              || finiteNonnegative(fields["ReleaseTiming"]!) != nil else {
        return nil
    }
    var parts = [identifier]
    if let priority = fields["Priority"] {
        parts.append(AutomationPresentationFormat.priority(priority))
    }
    if let timing = fields["Timing"]?.numberValue {
        parts.append(
            "\(AutomationPresentationFormat.duration(timing)) transition"
        )
    }
    if let timing = fields["ReleaseTiming"]?.numberValue {
        parts.append(
            "\(AutomationPresentationFormat.duration(timing)) return"
        )
    }
    return parts.joined(separator: " • ")
}

private func sceneClearAllDetail(_ payload: HBJSONValue) -> String? {
    guard let fields = payload.objectValue,
          Set(fields.keys).isSubset(of: ["Scope", "Excluding"]),
          fields["Scope"]?.stringValue == "Global" else {
        return nil
    }
    var detail = "All global scenes"
    if let excludingValue = fields["Excluding"] {
        guard let excluding = stringList(excludingValue, allowsEmpty: true)
        else { return nil }
        if !excluding.isEmpty {
            detail += " except \(naturalList(excluding))"
        }
    }
    return detail
}

private func sceneSetBetweenDetail(_ payload: HBJSONValue) -> String? {
    guard let fields = payload.objectValue,
          Set(fields.keys) == ["StartScenes", "EndScenes", "Position"]
              || Set(fields.keys) == [
                  "StartScenes", "EndScenes", "Position", "Priority",
              ]
              || Set(fields.keys) == [
                  "StartScenes", "EndScenes", "Position", "Timing",
              ]
              || Set(fields.keys) == [
                  "StartScenes", "EndScenes", "Position", "Priority", "Timing",
              ],
          let starts = stringList(fields["StartScenes"]!, allowsEmpty: false),
          Set(starts).count == starts.count,
          let ends = stringList(fields["EndScenes"]!, allowsEmpty: false),
          Set(ends).count == ends.count,
          let position = fields["Position"]?.numberValue,
          position.isFinite,
          (0 ... 1).contains(position),
          fields["Priority"] == nil || validPriority(fields["Priority"]!),
          fields["Timing"] == nil
              || finiteNonnegative(fields["Timing"]!) != nil else {
        return nil
    }
    var parts = [
        "\(AutomationPresentationFormat.percent(position)) from "
            + starts.joined(separator: " + ")
            + " toward " + ends.joined(separator: " + "),
    ]
    if let priority = fields["Priority"] {
        parts.append(AutomationPresentationFormat.priority(priority))
    }
    if let timing = fields["Timing"]?.numberValue {
        parts.append(
            "\(AutomationPresentationFormat.duration(timing)) transition"
        )
    }
    return parts.joined(separator: " • ")
}

private func sequenceSetDetail(_ payload: HBJSONValue) -> String? {
    if let identifier = nonemptyString(payload) { return identifier }
    let allowed = Set([
        "Identifier", "Duration", "Priority", "Timing", "ReleaseTiming",
    ])
    guard let fields = payload.objectValue,
          Set(fields.keys).isSubset(of: allowed),
          let identifierValue = fields["Identifier"],
          let identifier = nonemptyString(identifierValue),
          fields["Duration"] == nil
              || finiteNonnegative(fields["Duration"]!) != nil,
          fields["Priority"] == nil || validPriority(fields["Priority"]!),
          fields["Timing"] == nil
              || finiteNonnegative(fields["Timing"]!) != nil,
          fields["ReleaseTiming"] == nil
              || finiteNonnegative(fields["ReleaseTiming"]!) != nil else {
        return nil
    }
    var parts = [identifier]
    if let duration = fields["Duration"]?.numberValue {
        parts.append(
            "\(AutomationPresentationFormat.duration(duration)) duration"
        )
    }
    if let priority = fields["Priority"] {
        parts.append(AutomationPresentationFormat.priority(priority))
    }
    if let timing = fields["Timing"]?.numberValue {
        parts.append(
            "\(AutomationPresentationFormat.duration(timing)) transition"
        )
    }
    if let timing = fields["ReleaseTiming"]?.numberValue {
        parts.append(
            "\(AutomationPresentationFormat.duration(timing)) return"
        )
    }
    return parts.joined(separator: " • ")
}

enum AutomationPresentationFormat {
    nonisolated static let userPriority = Int64(Int32.max)
    nonisolated static let userPriorityLabel = "P-User"

    static func priority(_ value: HBJSONValue) -> String {
        guard let number = exactInteger(value) else {
            return value.compactConfigurationJSON
        }
        return priority(number)
    }

    static func priority(_ value: Int64) -> String {
        value == userPriority
            ? userPriorityLabel
            : "P-\(value)"
    }

    static func number(_ value: Double) -> String {
        String(format: "%.6g", value)
    }

    static func percent(_ unitValue: Double) -> String {
        let percent = unitValue * 100
        let rounded = percent.rounded()
        return abs(percent - rounded) < 0.05
            ? "\(Int(rounded))%"
            : "\(String(format: "%.1f", percent))%"
    }

    static func duration(_ seconds: Double) -> String {
        if seconds >= 3_600, seconds.truncatingRemainder(dividingBy: 3_600) == 0 {
            return unit(seconds / 3_600, singular: "hr")
        }
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 {
            return unit(seconds / 60, singular: "min")
        }
        return unit(seconds, singular: "sec")
    }

    private static func unit(
        _ value: Double,
        singular: String
    ) -> String {
        "\(number(value)) \(singular)"
    }
}

private func finiteNonnegative(_ value: HBJSONValue) -> Double? {
    guard let number = value.numberValue,
          number.isFinite,
          number >= 0 else {
        return nil
    }
    return number
}

private func exactInteger(_ value: HBJSONValue) -> Int64? {
    if let integer = value.integerValue { return integer }
    guard let number = value.numberValue,
          number.isFinite,
          let integer = Int64(exactly: number) else {
        return nil
    }
    return integer
}

private func validPriority(_ value: HBJSONValue) -> Bool {
    guard let integer = exactInteger(value) else { return false }
    return integer >= Int64(Int32.min) && integer <= Int64(Int32.max)
}

private func nonemptyString(_ value: HBJSONValue) -> String? {
    guard let string = value.stringValue, !string.isEmpty else { return nil }
    return string
}

private func stringList(
    _ value: HBJSONValue,
    allowsEmpty: Bool
) -> [String]? {
    guard let values = value.arrayValue,
          allowsEmpty || !values.isEmpty else {
        return nil
    }
    let strings = values.compactMap(nonemptyString)
    return strings.count == values.count ? strings : nil
}

private func naturalList(_ values: [String]) -> String {
    switch values.count {
    case 0: return ""
    case 1: return values[0]
    case 2: return "\(values[0]) and \(values[1])"
    default:
        return values.dropLast().joined(separator: ", ")
            + ", and \(values.last!)"
    }
}

private func automationScope(_ value: HBJSONValue?) -> String? {
    guard let value else { return "Group" }
    guard let scope = value.stringValue,
          scope == "Group" || scope == "Leaf" else {
        return nil
    }
    return scope
}

private func automationOrder(_ value: HBJSONValue?) -> String? {
    guard let value else { return "Sequential" }
    guard let order = value.stringValue,
          order == "Sequential" || order == "Random" else {
        return nil
    }
    return order
}

private func automationSustainIsValid(_ value: HBJSONValue?) -> Bool {
    guard let value else { return true }
    if finiteNonnegative(value) != nil { return true }
    guard let outer = value.objectValue,
          outer.count == 1,
          let fields = outer["Cycle"]?.objectValue,
          Set(fields.keys).isSubset(of: ["Values", "Order"]),
          let values = fields["Values"]?.arrayValue,
          values.count >= 2,
          values.allSatisfy({ finiteNonnegative($0) != nil }),
          automationOrder(fields["Order"]) != nil else {
        return false
    }
    return true
}

private func automationSustainDescription(
    _ value: HBJSONValue
) -> String? {
    guard let outer = value.objectValue,
          outer.count == 1,
          let fields = outer["Cycle"]?.objectValue,
          Set(fields.keys).isSubset(of: ["Values", "Order"]),
          let values = fields["Values"]?.arrayValue,
          values.count >= 2,
          let order = automationOrder(fields["Order"]) else {
        return nil
    }
    let durations = values.compactMap { value -> String? in
        guard let seconds = finiteNonnegative(value) else { return nil }
        return AutomationPresentationFormat.duration(seconds)
    }
    guard durations.count == values.count else { return nil }
    var description = "hold for \(compactNaturalList(durations))"
    if order == "Random" {
        description += " in random order"
    }
    return description
}

private func automationTransitionIsValid(_ value: HBJSONValue?) -> Bool {
    guard let value else { return true }
    return finiteNonnegative(value) != nil || value.stringValue == "Sustain"
}

private func automationLiteralText(_ value: HBJSONValue) -> String {
    if let string = value.stringValue { return string }
    if let number = value.numberValue, number.isFinite {
        return AutomationPresentationFormat.number(number)
    }
    if let boolean = value.boolValue { return boolean ? "true" : "false" }
    if value == .null { return "null" }
    return value.compactConfigurationJSON
}

private func automationOperandValueList(
    _ values: [HBJSONValue]
) -> String? {
    let descriptions = values.compactMap {
        AutomationOperandPresentationRegistry.standard.presentation(for: $0)?
            .text
    }
    guard descriptions.count == values.count else { return nil }
    return compactNaturalList(descriptions)
}

private func compactNaturalList(_ values: [String]) -> String {
    let abbreviated = values.map { value in
        guard value.count > 36 else { return value }
        return String(value.prefix(35)) + "…"
    }
    guard abbreviated.count > 4 else {
        return naturalList(abbreviated)
    }
    return abbreviated.prefix(3).joined(separator: ", ")
        + ", and \(abbreviated.count - 3) more"
}
