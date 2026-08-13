//
//  AutomationActionTypePlugins.swift
//  HomeBase-GUI
//

import Foundation
import HomeBaseProtocol
import SwiftUI

extension AutomationActionTypeRegistry {
    /// The action UI manifest. Every engine action with a human presentation
    /// appears here by its exact wire type. `full` entries also have dedicated
    /// editing and creation UI; `presentation` entries deliberately retain the
    /// generic lossless JSON editor and do not appear in New Action.
    @MainActor
    static let standard = AutomationActionTypeRegistry(
        plugins: [
            .full(ControlSetActionPlugin()),
            .presentation(BuiltInActionPresentationPlugin(.controlToggle)),
            .presentation(BuiltInActionPresentationPlugin(.controlHold)),
            .presentation(BuiltInActionPresentationPlugin(.controlRelease)),
            .full(WaitActionPlugin()),
            .full(SceneApplyActionPlugin()),
            .full(SceneActivateActionPlugin()),
            .presentation(BuiltInActionPresentationPlugin(.sceneClear)),
            .presentation(BuiltInActionPresentationPlugin(.sceneClearAll)),
            .presentation(BuiltInActionPresentationPlugin(.sceneToggle)),
            .presentation(BuiltInActionPresentationPlugin(.sceneSetBetween)),
            .presentation(BuiltInActionPresentationPlugin(.sequenceSet)),
            .presentation(BuiltInActionPresentationPlugin(.triggerReassert)),
        ],
        fallback: .full(RawJSONActionPlugin())
    )
}

struct AutomationWaitActionConfiguration: Equatable, Sendable {
    let actionIndex: Int
    let duration: Double

    init?(action: SceneActionConfiguration) {
        guard action.type == "Wait",
              let duration = action.payload?.numberValue,
              duration.isFinite,
              duration >= 0 else {
            return nil
        }
        actionIndex = action.index
        self.duration = duration
    }
}

struct AutomationSceneInvocationActionConfiguration: Equatable, Sendable {
    enum Representation: Equatable, Sendable {
        case identifier
        case object
    }

    enum Field: CaseIterable, Hashable, Sendable {
        case identifier
        case priority
        case timing
        case releaseTiming
    }

    let actionIndex: Int
    let actionType: String
    let representation: Representation
    let fields: [String: HBJSONValue]
    let identifier: String

    init?(action: SceneActionConfiguration, actionType: String) {
        guard action.type == actionType, let payload = action.payload else {
            return nil
        }
        self.actionType = actionType
        actionIndex = action.index

        if let identifier = payload.stringValue, !identifier.isEmpty {
            representation = .identifier
            fields = [:]
            self.identifier = identifier
            return
        }

        guard let fields = payload.objectValue,
              let identifier = fields["Identifier"]?.stringValue,
              !identifier.isEmpty,
              Self.isValidPriority(fields["Priority"]),
              Self.isValidTiming(fields["Timing"]),
              Self.isValidTiming(fields["ReleaseTiming"]) else {
            return nil
        }
        representation = .object
        self.fields = fields
        self.identifier = identifier
    }

    var priority: HBJSONValue? { fields["Priority"] }
    var timing: HBJSONValue? { fields["Timing"] }
    var releaseTiming: HBJSONValue? { fields["ReleaseTiming"] }

    var additionalFields: [(key: String, value: HBJSONValue)] {
        fields
            .filter {
                $0.key != "Identifier"
                    && $0.key != "Priority"
                    && $0.key != "Timing"
                    && $0.key != "ReleaseTiming"
            }
            .sorted { left, right in
                let order = left.key.localizedCaseInsensitiveCompare(right.key)
                if order != .orderedSame {
                    return order == .orderedAscending
                }
                return left.key < right.key
            }
    }

    func actionValue(
        identifier: String,
        priority: HBJSONValue?,
        timing: HBJSONValue?,
        releaseTiming: HBJSONValue?,
        supportsReleaseTiming: Bool,
        patching requestedFields: Set<Field>? = nil
    ) -> HBJSONValue {
        let patchedFields = requestedFields ?? Set(Field.allCases)
        var updatedFields = fields
        if patchedFields.contains(.identifier) {
            updatedFields["Identifier"] = .string(identifier)
        }
        if patchedFields.contains(.priority) {
            updatedFields["Priority"] = priority
        }
        if patchedFields.contains(.timing) {
            updatedFields["Timing"] = timing
        }
        if supportsReleaseTiming,
           patchedFields.contains(.releaseTiming) {
            updatedFields["ReleaseTiming"] = releaseTiming
        }

        if updatedFields["Identifier"] == nil {
            updatedFields["Identifier"] = .string(self.identifier)
        }
        if representation == .identifier,
           updatedFields.keys.allSatisfy({ $0 == "Identifier" }),
           let identifier = updatedFields["Identifier"]?.stringValue {
            return .object([actionType: .string(identifier)])
        }
        return .object([actionType: .object(updatedFields)])
    }

