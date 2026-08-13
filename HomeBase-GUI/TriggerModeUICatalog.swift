//
//  TriggerModeUICatalog.swift
//  HomeBase-GUI
//

import Foundation
import HomeBaseProtocol

/// The UI and protocol mapping for one supported trigger mode.
struct TriggerModeUIRegistration: Identifiable, Equatable, Sendable {
    let wireValue: String
    let displayName: String
    let mode: HBTriggerMode
    let showsLastFired: Bool

    var id: String { wireValue }

    var actionConfigurationContext: AutomationActionConfigurationContext {
        .trigger(mode)
    }
}

/// The single catalog of trigger modes that can be configured in the app.
enum TriggerModeUICatalog {
    static let supported: [TriggerModeUIRegistration] = [
        .init(
            wireValue: "Trigger",
            displayName: "Trigger",
            mode: .trigger,
            showsLastFired: true
        ),
        .init(
            wireValue: "Overlay",
            displayName: "Overlay",
            mode: .overlay,
            showsLastFired: false
        ),
    ]

    static let defaultRegistration = supported[0]

    static func registration(
        forWireValue wireValue: String?
    ) -> TriggerModeUIRegistration? {
        guard let wireValue else { return nil }
        return supported.first { $0.wireValue == wireValue }
    }

    static func registration(
        for mode: HBTriggerMode
    ) -> TriggerModeUIRegistration {
        guard let registration = supported.first(where: { $0.mode == mode })
        else {
            preconditionFailure(
                "Every protocol trigger mode must have a UI registration."
            )
        }
        return registration
    }

    static func registration(
        caseInsensitiveWireValue wireValue: String
    ) -> TriggerModeUIRegistration? {
        supported.first {
            $0.wireValue.caseInsensitiveCompare(wireValue) == .orderedSame
        }
    }

    /// Unrecognized editor values use the default Trigger action context until
    /// validation rejects them.
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
