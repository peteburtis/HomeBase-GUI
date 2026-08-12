//
//  ControlValueTypePlugins.swift
//  HomeBase-GUI
//

import Foundation
import HomeBaseProtocol
import SwiftUI

extension ControlValueTypeRegistry {
    static let standard = ControlValueTypeRegistry(
        plugins: [
            AnyControlValueTypePlugin(
                standaloneEditing: ColorControlValuePlugin()
            ),
            AnyControlValueTypePlugin(BinarySwitchControlValuePlugin()),
            AnyControlValueTypePlugin(UnitIntervalControlValuePlugin()),
        ],
        fallback: AnyControlValueTypePlugin(FallbackControlValuePlugin())
    )
}

private struct FallbackControlValuePlugin: ControlValueTypePlugin {
    let identifier = "fallback"

    func matchScore(for schema: ControlValueSchema) -> Int? {
        nil
    }

    func presentsStaleness(
        for snapshot: ControlValueSnapshot
    ) -> Bool {
        false
    }

    func makeBody(context: ControlValuePresentationContext) -> some View {
        ControlValueTextReadout(context.snapshot.displayText)
    }
}

private struct BinarySwitchControlValuePlugin: ControlValueTypePlugin {
    let identifier = "binary-switch"

    func matchScore(for schema: ControlValueSchema) -> Int? {
        schema.normalizedKind == "binaryswitch"
            ? ControlValueTypeMatchSpecificity.exactSchema
            : nil
    }

    func presentsStaleness(
        for snapshot: ControlValueSnapshot
    ) -> Bool {
        false
    }

    func supportsEditing(
        context: ControlValuePresentationContext
    ) -> Bool {
        BinarySwitchControlValueBody.editableValue(for: context) != nil
    }

    func makeBody(context: ControlValuePresentationContext) -> some View {
        BinarySwitchControlValueBody(context: context)
    }
}

private struct BinarySwitchControlValueBody: View {
    let context: ControlValuePresentationContext

    var body: some View {
        if let isOn = editableValue {
            Toggle(
                "",
                isOn: Binding(
                    get: { isOn },
                    set: { requestedValue in
                        Task {
                            try? await context.interaction.commit(
                                .integer(requestedValue ? 1 : 0),
                                .inline
                            )
                        }
                    }
                )
            )
            .labelsHidden()
            .disabled(
                !context.interaction.isEnabled
                    || context.interaction.isUpdating
            )
            .accessibilityLabel(context.accessibilityLabel)
            .accessibilityValue(context.snapshot.displayText)
        } else {
            ControlValueTextReadout(context.snapshot.displayText)
        }
    }

    private var editableValue: Bool? {
        Self.editableValue(for: context)
    }

    fileprivate static func editableValue(
        for context: ControlValuePresentationContext
    ) -> Bool? {
        guard context.schema.isReadable,
              context.schema.isWritable,
              !context.schema.isStructured,
              context.snapshot.aggregateState != .mixed,
              context.snapshot.aggregateState != .unavailable,
              let value = context.snapshot.value?.numberValue else {
            return nil
        }
        return value > 0
    }
}

private struct UnitIntervalControlValuePlugin: ControlValueTypePlugin {
    let identifier = "unit-interval"

    func matchScore(for schema: ControlValueSchema) -> Int? {
        schema.normalizedKind == "unitinterval"
            ? ControlValueTypeMatchSpecificity.exactSchema
            : nil
    }

    func presentsStaleness(
        for snapshot: ControlValueSnapshot
    ) -> Bool {
        false
    }

    func supportsEditing(
        context: ControlValuePresentationContext
    ) -> Bool {
        UnitIntervalControlValueBody.editor(for: context) != nil
    }

    func makeBody(context: ControlValuePresentationContext) -> some View {
        UnitIntervalControlValueBody(context: context)
    }
}

private struct UnitIntervalControlValueBody: View {
    let context: ControlValuePresentationContext

    var body: some View {
        if let editor {
            ControlSlider(
                value: editor.value,
                range: editor.range,
                interactionEnabled:
                    context.interaction.isEnabled
                        && !context.interaction.isUpdating,
                controlPath: context.controlPath,
                accessibilityLabel: context.accessibilityLabel,
                setValue: { value in
                    try? await context.interaction.commit(
                        .number(value),
                        .inline
                    )
                }
            )
        } else {
            ControlValueTextReadout(context.snapshot.displayText)
        }
    }

    private var editor: (value: Double, range: ClosedRange<Double>)? {
        Self.editor(for: context)
    }

    fileprivate static func editor(
        for context: ControlValuePresentationContext
    ) -> (value: Double, range: ClosedRange<Double>)? {
        guard context.schema.isReadable,
              context.schema.isWritable,
              !context.schema.isStructured,
              context.snapshot.aggregateState != .mixed,
              context.snapshot.aggregateState != .unavailable,
              let value = context.snapshot.value?.numberValue,
              let range = context.schema.scalarRange else {
            return nil
        }
        return (value.clamped(to: range), range)
    }
}

private struct ColorControlValuePlugin: ControlValueStandaloneEditingPlugin {
    let identifier = "color-v1"

