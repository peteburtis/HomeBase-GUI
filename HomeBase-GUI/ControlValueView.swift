//
//  ControlValueView.swift
//  HomeBase-GUI
//

import Foundation
import HomeBaseProtocol
import SwiftUI

enum ControlValuePresentation: Equatable {
    case toggle(Bool)
    case slider(value: Double, range: ClosedRange<Double>)
    case color(HomeBaseColorReadoutPresentation)
    case text(String)

    var presentsStaleness: Bool {
        if case .color = self {
            return true
        }
        return false
    }
}

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
    var valuePresentation: ControlValuePresentation {
        let text = ControlValuePresentation.text(presentedValue)
        if descriptor.kind.lowercased().hasPrefix("color-v1:") {
            if aggregateState == .mixed {
                if let aggregateValues,
                   let aggregate = HomeBaseColorAggregatePresentation(
                    wireValues: aggregateValues,
                    aggregateValueCount: aggregateValueCount
                   ) {
                    return .color(.aggregate(aggregate))
                }
                return .color(.mixed)
            }
            if aggregateState == .unavailable {
                return .color(.unavailable)
            }
            if aggregateState != .unavailable,
               let value = pendingValue ?? value,
               let color = HomeBaseColorPresentation(wireValue: value) {
                return .color(.selected(color))
            }
        }

        guard details?.metadata["readable"]?.boolValue == true,
              details?.metadata["writable"]?.boolValue == true,
              details?.metadata["structured"]?.boolValue == false,
              aggregateState != .mixed,
              aggregateState != .unavailable,
              let numericValue = (pendingValue ?? value)?.numberValue else {
            return text
        }

        switch descriptor.kind.lowercased() {
        case "binaryswitch":
            return .toggle(numericValue > 0)

        case "unitinterval":
            guard let minimum = details?.metadata["minimum"]?.numberValue,
                  let maximum = details?.metadata["maximum"]?.numberValue,
                  minimum < maximum else {
                return text
            }
            let range = minimum ... maximum
            return .slider(
                value: numericValue.clamped(to: range),
                range: range
            )

        default:
            return text
        }
    }
}

struct ControlValueView: View {
    let control: LiveDeviceControl
    let interactionEnabled: Bool
    let setValue: (Double) async -> Void
    let setColorValue: (HBJSONValue) async throws -> Void
    let colorValues: () -> AsyncThrowingStream<
        HomeBaseColorPickerObservation,
        Error
    >

    @State private var isShowingColorPicker = false

    var body: some View {
        HStack(spacing: 8) {
            switch control.valuePresentation {
            case .toggle(let isOn):
                Toggle(
                    "",
                    isOn: Binding(
                        get: { isOn },
                        set: { requestedValue in
                            Task {
                                await submit(
                                    requestedValue ? 1 : 0,
                                    stage: "toggle-ui"
                                )
                            }
                        }
                    )
                )
                .labelsHidden()
                .disabled(!interactionEnabled || control.isUpdating)
                .accessibilityLabel(control.displayName)
                .accessibilityValue(control.presentedValue)

            case .slider(let value, let range):
                ControlSlider(
                    value: value,
                    range: range,
                    interactionEnabled:
                        interactionEnabled && !control.isUpdating,
                    controlPath: control.descriptor.control,
                    accessibilityLabel: control.displayName,
                    setValue: { value in
                        await submit(value, stage: "slider-presentation")
                    }
                )

            case .color(let presentation):
                if let capabilities = HomeBaseColorPickerCapabilities(
                    controlKind: control.descriptor.kind
                ),
                control.details?.metadata["writable"]?.boolValue == true {
                    Button {
                        isShowingColorPicker = true
                    } label: {
                        colorReadout(presentation)
                    }
                    .buttonStyle(.plain)
                    .disabled(!interactionEnabled || control.isUpdating)
                    .accessibilityHint("Opens the color picker")
                    .navigationDestination(
                        isPresented: $isShowingColorPicker
                    ) {
                        HomeBaseColorPickerView(
                            capabilities: capabilities,
                            initialValue: control.aggregateState == .mixed
                                ? nil
                                : control.pendingValue ?? control.value,
                            aggregateState: control.aggregateState,
                            aggregateValues: control.aggregateValues,
                            aggregateValueCount: control.aggregateValueCount,
                            liveValues: colorValues,
                            setValue: setColorValue
                        )
                        .navigationTitle(control.displayName)
#if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
#endif
                    }
                } else {
                    colorReadout(presentation)
                }

            case .text(let value):
                Text(value)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
            }

            if control.isUpdating {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func colorReadout(
        _ presentation: HomeBaseColorReadoutPresentation
    ) -> some View {
        HomeBaseColorReadout(
            presentation: presentation,
            accessibilityValue: control.presentedValue,
            isStale: control.valid == false
        )
    }

    private func submit(
        _ value: Double,
        stage: String
    ) async {
        ControlWriteDiagnostics.logNumeric(
            stage: stage,
            control: control.descriptor.control,
            value: value
        )
        await setValue(value)
    }
}

private struct ControlSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let interactionEnabled: Bool
    let controlPath: String
    let accessibilityLabel: String
    let setValue: (Double) async -> Void

    @State private var draftValue: Double
    @State private var isEditing = false

    init(
        value: Double,
        range: ClosedRange<Double>,
        interactionEnabled: Bool,
        controlPath: String,
        accessibilityLabel: String,
        setValue: @escaping (Double) async -> Void
    ) {
        self.value = value
        self.range = range
        self.interactionEnabled = interactionEnabled
        self.controlPath = controlPath
        self.accessibilityLabel = accessibilityLabel
        self.setValue = setValue
        _draftValue = State(initialValue: value.clamped(to: range))
    }

    var body: some View {
        Slider(
            value: $draftValue,
            in: range,
            onEditingChanged: { editing in
                if editing {
                    isEditing = true
                    return
                }

                isEditing = false
                let requestedValue = draftValue.clamped(to: range)
                guard interactionEnabled,
                      requestedValue != value else {
                    return
                }
                Task {
                    ControlWriteDiagnostics.logNumeric(
                        stage: "slider-ui",
                        control: controlPath,
                        value: requestedValue
                    )
                    await setValue(requestedValue)
                }
            }
        )
        .frame(minWidth: 120, idealWidth: 160, maxWidth: 200)
        .disabled(!interactionEnabled)
        .accessibilityLabel(accessibilityLabel)
        .onChange(of: value) { _, updatedValue in
            guard !isEditing else { return }
            draftValue = updatedValue.clamped(to: range)
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
