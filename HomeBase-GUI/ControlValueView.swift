//
//  ControlValueView.swift
//  HomeBase-GUI
//

import Foundation
import HomeBaseProtocol
import SwiftUI

enum ControlWriteDiagnostics {
    static func logNumeric(
        stage: String,
        control: String,
        value: Double
    ) {
#if DEBUG
        print(
            "[HomeBase ControlWrite] stage=\(stage) "
                + "control=\(control) numeric=\(description(of: value))"
        )
#endif
    }

    static func log(
        stage: String,
        control: String,
        value: HBJSONValue
    ) {
#if DEBUG
        print(
            "[HomeBase ControlWrite] stage=\(stage) "
                + "control=\(control) value=\(description(of: value))"
        )
#endif
    }

    static func description(of value: HBJSONValue) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let value):
            return "bool(\(value))"
        case .integer(let value):
            return "integer(\(value))"
        case .number(let value):
            return "number(\(description(of: value)))"
        case .string:
            return "string"
        case .array(let values):
            return "array(count=\(values.count))"
        case .object(let values):
            return "object(count=\(values.count))"
        }
    }

    static func description(of value: Double) -> String {
        String(format: "%.17g", value)
    }
}

extension LiveDeviceControl {
    var valueSchema: ControlValueSchema {
        ControlValueSchema(
            kind: descriptor.kind,
            metadata: details?.metadata ?? [:],
            tags: Set(descriptor.tags).union(details?.tags ?? [])
        )
    }

    var valueSnapshot: ControlValueSnapshot {
        ControlValueSnapshot(
            value: pendingValue ?? value,
            displayText: presentedValue,
            aggregateState: aggregateState,
            aggregateValues: aggregateValues,
            aggregateValueCount: aggregateValueCount,
            isStale: valid == false
        )
    }

    var valuePresentationHandlesStaleness: Bool {
        let resolution = ControlValueTypeRegistry.standard.resolve(
            valueSchema
        )
        return resolution.plugin.presentsStaleness(for: valueSnapshot)
    }
}

/// Host for source-independent control-value plugins. This view adapts a live
/// control today; scene-file drafts can construct the same presentation
/// context without depending on `LiveDeviceControl`.
struct ControlValueView: View {
    let control: LiveDeviceControl
    let interactionEnabled: Bool
    let setValue:
        (HBJSONValue, ControlValueCommitOrigin) async throws -> Void
    let values: () -> AsyncThrowingStream<ControlValueObservation, Error>

    var body: some View {
        HStack(spacing: 8) {
            ControlValuePluginView(context: context)

            if control.isUpdating {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var context: ControlValuePresentationContext {
        ControlValuePresentationContext(
            schema: control.valueSchema,
            snapshot: control.valueSnapshot,
            interaction: ControlValueInteraction(
                isEnabled: interactionEnabled,
                isUpdating: control.isUpdating,
                commit: setValue,
                observations: values
            ),
            accessibilityLabel: control.displayName,
            controlPath: control.descriptor.control
        )
    }
}

/// The shared host for a resolved control-value plugin. Live controls and
/// configuration drafts both construct a source-specific context and render
/// it through this same view.
struct ControlValuePluginView: View {
    let context: ControlValuePresentationContext

    var body: some View {
        resolution.plugin.makeBody(context: context)
    }

    private var resolution: ControlValueTypeRegistry.Resolution {
        ControlValueTypeRegistry.standard.resolve(context.schema)
    }
}