    func matchScore(for schema: ControlValueSchema) -> Int? {
        HomeBaseColorPickerCapabilities(controlKind: schema.kind) == nil
            ? nil
            : ControlValueTypeMatchSpecificity.schemaFamily
    }

    func presentsStaleness(
        for snapshot: ControlValueSnapshot
    ) -> Bool {
        readoutPresentation(for: snapshot) != nil
    }

    func supportsEditing(
        context: ControlValuePresentationContext
    ) -> Bool {
        context.schema.isWritable
            && HomeBaseColorPickerCapabilities(
                controlKind: context.schema.kind
            ) != nil
            && readoutPresentation(for: context.snapshot) != nil
    }

    func makeBody(context: ControlValuePresentationContext) -> some View {
        ColorControlValueBody(context: context)
    }

    func supportsStandaloneEditing(
        context: ControlValuePresentationContext
    ) -> Bool {
        context.schema.isWritable
            && HomeBaseColorPickerCapabilities(
                controlKind: context.schema.kind
            ) != nil
    }

    func makeStandaloneEditor(
        context: ControlValuePresentationContext
    ) -> some View {
        ColorControlValueStandaloneEditor(context: context)
    }

    fileprivate func readoutPresentation(
        for snapshot: ControlValueSnapshot
    ) -> HomeBaseColorReadoutPresentation? {
        if snapshot.aggregateState == .mixed {
            if let aggregateValues = snapshot.aggregateValues,
               let aggregate = HomeBaseColorAggregatePresentation(
                wireValues: aggregateValues,
                aggregateValueCount: snapshot.aggregateValueCount
               ) {
                return .aggregate(aggregate)
            }
            return .mixed
        }
        if snapshot.aggregateState == .unavailable {
            return .unavailable
        }
        guard let value = snapshot.value,
              let color = HomeBaseColorPresentation(wireValue: value) else {
            return nil
        }
        return .selected(color)
    }
}

private struct ColorControlValueBody: View {
    let context: ControlValuePresentationContext

    @State private var isShowingColorPicker = false

    var body: some View {
        if let presentation = readoutPresentation,
           capabilities != nil,
           context.schema.isWritable {
            Button {
                isShowingColorPicker = true
            } label: {
                colorReadout(presentation)
            }
            .buttonStyle(.plain)
            .disabled(
                !context.interaction.isEnabled
                    || context.interaction.isUpdating
            )
            .accessibilityHint("Opens the color picker")
            .navigationDestination(isPresented: $isShowingColorPicker) {
                ColorControlValueStandaloneEditor(context: context)
                .navigationTitle(context.accessibilityLabel)
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
            }
        } else if let presentation = readoutPresentation {
            colorReadout(presentation)
        } else {
            ControlValueTextReadout(context.snapshot.displayText)
        }
    }

    private var capabilities: HomeBaseColorPickerCapabilities? {
        HomeBaseColorPickerCapabilities(controlKind: context.schema.kind)
    }

    private var readoutPresentation: HomeBaseColorReadoutPresentation? {
        ColorControlValuePlugin().readoutPresentation(
            for: context.snapshot
        )
    }

    private func colorReadout(
        _ presentation: HomeBaseColorReadoutPresentation
    ) -> some View {
        HomeBaseColorReadout(
            presentation: presentation,
            accessibilityValue: context.snapshot.displayText,
            isStale: context.snapshot.isStale
        )
    }
}

private struct ColorControlValueStandaloneEditor: View {
    private enum UpdateError: LocalizedError {
        case unsupportedValue

        var errorDescription: String? {
            "This color value is not supported by the control."
        }
    }

    let context: ControlValuePresentationContext

    var body: some View {
        if let capabilities {
            HomeBaseColorPickerView(
                capabilities: capabilities,
                initialValue: context.snapshot.aggregateState == .mixed
                    ? nil
                    : context.snapshot.value,
                aggregateState: context.snapshot.aggregateState,
                aggregateValues: context.snapshot.aggregateValues,
                aggregateValueCount: context.snapshot.aggregateValueCount,
                liveValues: context.interaction.observations,
                setValue: submit
            )
        } else {
            ContentUnavailableView(
                "Color Editor Unavailable",
                systemImage: "paintpalette"
            )
        }
    }

    private var capabilities: HomeBaseColorPickerCapabilities? {
        HomeBaseColorPickerCapabilities(controlKind: context.schema.kind)
    }

    private func submit(_ value: HBJSONValue) async throws {
        guard capabilities?.accepts(value) == true else {
            throw UpdateError.unsupportedValue
        }
        try await context.interaction.commit(value, .editor)
    }
}

private struct ControlValueTextReadout: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        Text(value)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
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

private extension HomeBaseColorPickerCapabilities {
    func accepts(_ value: HBJSONValue) -> Bool {
        guard value.objectValue?.count == 1,
              let key = value.objectValue?.keys.first?.lowercased() else {
            return false
        }
        return (key == "xy" && supportsXY)
            || (key == "rgb" && supportsRGB)
            || (key == "white" && supportsWhite)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