    private static func isValidPriority(_ value: HBJSONValue?) -> Bool {
        guard let value else { return true }
        guard let number = value.numberValue,
              number.isFinite,
              number.rounded(.towardZero) == number,
              number >= Double(Int32.min),
              number <= Double(Int32.max) else {
            return false
        }
        return true
    }

    private static func isValidTiming(_ value: HBJSONValue?) -> Bool {
        guard let value else { return true }
        guard let number = value.numberValue else { return false }
        return number.isFinite && number >= 0
    }
}

@MainActor
struct AutomationActionSectionHeader<Model: AutomationActionEditingModel>: View {
    let action: SceneActionConfiguration
    @ObservedObject var model: Model

    private var context: AutomationActionPresentationContext {
        AutomationActionPresentationContext(action: action, model: model)
    }

    private var resolution: AutomationActionTypeRegistry.Resolution {
        AutomationActionTypeRegistry.standard.resolve(action)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: resolution.plugin.systemImage)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Action \(action.index + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if resolution.plugin.canRemove(context: context) {
                Button(role: .destructive) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        resolution.plugin.remove(context: context)
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(!model.canMutateStructure)
                .accessibilityLabel("Remove \(title)")
            }
        }
        .textCase(nil)
    }

    private var title: String {
        resolution.plugin.presentation(for: action).title
    }
}

@MainActor
struct AutomationActionConfigurationRows<
    Model: AutomationActionEditingModel
>: View {
    let action: SceneActionConfiguration
    @ObservedObject var model: Model

    var body: some View {
        let context = AutomationActionPresentationContext(
            action: action,
            model: model
        )
        let plugin = AutomationActionTypeRegistry.standard.resolve(action)
            .plugin
        if let rows = plugin.makeRows(context: context) {
            rows
        } else {
            AutomationRawActionRows(context: context)
        }
    }
}

private struct ControlSetActionPlugin:
    AutomationActionEditingPlugin,
    AutomationActionCreationPlugin
{
    let identifier = "control-set"
    let actionType: String? = "ControlSet"
    let displayName = "Set Control"
    let systemImage = "slider.horizontal.3"
    let applicability: AutomationActionApplicability = .all

    func presentation(
        for action: SceneActionConfiguration
    ) -> AutomationActionPluginPresentation {
        BuiltInActionPresentationPlugin(.controlSet).presentation(for: action)
    }

    func supports(
        action: SceneActionConfiguration,
        in context: AutomationActionConfigurationContext
    ) -> Bool {
        guard applicability.supports(context) else { return false }
        guard context == .trigger(.trigger),
              let value = action.controlSet?.value else { return true }
        return value.objectValue?["Cycle"] == nil
    }

    func canRemove(context: AutomationActionPresentationContext) -> Bool {
        context.canMutateStructure
            && (context.action.controlSet != nil
                || context.supportsGenericActionMutation)
    }

    func remove(context: AutomationActionPresentationContext) {
        if context.action.controlSet != nil {
            context.removeControlSet(actionIndex: context.action.index)
        } else {
            context.removeAction()
        }
    }

    func makeRows(
        context: AutomationActionPresentationContext
    ) -> some View {
        Group {
            if let controlSet = context.action.controlSet {
                AutomationControlSetActionRows(
                    controlSet: controlSet,
                    context: context
                )
            } else {
                AutomationRawActionRows(context: context)
            }
        }
    }

    func makeCreationView(
        operations: AutomationActionCreationOperations
    ) -> some View {
        SceneControlPickerView(
            repository: operations.controlRepository,
            excludedControlPaths: operations.excludedControlPaths,
            configurationKind: operations.configurationKind
        ) { deviceAddressableName, control, valueSource in
            _ = try await operations.addControlSet(
                deviceAddressableName: deviceAddressableName,
                control: control,
                valueSource: valueSource
            )
        }
    }
}

