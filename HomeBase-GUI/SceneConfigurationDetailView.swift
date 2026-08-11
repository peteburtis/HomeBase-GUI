//
//  SceneConfigurationDetailView.swift
//  HomeBase-GUI
//

import Combine
import Foundation
import HomeBaseProtocol
import SwiftUI

private enum SceneConfigurationEditingSource {
    case existing(sceneName: String)
    case newScene(suggestedIdentifier: String)
}

struct SceneConfigurationDetailView: View {
    @Environment(\.dismiss) private var dismiss

    private let navigationTitle: String
    private let repository: SceneConfigurationRepository
    @StateObject private var model: SceneConfigurationDetailModel
    @State private var isShowingControlPicker = false
    @State private var isConfirmingDiscard = false

    init(
        sceneName: String,
        client: HomeBaseWebSocketClient
    ) {
        navigationTitle = sceneName
        let repository = SceneConfigurationRepository(client: client)
        self.repository = repository
        _model = StateObject(
            wrappedValue: SceneConfigurationDetailModel(
                source: .existing(sceneName: sceneName),
                repository: repository
            )
        )
    }

    init(
        newSceneIdentifier: String,
        client: HomeBaseWebSocketClient
    ) {
        navigationTitle = "Untitled Scene"
        let repository = SceneConfigurationRepository(client: client)
        self.repository = repository
        _model = StateObject(
            wrappedValue: SceneConfigurationDetailModel(
                source: .newScene(
                    suggestedIdentifier: newSceneIdentifier
                ),
                repository: repository
            )
        )
    }

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                ProgressView("Loading scene…")
                    .foregroundStyle(.secondary)

            case .loaded:
                SceneConfigurationContents(model: model)
                    .refreshable {
                        await model.reload()
                    }

