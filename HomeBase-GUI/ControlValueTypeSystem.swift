//
//  ControlValueTypeSystem.swift
//  HomeBase-GUI
//

import Foundation
import HomeBaseProtocol
import SwiftUI

/// The semantic contract a value presenter/editor receives from HomeBase.
///
/// `kind` is the primary dispatch key. It is deliberately open and may be a
/// versioned structured schema such as `color-v1:RGB+White+XY` or
/// `position-v1`. Metadata refines that schema with capabilities such as
/// writability, scalar bounds, precision, and units.
struct ControlValueSchema: Equatable {
    let kind: String
    let metadata: [String: HBJSONValue]

    init(
        kind: String,
        metadata: [String: HBJSONValue] = [:]
    ) {
        self.kind = kind
        self.metadata = metadata
    }

    var normalizedKind: String {
        kind.lowercased()
    }

    var isReadable: Bool {
        metadata["readable"]?.boolValue == true
    }

    var isWritable: Bool {
        metadata["writable"]?.boolValue == true
    }

    var isStructured: Bool {
        metadata["structured"]?.boolValue == true
    }

    var presentationHint: String? {
        metadata["presentation"]?.stringValue?.lowercased()
    }

    var scalarRange: ClosedRange<Double>? {
        guard !isStructured,
              let minimum = metadata["minimum"]?.numberValue,
              let maximum = metadata["maximum"]?.numberValue,
              minimum.isFinite,
              maximum.isFinite,
              minimum < maximum else {
            return nil
        }
        return minimum ... maximum
    }
}

/// One source-independent value snapshot. Live controls and scene drafts both
/// adapt into this shape before a type plugin sees them.
struct ControlValueSnapshot: Equatable {
    let value: HBJSONValue?
    let displayText: String
    let aggregateState: HBControlAggregateState?
    let aggregateValues: [HBJSONValue]?
    let aggregateValueCount: Int?
    let isStale: Bool

    init(
        value: HBJSONValue?,
        displayText: String,
        aggregateState: HBControlAggregateState? = nil,
        aggregateValues: [HBJSONValue]? = nil,
        aggregateValueCount: Int? = nil,
        isStale: Bool = false
    ) {
        self.value = value
        self.displayText = displayText
        self.aggregateState = aggregateState
        self.aggregateValues = aggregateValues
        self.aggregateValueCount = aggregateValueCount
        self.isStale = isStale
    }
}

/// A generic observation stream for editors that remain open while their
/// backing live value changes. Draft-backed editors can provide an empty
/// stream while using the same plugin UI.
struct ControlValueObservation: Equatable, Sendable {
    let value: HBJSONValue?
    let aggregateState: HBControlAggregateState?
    let aggregateValues: [HBJSONValue]?
    let aggregateValueCount: Int?

    init(
        value: HBJSONValue?,
        aggregateState: HBControlAggregateState? = nil,
        aggregateValues: [HBJSONValue]? = nil,
        aggregateValueCount: Int? = nil
    ) {
        self.value = value
        self.aggregateState = aggregateState
        self.aggregateValues = aggregateValues
        self.aggregateValueCount = aggregateValueCount
    }
}

enum ControlValueCommitOrigin: Equatable, Sendable {
    /// An inline control whose containing live view is still present.
    case inline
    /// A pushed or otherwise independent editor which may outlive its source
    /// view and therefore may need to reactivate its connection.
    case editor
}

/// Source behavior supplied to a plugin. A live adapter sends writes to the
/// daemon; a scene adapter will mutate its local document draft instead.
struct ControlValueInteraction {
    let isEnabled: Bool
    let isUpdating: Bool
    let commit: (HBJSONValue, ControlValueCommitOrigin) async throws -> Void
    let observations: () -> AsyncThrowingStream<ControlValueObservation, Error>
}

struct ControlValuePresentationContext {
    let schema: ControlValueSchema
    let snapshot: ControlValueSnapshot
    let interaction: ControlValueInteraction
    let accessibilityLabel: String
    let controlPath: String
}

