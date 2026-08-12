//
//  TriggerKindUICatalog.swift
//  HomeBase-GUI
//

import Foundation
import HomeBaseProtocol

/// The UI and protocol mapping for one supported trigger configuration type.
struct TriggerKindUIRegistration: Identifiable, Equatable, Sendable {
    let wireValue: String
    let displayName: String
    let kind: HBTriggerKind
    let showsLastFired: Bool

    var id: String { wireValue }

    var actionConfigurationContext: AutomationActionConfigurationContext {
        .trigger(kind)
    }
}

/// The single catalog of trigger kinds that can be configured in the app.
enum TriggerKindUICatalog {
    static let supported: [TriggerKindUIRegistration] = [
        .init(
            wireValue: "When",
            displayName: "When",
            kind: .when,
            showsLastFired: true
        ),
        .init(
            wireValue: "While",
            displayName: "While",
            kind: .while,
            showsLastFired: false
        ),
    ]

    static let defaultRegistration = supported[0]

    static func registration(
        forWireValue wireValue: String?
    ) -> TriggerKindUIRegistration? {
        guard let wireValue else { return nil }
        return supported.first { $0.wireValue == wireValue }
    }

    static func registration(
        for kind: HBTriggerKind
    ) -> TriggerKindUIRegistration {
        guard let registration = supported.first(where: { $0.kind == kind })
        else {
            preconditionFailure(
                "Every protocol trigger kind must have a UI registration."
            )
        }
        return registration
    }

    static func registration(
        caseInsensitiveWireValue wireValue: String
    ) -> TriggerKindUIRegistration? {
        supported.first {
            $0.wireValue.caseInsensitiveCompare(wireValue) == .orderedSame
        }
    }

    /// Retains the editor's existing behavior: values other than While use
    /// the default When action context until validation rejects them.
    static func actionConfigurationContext(
        forEditorWireValue wireValue: String
    ) -> AutomationActionConfigurationContext {
        registration(caseInsensitiveWireValue: wireValue)?
            .actionConfigurationContext
            ?? defaultRegistration.actionConfigurationContext
    }

    static var supportedWireValueDescription: String {
        supported
            .map { "\"\($0.wireValue)\"" }
            .joined(separator: " or ")
    }
}