private struct WaitActionPlugin:
    AutomationActionEditingPlugin,
    AutomationActionCreationPlugin
{
    let identifier = "wait"
    let actionType: String? = "Wait"
    let displayName = "Wait"
    let systemImage = "clock"
    let applicability: AutomationActionApplicability = .all

    func presentation(
        for action: SceneActionConfiguration
    ) -> AutomationActionPluginPresentation {
        BuiltInActionPresentationPlugin(.wait).presentation(for: action)
    }

    func canRemove(context: AutomationActionPresentationContext) -> Bool {
        context.canMutateStructure && context.supportsGenericActionMutation
    }

    func remove(context: AutomationActionPresentationContext) {
        context.removeAction()
    }

    func makeRows(
        context: AutomationActionPresentationContext
    ) -> some View {
        Group {
            if let wait = AutomationWaitActionConfiguration(
                action: context.action
            ) {
                AutomationWaitActionRows(wait: wait, context: context)
            } else {
                AutomationRawActionRows(context: context)
            }
        }
    }

    func makeCreationView(
        operations: AutomationActionCreationOperations
    ) -> some View {
        NavigationStack {
            AutomationWaitActionEditor(
                title: "New Wait",
                initialAction: nil,
                actionLabel: "Add"
            ) { value in
                _ = try await operations.appendAction(value)
            }
        }
    }
}

private struct SceneApplyActionPlugin:
    AutomationActionEditingPlugin,
    AutomationActionCreationPlugin
{
    let identifier = "scene-apply"
    let actionType: String? = "SceneApply"
    let displayName = "Apply Scene"
    let systemImage = "sparkles"
    let applicability: AutomationActionApplicability = .all

    func presentation(
        for action: SceneActionConfiguration
    ) -> AutomationActionPluginPresentation {
        BuiltInActionPresentationPlugin(.sceneApply).presentation(for: action)
    }

    func canRemove(context: AutomationActionPresentationContext) -> Bool {
        context.canMutateStructure && context.supportsGenericActionMutation
    }

    func remove(context: AutomationActionPresentationContext) {
        context.removeAction()
    }

    func makeRows(
        context: AutomationActionPresentationContext
    ) -> some View {
        AutomationSceneInvocationActionRows(
            actionType: "SceneApply",
            supportsReleaseTiming: false,
            context: context
        )
    }

    func makeCreationView(
        operations: AutomationActionCreationOperations
    ) -> some View {
        NavigationStack {
            AutomationSceneInvocationActionEditor(
                title: "Apply Scene",
                actionType: "SceneApply",
                supportsReleaseTiming: false,
                initialAction: nil,
                actionLabel: "Add"
            ) { value in
                _ = try await operations.appendAction(value)
            }
        }
    }
}

private struct SceneActivateActionPlugin:
    AutomationActionEditingPlugin,
    AutomationActionCreationPlugin
{
    let identifier = "scene-activate"
    let actionType: String? = "SceneActivate"
    let displayName = "Activate Scene"
    let systemImage = "sparkles.rectangle.stack"
    let applicability: AutomationActionApplicability = .overlayMode

    func presentation(
        for action: SceneActionConfiguration
    ) -> AutomationActionPluginPresentation {
        BuiltInActionPresentationPlugin(.sceneActivate)
            .presentation(for: action)
    }

    func canRemove(context: AutomationActionPresentationContext) -> Bool {
        context.canMutateStructure && context.supportsGenericActionMutation
    }

    func remove(context: AutomationActionPresentationContext) {
        context.removeAction()
    }

    func makeRows(
        context: AutomationActionPresentationContext
    ) -> some View {
        AutomationSceneInvocationActionRows(
            actionType: "SceneActivate",
            supportsReleaseTiming: true,
            context: context
        )
    }

    func makeCreationView(
        operations: AutomationActionCreationOperations
    ) -> some View {
        NavigationStack {
            AutomationSceneInvocationActionEditor(
                title: "Activate Scene",
                actionType: "SceneActivate",
                supportsReleaseTiming: true,
                initialAction: nil,
                actionLabel: "Add"
            ) { value in
                _ = try await operations.appendAction(value)
            }
        }
    }
}