extension HBControlDescriptor {
    var controlValueSchema: ControlValueSchema {
        ControlValueSchema(
            kind: kind,
            metadata: metadata
        )
    }

    /// The value snapshot published by `device.list`. Aggregate controls put
    /// their constituent state in descriptor metadata because a mixed value
    /// deliberately has no single JSON representation.
    var listedControlValueSnapshot: ControlValueSnapshot {
        let displayText = metadata["displayValue"]?.stringValue
            ?? value?.presentationText
            ?? "—"
        return ControlValueSnapshot(
            value: value,
            displayText: displayText,
            aggregateState: aggregateState,
            aggregateValues: aggregateValues,
            aggregateValueCount: aggregateValueCount,
            isStale: metadata["valid"]?.boolValue == false
        )
    }

    var aggregateState: HBControlAggregateState? {
        guard let value = metadata["aggregateState"]?.stringValue else {
            return nil
        }
        return HBControlAggregateState(rawValue: value)
    }

    var aggregateValues: [HBJSONValue]? {
        metadata["aggregateValues"]?.arrayValue
    }

    var aggregateValueCount: Int? {
        guard let value = metadata["aggregateValueCount"]?.integerValue else {
            return nil
        }
        return Int(exactly: value)
    }
}

extension HBJSONValue {
    var presentationText: String {
        switch self {
        case .null:
            "null"
        case .bool(let value):
            value ? "True" : "False"
        case .integer(let value):
            String(value)
        case .number(let value):
            value.formatted(
                .number.precision(.fractionLength(0 ... 6))
            )
        case .string(let value):
            value
        case .array, .object:
            compactJSONString
        }
    }

