//
//  TriggerConditionEditorView.swift
//  HomeBase-GUI
//

import Foundation
import HomeBaseProtocol
import SwiftUI

/// A local, transactional editor for one complete condition tree. Nested
/// editors only update this value; the trigger draft is touched once when the
/// user explicitly commits the root editor.
struct TriggerConditionEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let repository: TriggerConfigurationRepository
    let actionLabel: String
    let onCommit: (HBJSONValue) throws -> Void

    @State private var rawValue: HBJSONValue
    @State private var submissionError: String?

    init(
        title: String,
        initialValue: HBJSONValue,
        repository: TriggerConfigurationRepository,
        actionLabel: String,
        onCommit: @escaping (HBJSONValue) throws -> Void
    ) {
        self.title = title
        self.repository = repository
        self.actionLabel = actionLabel
        self.onCommit = onCommit
        _rawValue = State(initialValue: initialValue)
    }

    var body: some View {
        Form {
            let pluginContext = TriggerConditionPluginContext(
                rawValue: rawValue
            )
            TriggerConditionTypeRegistry.standard.resolve(pluginContext)
                .module.makeEditorRows(
                    context: TriggerConditionEditingContext(
                        rawValue: $rawValue,
                        repository: repository
                    )
                )

            Section("Advanced") {
                NavigationLink {
                    TriggerConditionJSONEditor(
                        title: "Condition JSON",
                        initialValue: rawValue,
                        actionLabel: "Apply"
                    ) { rawValue = $0 }
                } label: {
                    Label("Edit Raw JSON", systemImage: "curlybraces")
                }

                Text(
                    "Raw editing is available for every condition. Unsupported fields and nested values remain unchanged unless you edit their JSON."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let validationMessage {
                Section {
                    Label(
                        validationMessage,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }

            if let submissionError {
                Section {
                    Label(
                        submissionError,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(title)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: submit) {
                    Label(actionLabel, systemImage: "checkmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.glassProminent)
                .disabled(validationMessage != nil)
            }
        }
        .onChange(of: rawValue) {
            submissionError = nil
        }
    }

    private var validationMessage: String? {
        TriggerConditionTypeRegistry.standard.validationMessage(for: rawValue)
    }

    private func submit() {
        guard validationMessage == nil else { return }
        do {
            try onCommit(rawValue)
            dismiss()
        } catch {
            submissionError = error.localizedDescription
        }
    }
}

struct TriggerCompareConditionEditorRows: View {
    @Binding var rawValue: HBJSONValue
    let repository: TriggerConfigurationRepository

    @State private var isShowingControlPicker = false
    @State private var resolvedDevice: HBDeviceDescriptor?
    @State private var resolvedControl: HBControlDescriptor?
    @State private var resolutionMessage: String?
    @State private var equalityOperator: String

    init(
        rawValue: Binding<HBJSONValue>,
        repository: TriggerConfigurationRepository
    ) {
        _rawValue = rawValue
        self.repository = repository
        let operation = TriggerCompareCondition(rawValue.wrappedValue)?
            .comparisonOperator
        _equalityOperator = State(initialValue: operation == "=" ? "=" : "==")
    }

    private var comparison: TriggerCompareCondition? {
        TriggerCompareCondition(rawValue)
    }

    var body: some View {
        if let comparison {
            Section("Control") {
                Button {
                    isShowingControlPicker = true
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Control")
                            .foregroundStyle(.primary)
                        Spacer()
                        controlLabel(comparison)
                    }
                }

                if let resolutionMessage,
                   !comparison.device.isEmpty,
                   !comparison.control.isEmpty {
                    Text(resolutionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if comparison.usesExplicitProjection {
                    LabeledContent(
                        "Compared state",
                        value: comparison.projection == .observed
                            ? "Device-reported"
                            : "HomeBase target"
                    )
                }
            }

            Section("Condition") {
                Picker(
                    "Relationship",
                    selection: Binding(
                        get: { comparison.relationship },
                        set: { relationship in
                            replace(
                                comparison.replacingRelationship(
                                    relationship,
                                    preservingEqualityAlias: equalityOperator
                                )
                            )
                        }
                    )
                ) {
                    ForEach(TriggerCompareCondition.Relationship.allCases) {
                        relationship in
                        Text(relationship.title).tag(relationship)
                    }
                }

                TriggerCompareLiteralEditor(
                    value: Binding(
                        get: { comparison.literal },
                        set: { value in
                            replace(comparison.replacingLiteral(value))
                        }
                    ),
                    control: resolvedControl,
                    controlPath: comparison.device.isEmpty
                        ? "Comparison value"
                        : "\(comparison.device):\(comparison.control)"
                )
            }
            .sheet(isPresented: $isShowingControlPicker) {
                TriggerConditionControlPicker(
                    repository: repository
                ) { device, control in
                    replace(
                        comparison.replacingTarget(
                            device: device.addressableName,
                            control: control.identifier
                        )
                    )
                    resolvedDevice = device
                    resolvedControl = control
                    resolutionMessage = nil
                }
            }
            .task(id: targetTaskID(comparison)) {
                await resolve(comparison)
            }
        }
    }

    @ViewBuilder
    private func controlLabel(
        _ comparison: TriggerCompareCondition
    ) -> some View {
        if comparison.device.isEmpty || comparison.control.isEmpty {
            Text("Choose…")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                Text(
                    resolvedControl?.name
                        ?? humanizedConditionIdentifier(comparison.control)
                )
                .foregroundStyle(.primary)
                Text(
                    resolvedDevice?.displayName
                        ?? humanizedConditionIdentifier(comparison.device)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.trailing)
        }
    }

    private func targetTaskID(_ comparison: TriggerCompareCondition) -> String {
        "\(comparison.device)\u{0}\(comparison.control)"
    }

    private func replace(_ comparison: TriggerCompareCondition) {
        rawValue = comparison.rawValue
    }

    @MainActor
    private func resolve(_ comparison: TriggerCompareCondition) async {
        resolvedDevice = nil
        resolvedControl = nil
        resolutionMessage = nil
        guard !comparison.device.isEmpty, !comparison.control.isEmpty else {
            return
        }
        do {
            let device = try await repository.deviceDetails(
                named: comparison.device
            )
            guard !Task.isCancelled else { return }
            guard let control = device.controls.first(where: {
                $0.identifier.caseInsensitiveCompare(comparison.control)
                    == .orderedSame
            }) else {
                resolutionMessage =
                    "HomeBase did not report this control in the device schema. Use raw JSON to preserve or edit its value."
                return
            }
            let schema = ControlValueSchema(
                kind: control.kind,
                metadata: control.metadata,
                tags: control.tags
            )
            guard schema.isReadable, !schema.isStructured else {
                resolutionMessage =
                    "This control is not a readable scalar, so Compare cannot use it."
                return
            }
            resolvedDevice = device
            resolvedControl = control
        } catch is CancellationError {
            return
        } catch {
            resolutionMessage =
                "Control metadata could not be loaded: \(error.localizedDescription)"
        }
    }
}

private struct TriggerCompareLiteralEditor: View {
    @Binding var value: HBJSONValue
    let control: HBControlDescriptor?
    let controlPath: String

    var body: some View {
        if control != nil, let typedEditor {
            HStack(alignment: .center, spacing: 12) {
                Text("Value")
                Spacer(minLength: 12)
                typedEditor
            }
        } else {
            LabeledContent("Value") {
                Text(value.presentationText)
            }
        }

    }

    @MainActor
    private var typedEditor: AnyView? {
        guard let control else { return nil }
        let schema = editableSchema(control)
        let context = ControlValuePresentationContext(
            schema: schema,
            snapshot: ControlValueSnapshot(
                value: value,
                displayText: value.presentationText
                    + (control.metadata["unitSuffix"]?.stringValue ?? "")
            ),
            interaction: ControlValueInteraction(
                isEnabled: true,
                isUpdating: false,
                commit: { requested, _ in
                    await MainActor.run {
                        if case .number(let number) = requested {
                            value = triggerConditionJSONNumber(number)
                        } else {
                            value = requested
                        }
                    }
                },
                observations: {
                    AsyncThrowingStream { continuation in
                        continuation.finish()
                    }
                }
            ),
            accessibilityLabel: "Comparison value",
            controlPath: controlPath
        )
        let plugin = ControlValueTypeRegistry.standard.resolve(schema).plugin
        guard plugin.supportsEditing(context: context) else { return nil }
        return plugin.makeBody(context: context)
    }

    private func editableSchema(
        _ control: HBControlDescriptor
    ) -> ControlValueSchema {
        var metadata = control.metadata
        // This is an in-memory literal, not a write to the source control.
        // Supplying editable capabilities lets the same type plugin render it.
        metadata["readable"] = .bool(true)
        metadata["writable"] = .bool(true)
        return ControlValueSchema(
            kind: control.kind,
            metadata: metadata,
            tags: control.tags
        )
    }
}

struct TriggerCompositeConditionEditorRows: View {
    @Binding var rawValue: HBJSONValue
    let repository: TriggerConfigurationRepository

    private var composite: TriggerCompositeCondition? {
        TriggerCompositeCondition(rawValue)
    }

    var body: some View {
        if let composite {
            Section {
                LabeledContent("Logic", value: composite.kind.title)
                Text(logicExplanation(composite.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Conditions") {
                if composite.children.isEmpty {
                    Text("No conditions")
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(composite.children.enumerated()), id: \.offset) {
                    index, child in
                    HStack(spacing: 10) {
                        NavigationLink {
                            TriggerConditionEditorView(
                                title: childTitle(child, index: index),
                                initialValue: child,
                                repository: repository,
                                actionLabel: "Done"
                            ) { updatedChild in
                                replaceChild(at: index, with: updatedChild)
                            }
                        } label: {
                            TriggerNestedConditionLabel(rawValue: child)
                        }

                        if composite.kind != .trueWhenInvalid {
                            Button(role: .destructive) {
                                rawValue = composite
                                    .removingChild(at: index)
                                    .rawValue
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(
                                "Remove condition \(index + 1)"
                            )
                        }
                    }
                }

                if composite.kind != .trueWhenInvalid {
                    Menu {
                        ForEach(
                            TriggerConditionTypeRegistry.standard
                                .creationOptions
                        ) { option in
                            Button {
                                rawValue = composite.appendingChild(
                                    option.initialValue
                                ).rawValue
                            } label: {
                                Label(
                                    option.title,
                                    systemImage: option.systemImage
                                )
                            }
                        }
                    } label: {
                        Label("New Condition", systemImage: "plus")
                    }
                }
            }
        }
    }

    private func replaceChild(at index: Int, with value: HBJSONValue) {
        guard let latest = TriggerCompositeCondition(rawValue) else { return }
        rawValue = latest.replacingChild(at: index, with: value).rawValue
    }

    private func childTitle(_ value: HBJSONValue, index: Int) -> String {
        let presentation = TriggerConditionTypeRegistry.standard
            .presentation(for: value)
        return presentation.title.isEmpty
            ? "Condition \(index + 1)"
            : presentation.title
    }

    private func logicExplanation(
        _ kind: TriggerCompositeCondition.Kind
    ) -> String {
        switch kind {
        case .and:
            "Every condition below must match."
        case .or:
            "At least one condition below must match."
        case .xor:
            "Exactly one condition below must match."
        case .trueWhenInvalid:
            "If the value becomes unavailable, keep treating this condition as matched."
        }
    }
}

private struct TriggerNestedConditionLabel: View {
    let rawValue: HBJSONValue

    var body: some View {
        let presentation = TriggerConditionTypeRegistry.standard
            .presentation(for: rawValue)
        VStack(alignment: .leading, spacing: 3) {
            Text(presentation.title)
            if let detail = presentation.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

struct TriggerRawConditionEditorRows: View {
    @Binding var rawValue: HBJSONValue

    var body: some View {
        let presentation = TriggerConditionTypeRegistry.standard
            .presentation(for: rawValue)
        Section("Condition") {
            LabeledContent("Type", value: presentation.title)
            SceneConfigurationValueRow(
                label: "Configuration",
                value: TriggerConditionPluginContext(rawValue: rawValue)
                    .payload ?? rawValue
            )
            Text(
                "No structured editor is registered for this condition shape. Its JSON is preserved exactly."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct TriggerConditionControlPicker: View {
    private enum LoadState {
        case loading
        case loaded([HBDeviceDescriptor])
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss

    let repository: TriggerConfigurationRepository
    let onSelect: (HBDeviceDescriptor, HBControlDescriptor) -> Void

    @State private var state: LoadState = .loading

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    ProgressView("Loading controls…")
                case .failed(let message):
                    ContentUnavailableView {
                        Label(
                            "Controls Could Not Be Loaded",
                            systemImage: "exclamationmark.triangle"
                        )
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                case .loaded(let devices):
                    controlList(devices)
                }
            }
            .navigationTitle("Choose Control")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                }
            }
        }
        .task { await load() }
    }

    private func controlList(_ devices: [HBDeviceDescriptor]) -> some View {
        List {
            ForEach(devices, id: \.identifier) { device in
                let controls = supportedControls(device)
                if !controls.isEmpty {
                    Section(device.displayName) {
                        ForEach(controls, id: \.identifier) { control in
                            Button {
                                onSelect(device, control)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(control.name)
                                            .foregroundStyle(.primary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func supportedControls(
        _ device: HBDeviceDescriptor
    ) -> [HBControlDescriptor] {
        device.controls.filter { control in
            let schema = ControlValueSchema(
                kind: control.kind,
                metadata: control.metadata,
                tags: control.tags
            )
            return schema.isReadable && !schema.isStructured
        }.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame
                ? $0.identifier < $1.identifier
                : order == .orderedAscending
        }
    }

    @MainActor
    private func load() async {
        state = .loading
        do {
            let catalog = try await repository.editableDeviceCatalog()
            try Task.checkCancellation()
            let devices = catalog.devices
                .filter { !supportedControls($0).isEmpty }
                .sorted {
                    let order = $0.displayName.localizedCaseInsensitiveCompare(
                        $1.displayName
                    )
                    return order == .orderedSame
                        ? $0.addressableName < $1.addressableName
                        : order == .orderedAscending
                }
            state = .loaded(devices)
        } catch is CancellationError {
            return
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