private struct RawJSONActionPlugin:
    AutomationActionEditingPlugin,
    AutomationActionCreationPlugin
{
    let identifier = "raw-json"
    let actionType: String? = nil
    let displayName = "Raw JSON"
    let systemImage = "curlybraces"
    let applicability: AutomationActionApplicability = .all

    func presentation(
        for action: SceneActionConfiguration
    ) -> AutomationActionPluginPresentation {
        fallbackActionPresentation(
            action,
            title: action.type.map(humanizedAutomationIdentifier)
                ?? "Unrecognized Action"
        )
    }

    func canRemove(context: AutomationActionPresentationContext) -> Bool {
        context.canMutateStructure && context.supportsGenericActionMutation
    }

    func remove(context: AutomationActionPresentationContext) {
        context.removeAction()
    }

    func makeRows(
        context: AutomationActionPresentationContext
    ) -> some View {
        AutomationRawActionRows(context: context)
    }

    func makeCreationView(
        operations: AutomationActionCreationOperations
    ) -> some View {
        NavigationStack {
            AutomationActionJSONEditor(
                title: "New Action",
                initialValue: .object(["": .null]),
                actionLabel: "Add"
            ) { value in
                _ = try await operations.appendAction(value)
            }
        }
    }
}

private struct AutomationControlSetActionRows: View {
    let controlSet: SceneControlSetConfiguration
    let context: AutomationActionPresentationContext

    var body: some View {
        SceneConfigurationTextRow(label: "Device", value: controlSet.device)
        SceneConfigurationTextRow(label: "Control", value: controlSet.control)
        AutomationControlSetValueRow(
            controlSet: controlSet,
            context: context
        )

        ForEach(
            Array(controlSet.trailingValues.enumerated()),
            id: \.offset
        ) { offset, value in
            SceneConfigurationValueRow(
                label: controlSetTrailingLabel(
                    value: value,
                    absoluteIndex: offset + 3
                ),
                value: value
            )
        }
    }

    private func controlSetTrailingLabel(
        value: HBJSONValue,
        absoluteIndex: Int
    ) -> String {
        if value.objectValue != nil { return "Options" }
        if absoluteIndex == 3 { return "Priority" }
        return "Element \(absoluteIndex + 1)"
    }
}

private struct AutomationControlSetValueRow: View {
    let controlSet: SceneControlSetConfiguration
    let context: AutomationActionPresentationContext

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Value")
                .font(.caption)
                .foregroundStyle(.secondary)

            switch context.controlResolution(for: controlSet.actionIndex) {
            case .resolving:
                HStack(spacing: 10) {
                    rawValue
                    Spacer(minLength: 8)
                    ProgressView().controlSize(.small)
                }

            case .unavailable(let message):
                rawValue
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .resolved(let target):
                resolvedValue(target)
            }