            case .failed(let message):
                ContentUnavailableView {
                    Label(
                        "Scene Could Not Be Loaded",
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") {
                        Task {
                            await model.forceReload()
                        }
                    }
                }
            }
        }
        .navigationTitle(navigationTitle)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    cancel()
                } label: {
                    Image(systemName: "xmark")
                }
                .disabled(model.isSaving)
                .accessibilityLabel("Cancel Editing")
            }

            if model.state == .loaded {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        isShowingControlPicker = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!model.canMutateStructure)
                    .accessibilityLabel("Add Control Set")

                    if model.isSaving {
                        ProgressView()
                            .accessibilityLabel("Saving scene")
                    } else {
                        Button {
                            Task {
                                if await model.saveIfNeeded() {
                                    dismiss()
                                }
                            }
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .accessibilityLabel("Save and Close")
                    }
                }
            }
        }
        .alert(item: $model.presentedAlert, content: makeAlert)
        .confirmationDialog(
            "Discard Scene Changes?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) {
                dismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your unsaved scene changes will be lost.")
        }
        .sheet(isPresented: $isShowingControlPicker) {
            SceneControlPickerView(
                repository: repository,
                excludedControlPaths: model.configuredControlPaths
            ) { device, control, valueSource in
                try await model.addControlSet(
                    device: device,
                    control: control,
                    valueSource: valueSource
                )
            }
        }
        .task {
            await model.loadIfNeeded()
        }
    }

    private func cancel() {
        if model.hasChangesToDiscard {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func makeAlert(_ alert: SceneEditorAlert) -> Alert {
        switch alert.kind {
        case .discardChanges:
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .destructive(Text("Discard Changes")) {
                    Task {
                        await model.forceReload()
                    }
                },
                secondaryButton: .cancel()
            )

        case .conflict:
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .default(Text("Reload")) {
                    Task {
                        await model.forceReload()
                    }
                },
                secondaryButton: .cancel()
            )

        case .reloadFailed:
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .default(Text("Restore Original")) {
                    Task {
                        await model.restoreOriginal()
                    }
                },
                secondaryButton: .cancel(Text("Keep Saved File"))
            )

        case .message:
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

private struct SceneConfigurationContents: View {
    @ObservedObject var model: SceneConfigurationDetailModel

    var body: some View {
        List {
            if let scene = model.scene {
                Section {
                    SceneConfigurationEditableTextRow(
                        label: "Identifier",
                        text: Binding(
                            get: { model.identifierInput },
                            set: model.setIdentifierInput
                        ),
                        prompt: "Required",
                        kind: .identifier,
                        validationMessage:
                            model.identifierValidationMessage
                    )
                    SceneConfigurationEditableTextRow(
                        label: "Priority",
                        text: Binding(
                            get: { model.priorityInput },
                            set: model.setPriorityInput
                        ),
                        prompt: "Default",
                        kind: .integer,
                        validationMessage: model.priorityValidationMessage
                    )
                    SceneConfigurationEditableTextRow(
                        label: "Timing",
                        text: Binding(
                            get: { model.timingInput },
                            set: model.setTimingInput
                        ),
                        prompt: "Default (seconds)",
                        kind: .decimal,
                        validationMessage: model.timingValidationMessage
                    )

                    ForEach(scene.additionalFields, id: \.key) { field in
                        SceneConfigurationValueRow(
                            label: field.key,
                            value: field.value
                        )
                    }
                } header: {
                    SceneConfigurationSectionHeader("Scene")
                }

                if scene.actions.isEmpty {
                    Section {
                        Text("This scene contains no actions.")
                            .foregroundStyle(.secondary)
                    } header: {
                        SceneConfigurationSectionHeader("Actions")
                    }
                } else {
                    ForEach(scene.actions) { action in
                        Section {
                            SceneActionConfigurationRows(
                                action: action,
                                model: model
                            )
                        } header: {
                            SceneActionSectionHeader(
                                action: action,
                                model: model
                            )
                        }
                    }
                }

                Section {
                    SceneConfigurationFileRow(
                        path: model.presentedFilePath,
                        note: model.filePathNote,
                        renamePending: model.fileRenameIsPending,
                        creatingFile: model.fileCreationIsPending
                    )
                    SceneConfigurationTextRow(
                        label: "JSON location",
                        value: scene.jsonPath
                    )

                    if model.isAwaitingCreatedSceneReload {
                        Label(
                            "File created; reload pending",
                            systemImage: "arrow.clockwise.circle"
                        )
                        .foregroundStyle(.orange)
                    } else if model.isDirty {
                        Label(
                            "Unsaved changes",
                            systemImage: "pencil.circle"
                        )
                        .foregroundStyle(.secondary)
                    } else if let saveConfirmation = model.saveConfirmation {
                        Label(
                            saveConfirmation,
                            systemImage: "checkmark.circle"
                        )
                        .foregroundStyle(.green)
                    }
                } header: {
                    SceneConfigurationSectionHeader("Source")
                }
            }
        }
    }
}

private struct SceneActionSectionHeader: View {
    let action: SceneActionConfiguration
    @ObservedObject var model: SceneConfigurationDetailModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.type ?? "Unrecognized action")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Action \(action.index + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if action.controlSet != nil {
                Button(role: .destructive) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.removeControlSet(
                            actionIndex: action.index
                        )
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(!model.canMutateStructure)
                .accessibilityLabel("Remove Control Set")
            }
        }
        .textCase(nil)
    }
}

private struct SceneActionConfigurationRows: View {
    let action: SceneActionConfiguration
    @ObservedObject var model: SceneConfigurationDetailModel