    private var compactJSONString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else {
            return "—"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Relative scores make plugin selection independent of registration order.
/// A plugin may use an intermediate score when it has a meaningful subtype
/// relationship, but exact schemas should always outrank schema families and
/// generic capability matches.
enum ControlValueTypeMatchSpecificity {
    static let exactSchema = 1_000
    static let schemaFamily = 750
    static let genericCapabilities = 250
}

/// A modular value presenter/editor. Implementing one conforming type and
/// registering it is sufficient to use that UI with any compatible data
/// source, including live controls and scene-file drafts.
@MainActor
protocol ControlValueTypePlugin {
    associatedtype Body: View

    var identifier: String { get }
    func matchScore(for schema: ControlValueSchema) -> Int?
    func supportsEditing(context: ControlValuePresentationContext) -> Bool
    func presentsStaleness(for snapshot: ControlValueSnapshot) -> Bool
    @ViewBuilder
    func makeBody(context: ControlValuePresentationContext) -> Body
}

/// Optional full-screen editing supplied by the same module that owns compact
/// control presentation. This is used when a configuration editor must ask
/// for a value rather than copy an unambiguous current value.
@MainActor
protocol ControlValueStandaloneEditingPlugin: ControlValueTypePlugin {
    associatedtype StandaloneEditor: View

    func supportsStandaloneEditing(
        context: ControlValuePresentationContext
    ) -> Bool

    @ViewBuilder
    func makeStandaloneEditor(
        context: ControlValuePresentationContext
    ) -> StandaloneEditor
}

extension ControlValueTypePlugin {
    func supportsEditing(
        context: ControlValuePresentationContext
    ) -> Bool {
        false
    }
}

@MainActor
struct AnyControlValueTypePlugin: Identifiable {
    let identifier: String

    var id: String { identifier }

    private let matchScoreImplementation: (ControlValueSchema) -> Int?
    private let supportsEditingImplementation:
        (ControlValuePresentationContext) -> Bool
    private let presentsStalenessImplementation: (ControlValueSnapshot) -> Bool
    private let makeBodyImplementation:
        (ControlValuePresentationContext) -> AnyView
    private let supportsStandaloneEditingImplementation:
        (ControlValuePresentationContext) -> Bool
    private let makeStandaloneEditorImplementation:
        ((ControlValuePresentationContext) -> AnyView)?

    init<Plugin: ControlValueTypePlugin>(_ plugin: Plugin) {
        identifier = plugin.identifier
        matchScoreImplementation = plugin.matchScore
        supportsEditingImplementation = plugin.supportsEditing
        presentsStalenessImplementation = plugin.presentsStaleness
        makeBodyImplementation = { context in
            AnyView(plugin.makeBody(context: context))
        }
        supportsStandaloneEditingImplementation = { _ in false }
        makeStandaloneEditorImplementation = nil
    }

    init<Plugin: ControlValueStandaloneEditingPlugin>(
        standaloneEditing plugin: Plugin
    ) {
        identifier = plugin.identifier
        matchScoreImplementation = plugin.matchScore
        supportsEditingImplementation = plugin.supportsEditing
        presentsStalenessImplementation = plugin.presentsStaleness
        makeBodyImplementation = { context in
            AnyView(plugin.makeBody(context: context))
        }
        supportsStandaloneEditingImplementation =
            plugin.supportsStandaloneEditing
        makeStandaloneEditorImplementation = { context in
            AnyView(plugin.makeStandaloneEditor(context: context))
        }
    }

    func matchScore(for schema: ControlValueSchema) -> Int? {
        matchScoreImplementation(schema)
    }

    func supportsEditing(
        context: ControlValuePresentationContext
    ) -> Bool {
        supportsEditingImplementation(context)
    }

    func presentsStaleness(
        for snapshot: ControlValueSnapshot
    ) -> Bool {
        presentsStalenessImplementation(snapshot)
    }

    func makeBody(context: ControlValuePresentationContext) -> AnyView {
        makeBodyImplementation(context)
    }

    func supportsStandaloneEditing(
        context: ControlValuePresentationContext
    ) -> Bool {
        makeStandaloneEditorImplementation != nil
            && supportsStandaloneEditingImplementation(context)
    }

    func makeStandaloneEditor(
        context: ControlValuePresentationContext
    ) -> AnyView? {
        guard supportsStandaloneEditing(context: context) else { return nil }
        return makeStandaloneEditorImplementation?(context)
    }
}

/// Deterministic registry for control-value UI. Unknown schemas always resolve
/// to the fallback. Equal best scores are surfaced in `competingIdentifiers`
/// and then broken by plugin identifier so production UI remains stable while
/// tests can reject an ambiguous registration.
@MainActor
struct ControlValueTypeRegistry {
    struct Resolution {
        let plugin: AnyControlValueTypePlugin
        let score: Int?
        let competingIdentifiers: [String]

        var isAmbiguous: Bool {
            competingIdentifiers.count > 1
        }
    }

    let plugins: [AnyControlValueTypePlugin]
    let fallback: AnyControlValueTypePlugin

    init(
        plugins: [AnyControlValueTypePlugin],
        fallback: AnyControlValueTypePlugin
    ) {
        let identifiers = plugins.map(\.identifier) + [fallback.identifier]
        precondition(
            Set(identifiers).count == identifiers.count,
            "Control-value plugin identifiers must be unique."
        )
        self.plugins = plugins
        self.fallback = fallback
    }

    func resolve(_ schema: ControlValueSchema) -> Resolution {
        let candidates = plugins.compactMap { plugin -> (
            plugin: AnyControlValueTypePlugin,
            score: Int
        )? in
            guard let score = plugin.matchScore(for: schema) else {
                return nil
            }
            return (plugin, score)
        }

        guard let bestScore = candidates.map(\.score).max() else {
            return Resolution(
                plugin: fallback,
                score: nil,
                competingIdentifiers: []
            )
        }

        let best = candidates
            .filter { $0.score == bestScore }
            .map(\.plugin)
            .sorted { $0.identifier < $1.identifier }
        return Resolution(
            plugin: best[0],
            score: bestScore,
            competingIdentifiers: best.map(\.identifier)
        )
    }
}