            if let error = context.actionError(for: controlSet.actionIndex) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func resolvedValue(_ target: SceneResolvedControl) -> some View {
        let presentation = target.presentationContext(
            value: controlSet.value,
            isEnabled: !context.isBusy
                && !context.isLoadingCurrentValue(
                    actionIndex: controlSet.actionIndex
                ),
            commit: { value, _ in
                try await context.setControlValue(
                    actionIndex: controlSet.actionIndex,
                    value: value
                )
            }
        )
        let plugin = ControlValueTypeRegistry.standard
            .resolve(presentation.schema)
            .plugin

        if plugin.supportsEditing(context: presentation) {
            HStack(spacing: 12) {
                ControlValuePluginView(context: presentation)
                Spacer(minLength: 4)
                Button {
                    Task {
                        await context.useCurrentValue(
                            actionIndex: controlSet.actionIndex
                        )
                    }
                } label: {
                    if context.isLoadingCurrentValue(
                        actionIndex: controlSet.actionIndex
                    ) {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Current", systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(context.isBusy)
                .accessibilityLabel("Use Current Value")
            }
        } else {
            rawValue
            NavigationLink {
                SceneRawControlValueEditor(
                    control: target.descriptor,
                    initialValue: controlSet.value,
                    actionLabel: "Done"
                ) { value in
                    try await context.setControlValue(
                        actionIndex: controlSet.actionIndex,
                        value: value
                    )
                }
            } label: {
                Label("Edit JSON", systemImage: "curlybraces")
            }
            .disabled(context.isBusy)

            Text("This control does not have a dedicated editor.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var rawValue: some View {
        Text(controlSet.value.prettyConfigurationJSON)
            .font(.body.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AutomationWaitActionRows: View {
    let wait: AutomationWaitActionConfiguration
    let context: AutomationActionPresentationContext

    var body: some View {
        LabeledContent("Duration") {
            Text("\(wait.duration.formatted()) s")
        }

        if context.supportsGenericActionMutation {
            NavigationLink {
                AutomationWaitActionEditor(
                    title: "Wait",
                    initialAction: context.action,
                    actionLabel: "Done"
                ) { value in
                    try await context.setAction(rawValue: value)
                }
            } label: {
                Label("Edit Wait", systemImage: "clock")
            }
            .disabled(context.isBusy)
        }
    }
}

private struct AutomationSceneInvocationActionRows: View {
    let actionType: String
    let supportsReleaseTiming: Bool
    let context: AutomationActionPresentationContext

    var body: some View {
        if let invocation = AutomationSceneInvocationActionConfiguration(
            action: context.action,
            actionType: actionType
        ), supportsReleaseTiming || invocation.releaseTiming == nil {
            SceneConfigurationTextRow(
                label: "Scene",
                value: invocation.identifier
            )
            SceneConfigurationTextRow(
                label: "Priority override",
                value: invocation.priority?.compactConfigurationJSON
                    ?? "Inherited"
            )
            SceneConfigurationTextRow(
                label: "Transition override",
                value: invocation.timing.map {
                    "\($0.compactConfigurationJSON) seconds"
                } ?? "Inherited"
            )
            if supportsReleaseTiming {
                SceneConfigurationTextRow(
                    label: "Return transition",
                    value: invocation.releaseTiming.map {
                        "\($0.compactConfigurationJSON) seconds"
                    } ?? "Normal return"
                )
            }
            ForEach(invocation.additionalFields, id: \.key) { field in
                SceneConfigurationValueRow(
                    label: field.key,
                    value: field.value
                )
            }

            if context.supportsGenericActionMutation {
                NavigationLink {
                    AutomationSceneInvocationActionEditor(
                        title: actionType == "SceneActivate"
                            ? "Activate Scene"
                            : "Apply Scene",
                        actionType: actionType,
                        supportsReleaseTiming: supportsReleaseTiming,
                        initialAction: context.action,
                        actionLabel: "Done"
                    ) { value in
                        try await context.setAction(rawValue: value)
                    }
                } label: {
                    Label("Edit Scene Action", systemImage: "sparkles")
                }
                .disabled(context.isBusy)
            }
        } else {
            AutomationRawActionRows(context: context)
        }
    }
}

private struct AutomationRawActionRows: View {
    let context: AutomationActionPresentationContext

    var body: some View {
        SceneConfigurationValueRow(
            label: "Raw action",
            value: context.action.rawValue
        )

        if context.supportsGenericActionMutation {
            NavigationLink {
                AutomationActionJSONEditor(
                    title: context.action.type ?? "Action",
                    initialValue: context.action.rawValue,
                    actionLabel: "Done"
                ) { value in
                    try await context.setAction(rawValue: value)
                }
            } label: {
                Label("Edit JSON", systemImage: "curlybraces")
            }
            .disabled(context.isBusy)
        } else {
            Text(
                "This action type is preserved as authored but does not have a dedicated editor."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct AutomationWaitActionEditor: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let initialAction: SceneActionConfiguration?
    let actionLabel: String
    let onCommit: (HBJSONValue) async throws -> Void

    @State private var durationInput: String
    @State private var isSubmitting = false
    @State private var submissionError: String?

    private var initialDurationInput: String? {
        initialAction?.payload?.compactConfigurationJSON
    }

    init(
        title: String,
        initialAction: SceneActionConfiguration?,
        actionLabel: String,
        onCommit: @escaping (HBJSONValue) async throws -> Void
    ) {
        self.title = title
        self.initialAction = initialAction
        self.actionLabel = actionLabel
        self.onCommit = onCommit
        _durationInput = State(
            initialValue: initialAction?.payload?.compactConfigurationJSON
                ?? "1"
        )
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Duration") {
                    TextField("0 or more", text: $durationInput)
                        .font(.body.monospacedDigit())
                        .multilineTextAlignment(.trailing)
#if os(iOS)
                        .keyboardType(.decimalPad)
#endif
                }
                if let validationMessage {
                    validationLabel(validationMessage)
                }
                if let submissionError {
                    validationLabel(submissionError)
                }
            } footer: {
                Text("Actions after this one wait for the duration to elapse.")
            }
        }
        .navigationTitle(title)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(isSubmitting)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .disabled(isSubmitting)
            }
            ToolbarItem(placement: .primaryAction) {
                if isSubmitting {
                    ProgressView().accessibilityLabel("Saving wait")
                } else {
                    Button(action: submit) {
                        Label(actionLabel, systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(parsedDuration == nil)
                }
            }
        }
        .onChange(of: durationInput) {
            submissionError = nil
        }
    }

    private var parsedDuration: HBJSONValue? {
        guard let value = parseJSONValue(durationInput),
              let duration = value.numberValue,
              duration.isFinite,
              duration >= 0 else {
            return nil
        }
        return value
    }

    private var validationMessage: String? {
        parsedDuration == nil
            ? "Enter zero or a positive number of seconds."
            : nil
    }

    private func submit() {
        if durationInput == initialDurationInput {
            dismiss()
            return
        }
        guard let parsedDuration else { return }
        let value = HBJSONValue.object(["Wait": parsedDuration])
        if value == initialAction?.rawValue {
            dismiss()
            return
        }
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                try await onCommit(value)
                dismiss()
            } catch {
                submissionError = error.localizedDescription
            }
        }
    }
}

private struct AutomationSceneInvocationActionEditor: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let actionType: String
    let supportsReleaseTiming: Bool
    let initialAction: SceneActionConfiguration?
    let actionLabel: String
    let onCommit: (HBJSONValue) async throws -> Void

    private let initialConfiguration:
        AutomationSceneInvocationActionConfiguration?

    @State private var identifierInput: String
    @State private var priorityInput: String
    @State private var timingInput: String
    @State private var releaseTimingInput: String
    @State private var isSubmitting = false
    @State private var submissionError: String?

    init(
        title: String,
        actionType: String,
        supportsReleaseTiming: Bool,
        initialAction: SceneActionConfiguration?,
        actionLabel: String,
        onCommit: @escaping (HBJSONValue) async throws -> Void
    ) {
        self.title = title
        self.actionType = actionType
        self.supportsReleaseTiming = supportsReleaseTiming
        self.initialAction = initialAction
        self.actionLabel = actionLabel
        self.onCommit = onCommit
        let configuration = initialAction.flatMap {
            AutomationSceneInvocationActionConfiguration(
                action: $0,
                actionType: actionType
            )
        }
        initialConfiguration = configuration
        _identifierInput = State(initialValue: configuration?.identifier ?? "")
        _priorityInput = State(
            initialValue: configuration?.priority?.compactConfigurationJSON
                ?? ""
        )
        _timingInput = State(
            initialValue: configuration?.timing?.compactConfigurationJSON
                ?? ""
        )
        _releaseTimingInput = State(
            initialValue:
                configuration?.releaseTiming?.compactConfigurationJSON ?? ""
        )
    }

    var body: some View {
        Form {
            Section("Scene") {
                LabeledContent("Identifier") {
                    TextField("Required", text: $identifierInput)
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                }
                if let identifierValidationMessage {
                    validationLabel(identifierValidationMessage)
                }
            }

            Section {
                optionalNumberField(
                    "Priority",
                    prompt: "Inherited",
                    text: $priorityInput
                )
                if let priorityValidationMessage {
                    validationLabel(priorityValidationMessage)
                }

                optionalNumberField(
                    "Transition (seconds)",
                    prompt: "Inherited",
                    text: $timingInput
                )
                if let timingValidationMessage {
                    validationLabel(timingValidationMessage)
                }

                if supportsReleaseTiming {
                    optionalNumberField(
                        "Return transition (seconds)",
                        prompt: "Normal return",
                        text: $releaseTimingInput
                    )
                    if let releaseTimingValidationMessage {
                        validationLabel(releaseTimingValidationMessage)
                    }
                }
            } header: {
                Text("Overrides")
            } footer: {
                Text(overrideExplanation)
            }

            if let initialConfiguration,
               !initialConfiguration.additionalFields.isEmpty {
                Section("Preserved Fields") {
                    ForEach(
                        initialConfiguration.additionalFields,
                        id: \.key
                    ) { field in
                        SceneConfigurationValueRow(
                            label: field.key,
                            value: field.value
                        )
                    }
                }
            }

            if let submissionError {
                Section {
                    validationLabel(submissionError)
                }
            }
        }
        .navigationTitle(title)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(isSubmitting)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .disabled(isSubmitting)
            }
            ToolbarItem(placement: .primaryAction) {
                if isSubmitting {
                    ProgressView().accessibilityLabel("Saving scene action")
                } else {
                    Button(action: submit) {
                        Label(actionLabel, systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(actionValue == nil)
                }
            }
        }
        .onChange(of: identifierInput) { submissionError = nil }
        .onChange(of: priorityInput) { submissionError = nil }
        .onChange(of: timingInput) { submissionError = nil }
        .onChange(of: releaseTimingInput) { submissionError = nil }
    }

    @ViewBuilder
    private func optionalNumberField(
        _ label: String,
        prompt: String,
        text: Binding<String>
    ) -> some View {
        LabeledContent(label) {
            TextField(prompt, text: text)
                .font(.body.monospacedDigit())
                .multilineTextAlignment(.trailing)
#if os(iOS)
                .keyboardType(.numbersAndPunctuation)
#endif
        }
    }

    private var overrideExplanation: String {
        if supportsReleaseTiming {
            "Leave priority and transition empty to inherit from an enclosing scene, or use the selected scene’s settings. If neither sets a priority, HomeBase uses P-0. Leave return transition empty to use normal return behavior."
        } else {
            "Leave priority and transition empty to inherit from an enclosing scene, or use the selected scene’s settings. If neither sets a priority, HomeBase uses P-0."
        }
    }

    private var identifier: String? {
        let trimmed = identifierInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : identifierInput
    }

    private var identifierValidationMessage: String? {
        identifier == nil ? "A scene identifier is required." : nil
    }

    private var parsedPriority: HBJSONValue? {
        parseOptionalInteger(priorityInput)
    }

    private var parsedTiming: HBJSONValue? {
        parseOptionalTiming(timingInput)
    }

    private var parsedReleaseTiming: HBJSONValue? {
        parseOptionalTiming(releaseTimingInput)
    }

    private var priorityValidationMessage: String? {
        optionalIntegerValidationMessage(priorityInput)
    }

    private var timingValidationMessage: String? {
        optionalTimingValidationMessage(timingInput)
    }

    private var releaseTimingValidationMessage: String? {
        optionalTimingValidationMessage(releaseTimingInput)
    }

    private var actionValue: HBJSONValue? {
        guard let identifier,
              priorityValidationMessage == nil,
              timingValidationMessage == nil,
              !supportsReleaseTiming
                || releaseTimingValidationMessage == nil else {
            return nil
        }
        let configuration = initialConfiguration
            ?? AutomationSceneInvocationActionConfiguration(
                action: SceneActionConfiguration(
                    index: 0,
                    rawValue: .object([actionType: .string(identifier)])
                ),
                actionType: actionType
            )
        return configuration?.actionValue(
            identifier: identifier,
            priority: parsedPriority,
            timing: parsedTiming,
            releaseTiming: parsedReleaseTiming,
            supportsReleaseTiming: supportsReleaseTiming,
            patching: patchedFields
        )
    }

    private var patchedFields:
        Set<AutomationSceneInvocationActionConfiguration.Field> {
        guard let initialConfiguration else {
            return Set(
                AutomationSceneInvocationActionConfiguration.Field.allCases
            )
        }

        var fields: Set<
            AutomationSceneInvocationActionConfiguration.Field
        > = []
        if identifierInput != initialConfiguration.identifier {
            fields.insert(.identifier)
        }
        if priorityInput
            != (initialConfiguration.priority?.compactConfigurationJSON ?? "") {
            fields.insert(.priority)
        }
        if timingInput
            != (initialConfiguration.timing?.compactConfigurationJSON ?? "") {
            fields.insert(.timing)
        }
        if releaseTimingInput
            != (initialConfiguration.releaseTiming?.compactConfigurationJSON
                ?? "") {
            fields.insert(.releaseTiming)
        }
        return fields
    }

    private func submit() {
        guard let actionValue else { return }
        if actionValue == initialAction?.rawValue {
            dismiss()
            return
        }
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                try await onCommit(actionValue)
                dismiss()
            } catch {
                submissionError = error.localizedDescription
            }
        }
    }
}

private struct AutomationActionJSONEditor: View {
    private enum ValidationError: LocalizedError {
        case empty
        case invalidJSON(String)
        case invalidAction

        var errorDescription: String? {
            switch self {
            case .empty:
                "Enter one complete JSON action."
            case .invalidJSON(let message):
                "The action is not valid JSON: \(message)"
            case .invalidAction:
                "An action must be an object with exactly one nonempty key."
            }
        }
    }

    @Environment(\.dismiss) private var dismiss

    let title: String
    let initialValue: HBJSONValue
    let actionLabel: String
    let onCommit: (HBJSONValue) async throws -> Void
    private let initialSource: String

    @State private var source: String
    @State private var isSubmitting = false
    @State private var submissionError: String?

    init(
        title: String,
        initialValue: HBJSONValue,
        actionLabel: String,
        onCommit: @escaping (HBJSONValue) async throws -> Void
    ) {
        self.title = title
        self.initialValue = initialValue
        self.actionLabel = actionLabel
        self.onCommit = onCommit
        initialSource = initialValue.prettyConfigurationJSON
        _source = State(initialValue: initialSource)
    }

    var body: some View {
        Form {
            Section("JSON Action") {
                TextEditor(text: $source)
                    .font(.body.monospaced())
                    .frame(minHeight: 180)
                    .autocorrectionDisabled()
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                if let validationMessage {
                    validationLabel(validationMessage)
                }
                if let submissionError {
                    validationLabel(submissionError)
                }
            }

            Section {
                Text(
                    "Unknown action types and fields are preserved unless you explicitly change this JSON value."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(title)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(isSubmitting)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .disabled(isSubmitting)
            }
            ToolbarItem(placement: .primaryAction) {
                if isSubmitting {
                    ProgressView().accessibilityLabel("Saving action")
                } else {
                    Button(action: submit) {
                        Label(actionLabel, systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(parsedValue == nil)
                }
            }
        }
        .onChange(of: source) { submissionError = nil }
    }

    private var parsedValue: HBJSONValue? {
        try? parse(source)
    }

    private var validationMessage: String? {
        do {
            _ = try parse(source)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func parse(_ source: String) throws -> HBJSONValue {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }
        let value: HBJSONValue
        do {
            value = try JSONDecoder().decode(
                HBJSONValue.self,
                from: Data(trimmed.utf8)
            )
        } catch {
            throw ValidationError.invalidJSON(error.localizedDescription)
        }
        guard let object = value.objectValue,
              object.count == 1,
              object.keys.first?.isEmpty == false else {
            throw ValidationError.invalidAction
        }
        return value
    }

    private func submit() {
        if source == initialSource {
            dismiss()
            return
        }
        guard let parsedValue else { return }
        if parsedValue == initialValue {
            dismiss()
            return
        }
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                try await onCommit(parsedValue)
                dismiss()
            } catch {
                submissionError = error.localizedDescription
            }
        }
    }
}

private func fallbackActionPresentation(
    _ action: SceneActionConfiguration,
    title: String
) -> AutomationActionPluginPresentation {
    AutomationActionPluginPresentation(
        title: title,
        detail: action.payload?.compactConfigurationJSON
            ?? action.rawValue.compactConfigurationJSON
    )
}

private func humanizedAutomationIdentifier(_ identifier: String) -> String {
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

private func parseJSONValue(_ source: String) -> HBJSONValue? {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return try? JSONDecoder().decode(
        HBJSONValue.self,
        from: Data(trimmed.utf8)
    )
}

private func parseOptionalInteger(_ source: String) -> HBJSONValue? {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let value = parseJSONValue(trimmed),
          let number = value.numberValue,
          number.isFinite,
          number.rounded(.towardZero) == number,
          number >= Double(Int32.min),
          number <= Double(Int32.max) else {
        return nil
    }
    return value
}

private func optionalIntegerValidationMessage(_ source: String) -> String? {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return parseOptionalInteger(trimmed) == nil
        ? "Enter a whole number from −2,147,483,648 through 2,147,483,647."
        : nil
}

private func parseOptionalTiming(_ source: String) -> HBJSONValue? {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let value = parseJSONValue(trimmed),
          let number = value.numberValue,
          number.isFinite,
          number >= 0 else {
        return nil
    }
    return value
}

private func optionalTimingValidationMessage(_ source: String) -> String? {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return parseOptionalTiming(trimmed) == nil
        ? "Enter zero or a positive number of seconds."
        : nil
}

private func validationLabel(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.red)
}