    @ViewBuilder
    var body: some View {
        if let controlSet = action.controlSet {
            SceneConfigurationTextRow(
                label: "Device",
                value: controlSet.device
            )
            SceneConfigurationTextRow(
                label: "Control",
                value: controlSet.control
            )
            SceneControlSetValueRow(
                controlSet: controlSet,
                model: model
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
        } else if let payload = action.payload {
            SceneConfigurationValueRow(
                label: "Configuration",
                value: payload
            )
        } else {
            SceneConfigurationValueRow(
                label: "Raw action",
                value: action.rawValue
            )
        }
    }

    private func controlSetTrailingLabel(
        value: HBJSONValue,
        absoluteIndex: Int
    ) -> String {
        if value.objectValue != nil {
            return "Options"
        }
        if absoluteIndex == 3 {
            return "Priority"
        }
        return "Element \(absoluteIndex + 1)"
    }
}

private struct SceneControlSetValueRow: View {
    let controlSet: SceneControlSetConfiguration
    @ObservedObject var model: SceneConfigurationDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Value")
                .font(.caption)
                .foregroundStyle(.secondary)

            switch model.controlResolution(for: controlSet.actionIndex) {
            case .resolving:
                HStack(spacing: 10) {
                    rawValue
                    Spacer(minLength: 8)
                    ProgressView()
                        .controlSize(.small)
                }

            case .unavailable(let message):
                rawValue
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .resolved(let target):
                resolvedValue(target)
            }

            if let error = model.actionError(
                for: controlSet.actionIndex
            ) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func resolvedValue(_ target: SceneResolvedControl) -> some View {
        let context = target.presentationContext(
            value: controlSet.value,
            isEnabled: !model.isSaving
                && !model.isLoadingCurrentValue(
                    actionIndex: controlSet.actionIndex
                ),
            commit: { value, _ in
                try await model.setControlValue(
                    actionIndex: controlSet.actionIndex,
                    value: value
                )
            }
        )
        let plugin = ControlValueTypeRegistry.standard
            .resolve(context.schema)
            .plugin

        if plugin.supportsEditing(context: context) {
            HStack(spacing: 12) {
                ControlValuePluginView(context: context)

                Spacer(minLength: 4)

                Button {
                    Task {
                        await model.useCurrentValue(
                            actionIndex: controlSet.actionIndex
                        )
                    }
                } label: {
                    if model.isLoadingCurrentValue(
                        actionIndex: controlSet.actionIndex
                    ) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Current", systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(model.isSaving)
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
                    try await model.setControlValue(
                        actionIndex: controlSet.actionIndex,
                        value: value
                    )
                }
            } label: {
                Label("Edit JSON", systemImage: "curlybraces")
            }
            .disabled(model.isSaving)

            Text(
                "This control does not have a dedicated editor."
            )
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

private struct SceneConfigurationSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .textCase(nil)
            .font(.headline)
            .foregroundStyle(.primary)
    }
}

private struct SceneConfigurationEditableTextRow: View {
    enum InputKind {
        case identifier
        case integer
        case decimal
    }

    let label: String
    @Binding var text: String
    let prompt: String
    let kind: InputKind
    let validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            configuredTextField

