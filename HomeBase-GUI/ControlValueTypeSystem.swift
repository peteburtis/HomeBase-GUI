//
//  ControlValueTypeSystem.swift
//  HomeBase-GUI
//

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
    let tags: Set<String>

    init(
        kind: String,
        metadata: [String: HBJSONValue] = [:],
        tags: some Sequence<String> = []
    ) {
        self.kind = kind
        self.metadata = metadata
        self.tags = Set(tags)
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

    init<Plugin: ControlValueTypePlugin>(_ plugin: Plugin) {
        identifier = plugin.identifier
        matchScoreImplementation = plugin.matchScore
        supportsEditingImplementation = plugin.supportsEditing
        presentsStalenessImplementation = plugin.presentsStaleness
        makeBodyImplementation = { context in
            AnyView(plugin.makeBody(context: context))
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