            if let validationMessage {
                Label(
                    validationMessage,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var configuredTextField: some View {
#if os(iOS)
        switch kind {
        case .identifier:
            textField
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
        case .integer:
            textField
                .keyboardType(.numbersAndPunctuation)
        case .decimal:
            textField
                .keyboardType(.decimalPad)
        }
#else
        textField
#endif
    }

    private var textField: some View {
        TextField(prompt, text: $text)
            .font(.body.monospaced())
            .autocorrectionDisabled()
    }
}

private struct SceneConfigurationFileRow: View {
    let path: String
    let note: String?
    let renamePending: Bool
    let creatingFile: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("File")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(path)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let note {
                Label(
                    note,
                    systemImage: statusSystemImage
                )
                .font(.caption)
                .foregroundStyle(statusColor)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusSystemImage: String {
        if creatingFile { return "doc.badge.plus" }
        return renamePending ? "arrow.right" : "doc.on.doc"
    }

    private var statusColor: Color {
        if creatingFile { return .accentColor }
        return renamePending ? .orange : .secondary
    }
}

private struct SceneConfigurationTextRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

private struct SceneConfigurationValueRow: View {
    let label: String
    let value: HBJSONValue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(presentedValue)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private var presentedValue: String {
        switch value {
        case .string(let value):
            value
        case .array, .object:
            value.prettyConfigurationJSON
        default:
            value.compactConfigurationJSON
        }
    }
}

private enum SceneControlResolution: Equatable, Sendable {
    case resolving
    case resolved(SceneResolvedControl)
    case unavailable(String)
}

private struct SceneEditorAlert: Identifiable {
    enum Kind {
        case discardChanges
        case conflict
        case reloadFailed
        case message
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
}

@MainActor
private final class SceneConfigurationDetailModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private enum EditorError: LocalizedError {
        case unavailable
        case invalidCurrentValue
        case mixedCurrentValue
        case staleCurrentValue
        case duplicateControl

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "This control is not available for editing."
            case .invalidCurrentValue:
                "The current presented value is not compatible with this editor."
            case .mixedCurrentValue:
                "This control currently represents multiple different values."
            case .staleCurrentValue:
                "HomeBase does not currently have a valid presented value for this control."
            case .duplicateControl:
                "This scene already contains a set for that control."
            }
        }
    }

    private enum ParsedOptionalField<Value> {
        case value(Value?)
        case invalid(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var draft: SceneConfigurationDraft?
    @Published private(set) var isSaving = false
    @Published private(set) var saveConfirmation: String?
    @Published private(set) var identifierInput = ""
    @Published private(set) var priorityInput = ""
    @Published private(set) var timingInput = ""
    @Published var presentedAlert: SceneEditorAlert?

    private let source: SceneConfigurationEditingSource
    private let repository: SceneConfigurationRepository
    private var resolutions: [Int: SceneControlResolution] = [:]
    private var loadingCurrentValues: Set<Int> = []
    private var actionErrors: [Int: String] = [:]
    private var pendingRecovery: SceneConfigurationRecovery?
    private var pendingCreatedScene: SceneConfigurationDocument?
    private var initialIdentifierInput = ""
    private var initialPriorityInput = ""
    private var initialTimingInput = ""

    init(
        source: SceneConfigurationEditingSource,
        repository: SceneConfigurationRepository
    ) {
        self.source = source
        self.repository = repository

        guard case .newScene(let suggestedIdentifier) = source else {
            return
        }
        do {
            let newDraft = try SceneConfigurationDraft.newScene(
                identifier: suggestedIdentifier
            )
            draft = newDraft
            identifierInput = suggestedIdentifier
            priorityInput = "0"
            timingInput = "1"
            initialIdentifierInput = identifierInput
            initialPriorityInput = priorityInput
            initialTimingInput = timingInput
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    var scene: SceneConfigurationDocument? {
        draft?.scene
    }

    var isDirty: Bool {
        draft?.isDirty == true
            || pendingCreatedScene != nil
            || identifierInput != initialIdentifierInput
            || priorityInput != initialPriorityInput
            || timingInput != initialTimingInput
    }

    var hasChangesToDiscard: Bool {
        draft?.hasSemanticChanges == true
            || identifierInput != initialIdentifierInput
            || priorityInput != initialPriorityInput
            || timingInput != initialTimingInput
    }

    var isAwaitingCreatedSceneReload: Bool {
        pendingCreatedScene != nil
    }

    var canSave: Bool {
        state == .loaded
            && (draft?.isDirty == true || pendingCreatedScene != nil)
            && metadataValidationMessage == nil
            && !isSaving
    }

    var canMutateStructure: Bool {
        state == .loaded && !isSaving && loadingCurrentValues.isEmpty
    }

    var configuredControlPaths: Set<String> {
        Set(
            scene?.actions.compactMap(\.controlSet).map {
                Self.normalizedControlPath($0.controlPath)
            } ?? []
        )
    }

    var identifierValidationMessage: String? {
        if identifierInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            return "Identifier is required."
        }
        if let draft,
           (draft.isNew || draft.identifierChanged),
           draft.derivesSourcePathFromIdentifier,
           draft.proposedSourcePath == nil {
            return "An identifier used as a filename cannot begin with a period or contain a slash."
        }
        return nil
    }

    var priorityValidationMessage: String? {
        guard case .invalid(let message) = parsedPriority else { return nil }
        return message
    }

    var timingValidationMessage: String? {
        guard case .invalid(let message) = parsedTiming else { return nil }
        return message
    }

    var presentedFilePath: String {
        guard let draft else { return "—" }
        return draft.proposedSourcePath ?? draft.original.source.path
    }

    var filePathNote: String? {
        guard let draft else { return nil }
        if draft.isNew {
            return draft.proposedSourcePath == nil
                ? "Enter an identifier to choose the new file name."
                : "A new scene file will be created when saved."
        }
        guard draft.identifierChanged else { return nil }
        if !draft.derivesSourcePathFromIdentifier {
            return "This file contains multiple scenes, so its name will remain unchanged."
        }
        guard let proposedPath = draft.proposedSourcePath,
              proposedPath != draft.original.source.path else {
            return nil
        }
        return "Will be renamed from \(draft.original.source.path) when saved."
    }

    var fileRenameIsPending: Bool {
        draft?.sourceRename != nil
    }

    var fileCreationIsPending: Bool {
        draft?.isNew == true
    }

    private var parsedPriority: ParsedOptionalField<Int32> {
        let input = priorityInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !input.isEmpty else { return .value(nil) }
        guard let value = Double(input),
              value.isFinite,
              value.rounded(.towardZero) == value,
              value >= Double(Int32.min),
              value <= Double(Int32.max) else {
            return .invalid("Priority must be a signed 32-bit integer.")
        }
        return .value(Int32(value))
    }

    private var parsedTiming: ParsedOptionalField<Double> {
        let input = timingInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !input.isEmpty else { return .value(nil) }
        guard let value = Double(input), value.isFinite, value >= 0 else {
            return .invalid("Timing must be a nonnegative number of seconds.")
        }
        return .value(value)
    }

    private var metadataValidationMessage: String? {
        identifierValidationMessage
            ?? priorityValidationMessage
            ?? timingValidationMessage
    }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await forceReload()
    }

    func reload() async {
        guard case .existing = source else { return }
        guard !isDirty else {
            presentedAlert = SceneEditorAlert(
                kind: .discardChanges,
                title: "Discard Changes?",
                message:
                    "Reloading will discard the scene values edited on this screen."
            )
            return
        }
        await forceReload()
    }

    func forceReload() async {
        guard !isSaving,
              case .existing(let sceneName) = source else {
            return
        }
        state = .loading
        draft = nil
        resolutions = [:]
        loadingCurrentValues = []
        actionErrors = [:]
        pendingRecovery = nil
        saveConfirmation = nil
        objectWillChange.send()

        do {
            let scene = try await repository.loadScene(named: sceneName)
            install(scene, retainingResolutions: false)
            state = .loaded
            await resolveControls()
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func setIdentifierInput(_ input: String) {
        identifierInput = input
        saveConfirmation = nil
        updateSceneMetadata { draft in
            try draft.setIdentifier(input)
        }
    }

    func setPriorityInput(_ input: String) {
        priorityInput = input
        saveConfirmation = nil
        guard case .value(let priority) = parsedPriority else { return }
        updateSceneMetadata { draft in
            try draft.setPriority(priority)
        }
    }

    func setTimingInput(_ input: String) {
        timingInput = input
        saveConfirmation = nil
        guard case .value(let timing) = parsedTiming else { return }
        updateSceneMetadata { draft in
            try draft.setTiming(timing)
        }
    }

    private func updateSceneMetadata(
        _ mutation: (inout SceneConfigurationDraft) throws -> Void
    ) {
        guard !isSaving, var updated = draft else { return }
        do {
            try mutation(&updated)
            draft = updated
            objectWillChange.send()
        } catch {
            presentedAlert = SceneEditorAlert(
                kind: .message,
                title: "Scene Field Could Not Be Changed",
                message: error.localizedDescription
            )
        }
    }

    func setControlValue(
        actionIndex: Int,
        value: HBJSONValue
    ) async throws {
        guard !isSaving, var updated = draft else {
            throw EditorError.unavailable
        }
        try updated.setControlValue(actionIndex: actionIndex, value: value)
        draft = updated
        actionErrors[actionIndex] = nil
        saveConfirmation = nil
        objectWillChange.send()
    }

    func removeControlSet(actionIndex: Int) {
        guard canMutateStructure, var updated = draft else { return }

        do {
            try updated.removeControlSet(actionIndex: actionIndex)
            draft = updated
            resolutions = shiftingIndexes(
                in: resolutions,
                afterRemoving: actionIndex
            )
            actionErrors = shiftingIndexes(
                in: actionErrors,
                afterRemoving: actionIndex
            )
            saveConfirmation = nil
            objectWillChange.send()
        } catch {
            presentedAlert = SceneEditorAlert(
                kind: .message,
                title: "Control Set Could Not Be Removed",
                message: error.localizedDescription
            )
        }
    }

    func addControlSet(
        device: HBDeviceDescriptor,
        control: HBControlDescriptor,
        valueSource: SceneControlSetValueSource
    ) async throws {
        guard canMutateStructure, var updated = draft else {
            throw EditorError.unavailable
        }

        let resolved = SceneResolvedControl(
            device: device,
            descriptor: control
        )
        guard !configuredControlPaths.contains(
            Self.normalizedControlPath(resolved.path)
        ) else {
            throw EditorError.duplicateControl
        }

        let value: HBJSONValue
        switch valueSource {
        case .currentPresentation:
            let current = try await repository.currentPresentedValue(
                for: resolved.path
            )
            value = try validatedCurrentValue(current, for: resolved)

        case .explicit(let explicitValue):
            try SceneRawControlValueValidator(control: control).validate(
                explicitValue
            )
            value = explicitValue
        }
        guard canMutateStructure,
              let latestDraft = draft,
              latestDraft.root == updated.root else {
            throw EditorError.unavailable
        }
        guard !configuredControlPaths.contains(
            Self.normalizedControlPath(resolved.path)
        ) else {
            throw EditorError.duplicateControl
        }
        updated = latestDraft
        let actionIndex = try updated.appendControlSet(
            device: device.addressableName,
            control: control.identifier,
            value: value
        )

        draft = updated
        resolutions[actionIndex] = .resolved(resolved)
        actionErrors[actionIndex] = nil
        saveConfirmation = nil
        objectWillChange.send()
    }

    func useCurrentValue(actionIndex: Int) async {
        guard !isSaving,
              !loadingCurrentValues.contains(actionIndex),
              case .resolved(let target) = resolutions[actionIndex] else {
            return
        }

        loadingCurrentValues.insert(actionIndex)
        actionErrors[actionIndex] = nil
        objectWillChange.send()
        defer {
            loadingCurrentValues.remove(actionIndex)
            objectWillChange.send()
        }

        do {
            let current = try await repository.currentPresentedValue(
                for: target.path
            )
            let value = try validatedCurrentValue(current, for: target)
            try await setControlValue(
                actionIndex: actionIndex,
                value: value
            )
        } catch is CancellationError {
            return
        } catch {
            actionErrors[actionIndex] = error.localizedDescription
        }
    }

    func saveIfNeeded() async -> Bool {
        guard state == .loaded, !isSaving else { return false }
        if let metadataValidationMessage {
            presentedAlert = SceneEditorAlert(
                kind: .message,
                title: "Scene Fields Need Attention",
                message: metadataValidationMessage
            )
            return false
        }
        guard draft?.isDirty == true || pendingCreatedScene != nil else {
            return true
        }
        return await save()
    }

    private func save() async -> Bool {
        guard canSave, let draft else { return false }
        isSaving = true
        actionErrors = [:]
        saveConfirmation = nil
        defer { isSaving = false }

        do {
            let outcome: SceneConfigurationSaveOutcome
            if let pendingCreatedScene, !draft.isDirty {
                outcome = try await repository.reloadCreatedScene(
                    pendingCreatedScene
                )
            } else {
                outcome = try await repository.save(draft)
            }

            switch outcome {
            case .unchanged(let scene):
                install(scene, retainingResolutions: true)
                pendingRecovery = nil
                pendingCreatedScene = nil

            case .saved(let scene, let reload):
                install(scene, retainingResolutions: true)
                pendingRecovery = nil
                pendingCreatedScene = nil
                saveConfirmation = reload.reloadStrategy
                    == .fullAutomationGraph
                    ? "Saved and reloaded"
                    : "Saved"
            }
            return true
        } catch let error as SceneConfigurationSaveError {
            handleSaveError(error)
        } catch is CancellationError {
            return false
        } catch {
            presentedAlert = SceneEditorAlert(
                kind: .message,
                title: "Scene Could Not Be Saved",
                message: error.localizedDescription
            )
        }
        return false
    }

    func restoreOriginal() async {
        guard let recovery = pendingRecovery, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            let restored = try await repository.restore(recovery)
            install(restored, retainingResolutions: true)
            pendingRecovery = nil
            saveConfirmation = "Original file restored and reloaded"
        } catch let error as SceneConfigurationSaveError {
            if case .conflict = error {
                presentedAlert = conflictAlert(message: error.localizedDescription)
            } else {
                presentedAlert = SceneEditorAlert(
                    kind: .message,
                    title: "Original Could Not Be Restored",
                    message: error.localizedDescription
                )
            }
        } catch {
            presentedAlert = SceneEditorAlert(
                kind: .message,
                title: "Original Could Not Be Restored",
                message: error.localizedDescription
            )
        }
    }

    func controlResolution(for actionIndex: Int) -> SceneControlResolution {
        resolutions[actionIndex] ?? .unavailable(
            "Control metadata is unavailable."
        )
    }

    func isLoadingCurrentValue(actionIndex: Int) -> Bool {
        loadingCurrentValues.contains(actionIndex)
    }

    func actionError(for actionIndex: Int) -> String? {
        actionErrors[actionIndex]
    }

    private func validatedCurrentValue(
        _ current: HBControlGetResult,
        for target: SceneResolvedControl
    ) throws -> HBJSONValue {
        guard current.valid != false else {
            throw EditorError.staleCurrentValue
        }
        if current.aggregateState == .mixed {
            throw EditorError.mixedCurrentValue
        }
        guard current.aggregateState != .unavailable else {
            throw EditorError.staleCurrentValue
        }
        guard target.supportsEditing(value: current.value) else {
            throw EditorError.invalidCurrentValue
        }
        return current.value
    }

    private func shiftingIndexes<Value>(
        in values: [Int: Value],
        afterRemoving removedIndex: Int
    ) -> [Int: Value] {
        var shifted: [Int: Value] = [:]
        shifted.reserveCapacity(values.count)
        for (index, value) in values where index != removedIndex {
            shifted[index > removedIndex ? index - 1 : index] = value
        }
        return shifted
    }

    private static func normalizedControlPath(_ path: String) -> String {
        path.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func install(
        _ scene: SceneConfigurationDocument,
        retainingResolutions: Bool
    ) {
        draft = SceneConfigurationDraft(scene: scene)
        pendingCreatedScene = nil
        installMetadataInputs(from: scene)
        if !retainingResolutions {
            resolutions = Dictionary(
                uniqueKeysWithValues: scene.actions.compactMap { action in
                    guard action.controlSet != nil else { return nil }
                    return (action.index, .resolving)
                }
            )
        }
        actionErrors = [:]
        loadingCurrentValues = []
    }

    private func installMetadataInputs(
        from scene: SceneConfigurationDocument
    ) {
        identifierInput = scene.identifier ?? ""
        priorityInput = scene.fields["Priority"]?.compactConfigurationJSON
            ?? ""
        timingInput = scene.fields["Timing"]?.compactConfigurationJSON ?? ""
        initialIdentifierInput = identifierInput
        initialPriorityInput = priorityInput
        initialTimingInput = timingInput
    }

    private func resolveControls() async {
        guard let scene else { return }
        let controlSets = scene.actions.compactMap(\.controlSet)
        let grouped = Dictionary(grouping: controlSets) {
            $0.device.lowercased()
        }

        for key in grouped.keys.sorted() {
            guard let configurations = grouped[key],
                  let requestedDevice = configurations.first?.device else {
                continue
            }

            do {
                let device = try await repository.deviceDetails(
                    named: requestedDevice
                )
                for configuration in configurations {
                    guard let descriptor = device.controls.first(where: {
                        $0.identifier.caseInsensitiveCompare(
                            configuration.control
                        ) == .orderedSame
                    }) else {
                        resolutions[configuration.actionIndex] = .unavailable(
                            "HomeBase did not report this control in the device schema."
                        )
                        continue
                    }
                    resolutions[configuration.actionIndex] = .resolved(
                        SceneResolvedControl(
                            path: configuration.controlPath,
                            descriptor: descriptor
                        )
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                for configuration in configurations {
                    resolutions[configuration.actionIndex] = .unavailable(
                        "Control metadata could not be loaded: \(error.localizedDescription)"
                    )
                }
            }
            objectWillChange.send()
        }
    }

    private func handleSaveError(_ error: SceneConfigurationSaveError) {
        switch error {
        case .conflict:
            presentedAlert = conflictAlert(message: error.localizedDescription)

        case .invalidDerivedFilename:
            presentedAlert = SceneEditorAlert(
                kind: .message,
                title: draft?.isNew == true
                    ? "Scene Cannot Be Created"
                    : "Scene File Cannot Be Renamed",
                message: error.localizedDescription
            )

        case .fileRenameUnsupported:
            presentedAlert = SceneEditorAlert(
                kind: .message,
                title: "Scene File Cannot Be Renamed",
                message: error.localizedDescription
            )

        case .fileAlreadyExists, .sceneAlreadyExists,
             .creationPreflightFailed:
            presentedAlert = SceneEditorAlert(
                kind: .message,
                title: "Scene Could Not Be Created",
                message: error.localizedDescription
            )

        case .creationReloadFailed(
            let message,
            let presumedScene
        ):
            install(presumedScene, retainingResolutions: true)
            pendingCreatedScene = presumedScene
            presentedAlert = SceneEditorAlert(
                kind: .message,
                title: "Scene File Created but Not Loaded",
                message: message
                    + " The file remains on the server. You can retry with the checkmark or continue editing it."
            )

        case .reloadFailed(let message, let recovery, let presumedScene):
            install(presumedScene, retainingResolutions: true)
            pendingRecovery = recovery
            presentedAlert = SceneEditorAlert(
                kind: .reloadFailed,
                title: "Scene Saved but Not Loaded",
                message: message
                    + " The previous scene remains active. You can restore the original file or keep editing the saved file."
            )

        case .verificationFailed(let message, let presumedScene):
            install(presumedScene, retainingResolutions: true)
            pendingRecovery = nil
            saveConfirmation = "Saved and reloaded; verification pending"
            presentedAlert = SceneEditorAlert(
                kind: .message,
                title: "Scene Saved",
                message: message
            )
        }
    }

    private func conflictAlert(message: String) -> SceneEditorAlert {
        SceneEditorAlert(
            kind: .conflict,
            title: "Scene Changed on Server",
            message: message
        )
    }
}
