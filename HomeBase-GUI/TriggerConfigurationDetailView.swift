//
//  TriggerConfigurationDetailView.swift
//  HomeBase-GUI
//

import Combine
import Foundation
import HomeBaseProtocol
import SwiftUI

private enum TriggerConfigurationEditingSource {
    case existing(triggerName: String)
    case newTrigger(suggestedIdentifier: String)
}

struct TriggerConfigurationDetailView: View {
    @Environment(\.dismiss) private var dismiss

    private let navigationTitle: String
    private let repository: TriggerConfigurationRepository
    @StateObject private var model: TriggerConfigurationDetailModel
    @State private var selectedActionPlugin: AnyAutomationActionTypePlugin?
    @State private var selectedConditionCreation:
        TriggerConditionCreationOption?
    @State private var pendingAddedActionIndex: Int?
    @State private var newlyAddedActionIndex: Int?

    init(triggerName: String, client: HomeBaseWebSocketClient) {
        navigationTitle = triggerName
        let repository = TriggerConfigurationRepository(client: client)
        self.repository = repository
        _model = StateObject(
            wrappedValue: TriggerConfigurationDetailModel(
                source: .existing(triggerName: triggerName),
                repository: repository
            )
        )
    }

    init(newTriggerIdentifier: String, client: HomeBaseWebSocketClient) {
        navigationTitle = "Untitled Trigger"
        let repository = TriggerConfigurationRepository(client: client)
        self.repository = repository
        _model = StateObject(
            wrappedValue: TriggerConfigurationDetailModel(
                source: .newTrigger(
                    suggestedIdentifier: newTriggerIdentifier
                ),
                repository: repository
            )
        )
    }

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                ProgressView("Loading trigger…")
                    .foregroundStyle(.secondary)

            case .loaded:
                TriggerConfigurationContents(
                    model: model,
                    repository: repository,
                    newlyAddedActionIndex: $newlyAddedActionIndex,
                    chooseCondition: { selectedConditionCreation = $0 },
                    chooseAction: beginAddingAction
                )
                .refreshable {
                    await model.reload()
                }

            case .failed(let message):
                ContentUnavailableView {
                    Label(
                        "Trigger Could Not Be Loaded",
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") {
                        Task { await model.forceReload() }
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
                .disabled(model.isBusy)
                .accessibilityLabel("Cancel Editing")
            }

            if model.state == .loaded {
                ToolbarItem(placement: .primaryAction) {
                    if model.isBusy {
                        ProgressView()
                            .accessibilityLabel(
                                model.isDeleting
                                    ? "Deleting trigger"
                                    : "Saving trigger"
                            )
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
        .sheet(item: $selectedActionPlugin, onDismiss: revealAddedAction) {
            plugin in
            plugin.makeCreationView(operations: actionCreationOperations)
        }
        .sheet(item: $selectedConditionCreation) { creation in
            NavigationStack {
                TriggerConditionEditorView(
                    title: creation.title,
                    initialValue: creation.initialValue,
                    repository: repository,
                    actionLabel: "Add"
                ) { value in
                    try model.appendCondition(value)
                }
            }
        }
        .task {
            await model.loadIfNeeded()
        }
    }

    private var actionCreationOperations: AutomationActionCreationOperations {
        AutomationActionCreationOperations(
            controlRepository: repository,
            excludedControlPaths: [],
            configurationKind: "trigger",
            addControlSet: { device, control, valueSource in
                let index = try await model.addControlSet(
                    device: device,
                    control: control,
                    valueSource: valueSource
                )
                pendingAddedActionIndex = index
                return index
            },
            appendAction: { value in
                let index = try await model.appendAction(value)
                pendingAddedActionIndex = index
                return index
            }
        )
    }

    private func beginAddingAction(
        _ plugin: AnyAutomationActionTypePlugin
    ) {
        pendingAddedActionIndex = nil
        newlyAddedActionIndex = nil
        selectedActionPlugin = plugin
    }

    private func revealAddedAction() {
        guard let pendingAddedActionIndex else { return }
        self.pendingAddedActionIndex = nil
        newlyAddedActionIndex = pendingAddedActionIndex
    }

    private func cancel() {
        if model.hasChangesToDiscard {
            model.confirmDiscardAndClose()
        } else {
            dismiss()
        }
    }

    private func makeAlert(_ alert: TriggerEditorAlert) -> Alert {
        switch alert.kind {
        case .discardChanges:
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .destructive(Text("Discard Changes")) {
                    Task { await model.forceReload() }
                },
                secondaryButton: .cancel()
            )

        case .discardAndClose:
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .destructive(Text("Discard Changes")) {
                    dismiss()
                },
                secondaryButton: .cancel(Text("Keep Editing"))
            )

        case .deleteTrigger:
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .destructive(Text("Delete Trigger")) {
                    Task {
                        if await model.deleteTrigger() {
                            dismiss()
                        }
                    }
                },
                secondaryButton: .cancel()
            )

        case .conflict:
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .default(Text("Reload")) {
                    Task { await model.forceReload() }
                },
                secondaryButton: .cancel()
            )

        case .reloadFailed:
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .default(Text("Restore Original")) {
                    Task { await model.restoreOriginal() }
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

private struct TriggerConfigurationContents: View {
    @ObservedObject var model: TriggerConfigurationDetailModel
    let repository: TriggerConfigurationRepository
    @Binding var newlyAddedActionIndex: Int?
    let chooseCondition: (TriggerConditionCreationOption) -> Void
    let chooseAction: (AnyAutomationActionTypePlugin) -> Void

    @State private var highlightedActionIndex: Int?

    var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                if let trigger = model.trigger {
                    Section {
                        TriggerEditableTextRow(
                            label: "Identifier",
                            text: Binding(
                                get: { model.identifierInput },
                                set: model.setIdentifierInput
                            ),
                            prompt: "Required",
                            validationMessage:
                                model.identifierValidationMessage
                        )

                        Picker(
                            "Type",
                            selection: Binding(
                                get: { model.triggerTypeInput },
                                set: model.setTriggerTypeInput
                            )
                        ) {
                            ForEach(TriggerKindUICatalog.supported) {
                                registration in
                                Text(registration.displayName)
                                    .tag(registration.wireValue)
                            }
                        }

                        if let message =
                            model.actionApplicabilityValidationMessage {
                            Label(
                                message,
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.red)
                        }

                        ForEach(trigger.additionalFields, id: \.key) { field in
                            SceneConfigurationValueRow(
                                label: field.key,
                                value: field.value
                            )
                        }
                    } header: {
                        SceneConfigurationSectionHeader("Trigger")
                    }

                    if trigger.conditions.isEmpty {
                        Section {
                            Text(
                                "This trigger has no conditions. It remains inactive unless fired manually."
                            )
                            .foregroundStyle(.secondary)
                            newConditionButton
                        } header: {
                            SceneConfigurationSectionHeader("Conditions")
                        }
                    } else {
                        ForEach(trigger.conditions) { condition in
                            Section {
                                TriggerConditionRows(
                                    condition: condition,
                                    model: model,
                                    repository: repository
                                )
                            } header: {
                                TriggerConditionSectionHeader(
                                    condition: condition,
                                    model: model
                                )
                            }
                        }

                        Section {
                            newConditionButton
                        }
                    }

                    if trigger.actions.isEmpty {
                        Section {
                            Text("This trigger contains no actions.")
                                .foregroundStyle(.secondary)
                            newActionButton
                        } header: {
                            SceneConfigurationSectionHeader("Actions")
                        }
                    } else {
                        ForEach(trigger.actions) { action in
                            Section {
                                AutomationActionConfigurationRows(
                                    action: action,
                                    model: model
                                )
                            } header: {
                                AutomationActionSectionHeader(
                                    action: action,
                                    model: model
                                )
                            }
                            .id(actionScrollID(action.index))
                            .listRowBackground(
                                action.index == highlightedActionIndex
                                    ? Color.accentColor.opacity(0.14)
                                    : nil
                            )
                        }

                        Section {
                            newActionButton
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
                            value: trigger.jsonPath
                        )

                        if model.isAwaitingCreatedTriggerReload {
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
                        } else if let confirmation = model.saveConfirmation {
                            Label(
                                confirmation,
                                systemImage: "checkmark.circle"
                            )
                            .foregroundStyle(.green)
                        }

                        if model.showsDeleteAction {
                            Button(role: .destructive) {
                                model.confirmDeletion()
                            } label: {
                                if model.isDeleting {
                                    HStack(spacing: 10) {
                                        ProgressView().controlSize(.small)
                                        Text("Deleting Trigger…")
                                    }
                                } else {
                                    Label(
                                        "Delete Trigger",
                                        systemImage: "trash"
                                    )
                                }
                            }
                            .disabled(!model.canDelete)
                        }
                    } header: {
                        SceneConfigurationSectionHeader("Source")
                    }
                }
            }
            .onChange(of: newlyAddedActionIndex) { _, actionIndex in
                guard let actionIndex else { return }
                newlyAddedActionIndex = nil
                reveal(actionIndex, using: scrollProxy)
            }
        }
    }

    private var newConditionButton: some View {
        Menu {
            ForEach(TriggerConditionTypeRegistry.standard.creationOptions) {
                option in
                Button {
                    chooseCondition(option)
                } label: {
                    Label(option.title, systemImage: option.systemImage)
                }
            }
        } label: {
            Label("New Condition", systemImage: "plus")
        }
        .disabled(!model.canMutateStructure)
    }

    private var newActionButton: some View {
        Menu {
            ForEach(
                AutomationActionTypeRegistry.standard.creationPlugins(
                    for: model.actionConfigurationContext
                )
            ) { plugin in
                Button {
                    chooseAction(plugin)
                } label: {
                    Label(plugin.displayName, systemImage: plugin.systemImage)
                }
            }
        } label: {
            Label("New Action", systemImage: "plus")
        }
        .disabled(!model.canMutateStructure)
    }

    private func actionScrollID(_ actionIndex: Int) -> String {
        "trigger-action-\(actionIndex)"
    }

    private func reveal(_ actionIndex: Int, using proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.3)) {
            highlightedActionIndex = actionIndex
            proxy.scrollTo(actionScrollID(actionIndex), anchor: .center)
        }

        Task { @MainActor in
            try? await Task<Never, Never>.sleep(for: .seconds(1))
            guard highlightedActionIndex == actionIndex else { return }
            withAnimation(.easeOut(duration: 0.35)) {
                highlightedActionIndex = nil
            }
        }
    }
}

private struct TriggerEditableTextRow: View {
    let label: String
    @Binding var text: String
    let prompt: String
    let validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .font(.body.monospaced())
                .autocorrectionDisabled()
#if os(iOS)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
#endif
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
}

private struct TriggerConditionSectionHeader: View {
    let condition: TriggerConditionConfiguration
    @ObservedObject var model: TriggerConfigurationDetailModel

    var body: some View {
        let presentation = TriggerConditionTypeRegistry.standard
            .presentation(for: condition.rawValue)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Condition \(condition.index + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(role: .destructive) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.removeCondition(at: condition.index)
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canMutateStructure)
            .accessibilityLabel("Remove Condition")
        }
        .textCase(nil)
    }
}

private struct TriggerConditionRows: View {
    let condition: TriggerConditionConfiguration
    @ObservedObject var model: TriggerConfigurationDetailModel
    let repository: TriggerConfigurationRepository

    var body: some View {
        let presentation = TriggerConditionTypeRegistry.standard
            .presentation(for: condition.rawValue)

        if let detail = presentation.detail {
            LabeledContent("Configuration") {
                Text(detail)
                    .multilineTextAlignment(.trailing)
            }
        }

        NavigationLink {
            TriggerConditionEditorView(
                title: presentation.title,
                initialValue: condition.rawValue,
                repository: repository,
                actionLabel: "Done"
            ) { value in
                try model.setCondition(
                    at: condition.index,
                    rawValue: value
                )
            }
        } label: {
            Label("Edit Condition", systemImage: "slider.horizontal.3")
        }
        .disabled(model.isBusy)
    }
}

struct TriggerConditionJSONEditor: View {
    private enum ValidationError: LocalizedError {
        case empty
        case invalidJSON(String)
        case invalidCondition

        var errorDescription: String? {
            switch self {
            case .empty:
                "Enter one complete JSON condition."
            case .invalidJSON(let message):
                "The condition is not valid JSON: \(message)"
            case .invalidCondition:
                "A condition must be an object with exactly one nonempty key."
            }
        }
    }

    @Environment(\.dismiss) private var dismiss

    let title: String
    let actionLabel: String
    let onCommit: (HBJSONValue) throws -> Void

    @State private var source: String
    @State private var submissionError: String?

    init(
        title: String,
        initialValue: HBJSONValue,
        actionLabel: String,
        onCommit: @escaping (HBJSONValue) throws -> Void
    ) {
        self.title = title
        self.actionLabel = actionLabel
        self.onCommit = onCommit
        _source = State(initialValue: initialValue.prettyConfigurationJSON)
    }

    var body: some View {
        Form {
            Section("JSON Condition") {
                TextEditor(text: $source)
                    .font(.body.monospaced())
                    .frame(minHeight: 180)
                    .autocorrectionDisabled()
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif

                if let validationMessage {
                    Label(
                        validationMessage,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                }
                if let submissionError {
                    Label(
                        submissionError,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }

            Section {
                Text(
                    "Condition types are source-authored. Unknown and nested condition forms are preserved exactly unless you edit this value."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(title)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(actionLabel, action: submit)
                    .disabled(parsedValue == nil)
            }
        }
        .onChange(of: source) {
            submissionError = nil
        }
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
            throw ValidationError.invalidCondition
        }
        return value
    }

    private func submit() {
        do {
            let value = try parse(source)
            try onCommit(value)
            dismiss()
        } catch {
            submissionError = error.localizedDescription
        }
    }
}

private struct TriggerEditorAlert: Identifiable {
    enum Kind {
        case discardChanges
        case discardAndClose
        case deleteTrigger
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
private final class TriggerConfigurationDetailModel:
    AutomationActionEditingModel
{
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
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var draft: TriggerConfigurationDraft?
    @Published private(set) var isSaving = false
    @Published private(set) var isDeleting = false
    @Published private(set) var saveConfirmation: String?
    @Published private(set) var identifierInput = ""
    @Published private(set) var triggerTypeInput =
        TriggerKindUICatalog.defaultRegistration.wireValue
    @Published var presentedAlert: TriggerEditorAlert?

    private let source: TriggerConfigurationEditingSource
    private let repository: TriggerConfigurationRepository
    private var resolutions: [Int: AutomationControlResolution] = [:]
    private var loadingCurrentValues: Set<Int> = []
    private var actionErrors: [Int: String] = [:]
    private var pendingRecovery: TriggerConfigurationRecovery?
    private var pendingCreatedTrigger: TriggerConfigurationDocument?
    private var initialIdentifierInput = ""
    private var initialTriggerTypeInput =
        TriggerKindUICatalog.defaultRegistration.wireValue

    init(
        source: TriggerConfigurationEditingSource,
        repository: TriggerConfigurationRepository
    ) {
        self.source = source
        self.repository = repository

        guard case .newTrigger(let suggestedIdentifier) = source else {
            return
        }
        do {
            let newDraft = try TriggerConfigurationDraft.newTrigger(
                identifier: suggestedIdentifier
            )
            draft = newDraft
            identifierInput = suggestedIdentifier
            triggerTypeInput =
                TriggerKindUICatalog.defaultRegistration.wireValue
            initialIdentifierInput = identifierInput
            initialTriggerTypeInput = triggerTypeInput
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    var trigger: TriggerConfigurationDocument? {
        draft?.trigger
    }

    var isBusy: Bool {
        isSaving || isDeleting
    }

    var isDirty: Bool {
        draft?.isDirty == true
            || pendingCreatedTrigger != nil
            || identifierInput != initialIdentifierInput
            || triggerTypeInput != initialTriggerTypeInput
    }

    var hasChangesToDiscard: Bool {
        draft?.hasSemanticChanges == true
            || identifierInput != initialIdentifierInput
            || triggerTypeInput != initialTriggerTypeInput
    }

    var isAwaitingCreatedTriggerReload: Bool {
        pendingCreatedTrigger != nil
    }

    var canMutateStructure: Bool {
        state == .loaded && !isBusy && loadingCurrentValues.isEmpty
    }

    var supportsGenericActionMutation: Bool { true }

    var actionConfigurationContext: AutomationActionConfigurationContext {
        TriggerKindUICatalog.actionConfigurationContext(
            forEditorWireValue: triggerTypeInput
        )
    }

    var showsDeleteAction: Bool {
        draft?.isNew == false
    }

    var canDelete: Bool {
        state == .loaded && showsDeleteAction && !isBusy
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

    var actionApplicabilityValidationMessage: String? {
        guard let actions = trigger?.actions else { return nil }
        let registry = AutomationActionTypeRegistry.standard
        let incompatible = actions.compactMap { action -> String? in
            let plugin = registry.resolve(action).plugin
            guard !plugin.supports(
                action: action,
                in: actionConfigurationContext
            ) else {
                return nil
            }
            return "\(plugin.displayName) (action \(action.index + 1))"
        }
        guard !incompatible.isEmpty else { return nil }
        let actionList = incompatible.formatted(
            .list(type: .and, width: .standard)
        )
        return "\(actionList) cannot be used in a \(triggerTypeInput) trigger. Remove the incompatible action or change the trigger type."
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
                : "A new trigger file will be created when saved."
        }
        guard draft.identifierChanged else { return nil }
        if !draft.derivesSourcePathFromIdentifier {
            return "This file contains multiple triggers, so its name will remain unchanged."
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

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await forceReload()
    }

    func confirmDiscardAndClose() {
        guard !isBusy else { return }
        presentedAlert = TriggerEditorAlert(
            kind: .discardAndClose,
            title: "Discard Trigger Changes?",
            message: "Your unsaved trigger changes will be lost."
        )
    }

    func confirmDeletion() {
        guard canDelete, let original = draft?.original else { return }
        let name = original.identifier ?? "this trigger"
        let message: String
        if original.occupiesEntireSourceFile {
            message =
                "This permanently deletes the trigger and its configuration file, \(original.source.path). This cannot be undone."
        } else {
            message =
                "This permanently removes the trigger from \(original.source.path). Other triggers in that file will be preserved. This cannot be undone."
        }
        presentedAlert = TriggerEditorAlert(
            kind: .deleteTrigger,
            title: "Delete \"\(name)\"?",
            message: hasChangesToDiscard
                ? message + " Unsaved changes will also be discarded."
                : message
        )
    }

    func reload() async {
        guard case .existing = source else { return }
        guard !isDirty else {
            presentedAlert = TriggerEditorAlert(
                kind: .discardChanges,
                title: "Discard Changes?",
                message:
                    "Reloading will discard the trigger values edited on this screen."
            )
            return
        }
        await forceReload()
    }

    func forceReload() async {
        guard !isBusy,
              case .existing(let triggerName) = source else {
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
            let trigger = try await repository.loadTrigger(named: triggerName)
            install(trigger, retainingResolutions: false)
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
        updateTrigger { draft in
            try draft.setIdentifier(input)
        }
    }

    func setTriggerTypeInput(_ input: String) {
        triggerTypeInput = input
        saveConfirmation = nil
        updateTrigger { draft in
            try draft.setTriggerType(input)
        }
    }

    func setCondition(at index: Int, rawValue: HBJSONValue) throws {
        guard canMutateStructure, var updated = draft else {
            throw EditorError.unavailable
        }
        try updated.setCondition(at: index, rawValue: rawValue)
        draft = updated
        saveConfirmation = nil
        objectWillChange.send()
    }

    func appendCondition(_ value: HBJSONValue) throws {
        guard canMutateStructure, var updated = draft else {
            throw EditorError.unavailable
        }
        _ = try updated.appendCondition(value)
        draft = updated
        saveConfirmation = nil
        objectWillChange.send()
    }

    func removeCondition(at index: Int) {
        guard canMutateStructure, var updated = draft else { return }
        do {
            try updated.removeCondition(at: index)
            draft = updated
            saveConfirmation = nil
            objectWillChange.send()
        } catch {
            presentedAlert = TriggerEditorAlert(
                kind: .message,
                title: "Condition Could Not Be Removed",
                message: error.localizedDescription
            )
        }
    }

    func setControlValue(
        actionIndex: Int,
        value: HBJSONValue
    ) async throws {
        guard !isBusy, var updated = draft else {
            throw EditorError.unavailable
        }
        try updated.setControlValue(actionIndex: actionIndex, value: value)
        draft = updated
        actionErrors[actionIndex] = nil
        saveConfirmation = nil
        objectWillChange.send()
    }

    func setAction(
        actionIndex: Int,
        rawValue: HBJSONValue
    ) async throws {
        guard canMutateStructure, var updated = draft else {
            throw EditorError.unavailable
        }
        let originalRoot = updated.root
        try updated.setAction(at: actionIndex, rawValue: rawValue)
        guard updated.root != originalRoot else { return }

        draft = updated
        resolutions[actionIndex] = nil
        actionErrors[actionIndex] = nil
        saveConfirmation = nil

        let needsResolution = updated.trigger.actions[actionIndex]
            .controlSet != nil
        if needsResolution {
            resolutions[actionIndex] = .resolving
        }
        objectWillChange.send()

        if needsResolution {
            await resolveControls()
        }
    }

    func removeAction(actionIndex: Int) {
        guard canMutateStructure, var updated = draft else { return }

        do {
            try updated.removeAction(at: actionIndex)
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
            presentedAlert = TriggerEditorAlert(
                kind: .message,
                title: "Action Could Not Be Removed",
                message: error.localizedDescription
            )
        }
    }

    func appendAction(_ rawValue: HBJSONValue) async throws -> Int {
        guard canMutateStructure, var updated = draft else {
            throw EditorError.unavailable
        }
        let actionIndex = try updated.appendAction(rawValue)
        draft = updated
        actionErrors[actionIndex] = nil
        saveConfirmation = nil

        let needsResolution = updated.trigger.actions[actionIndex]
            .controlSet != nil
        if needsResolution {
            resolutions[actionIndex] = .resolving
        }
        objectWillChange.send()

        if needsResolution {
            await resolveControls()
        }
        return actionIndex
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
            presentedAlert = TriggerEditorAlert(
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
    ) async throws -> Int {
        guard canMutateStructure, var updated = draft else {
            throw EditorError.unavailable
        }

        let resolved = SceneResolvedControl(
            device: device,
            descriptor: control
        )
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
        return actionIndex
    }

    func useCurrentValue(actionIndex: Int) async {
        guard !isBusy,
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

    func controlResolution(
        for actionIndex: Int
    ) -> AutomationControlResolution {
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

    func saveIfNeeded() async -> Bool {
        guard state == .loaded, !isBusy else { return false }
        if let identifierValidationMessage {
            presentedAlert = TriggerEditorAlert(
                kind: .message,
                title: "Trigger Fields Need Attention",
                message: identifierValidationMessage
            )
            return false
        }
        if let actionApplicabilityValidationMessage {
            presentedAlert = TriggerEditorAlert(
                kind: .message,
                title: "Trigger Actions Need Attention",
                message: actionApplicabilityValidationMessage
            )
            return false
        }
        guard draft?.isDirty == true || pendingCreatedTrigger != nil else {
            return true
        }
        return await save()
    }

    func deleteTrigger() async -> Bool {
        guard canDelete, let original = draft?.original else { return false }
        isDeleting = true
        actionErrors = [:]
        saveConfirmation = nil
        defer { isDeleting = false }

        do {
            _ = try await repository.delete(original)
            return true
        } catch let error as TriggerConfigurationDeleteError {
            if case .conflict = error {
                presentedAlert = conflictAlert(
                    message: error.localizedDescription
                )
            } else {
                presentedAlert = TriggerEditorAlert(
                    kind: .message,
                    title: "Trigger Could Not Be Deleted",
                    message: error.localizedDescription
                )
            }
        } catch is CancellationError {
            return false
        } catch {
            presentedAlert = TriggerEditorAlert(
                kind: .message,
                title: "Trigger Could Not Be Deleted",
                message: error.localizedDescription
            )
        }
        return false
    }

    func restoreOriginal() async {
        guard let recovery = pendingRecovery, !isBusy else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let restored = try await repository.restore(recovery)
            install(restored, retainingResolutions: true)
            pendingRecovery = nil
            saveConfirmation = "Original file restored and reloaded"
        } catch let error as TriggerConfigurationSaveError {
            if case .conflict = error {
                presentedAlert = conflictAlert(
                    message: error.localizedDescription
                )
            } else {
                presentedAlert = TriggerEditorAlert(
                    kind: .message,
                    title: "Original Could Not Be Restored",
                    message: error.localizedDescription
                )
            }
        } catch {
            presentedAlert = TriggerEditorAlert(
                kind: .message,
                title: "Original Could Not Be Restored",
                message: error.localizedDescription
            )
        }
    }

    private func save() async -> Bool {
        guard let draft else { return false }
        isSaving = true
        actionErrors = [:]
        saveConfirmation = nil
        defer { isSaving = false }

        do {
            let outcome: TriggerConfigurationSaveOutcome
            if let pendingCreatedTrigger, !draft.isDirty {
                outcome = try await repository.reloadCreatedTrigger(
                    pendingCreatedTrigger
                )
            } else {
                outcome = try await repository.save(draft)
            }

            switch outcome {
            case .unchanged(let trigger):
                install(trigger, retainingResolutions: true)
                pendingRecovery = nil
                pendingCreatedTrigger = nil

            case .saved(let trigger, let reload):
                install(trigger, retainingResolutions: true)
                pendingRecovery = nil
                pendingCreatedTrigger = nil
                saveConfirmation = reload.reloadStrategy
                    == .fullAutomationGraph
                    ? "Saved and reloaded"
                    : "Saved"
            }
            return true
        } catch let error as TriggerConfigurationSaveError {
            handleSaveError(error)
        } catch is CancellationError {
            return false
        } catch {
            presentedAlert = TriggerEditorAlert(
                kind: .message,
                title: "Trigger Could Not Be Saved",
                message: error.localizedDescription
            )
        }
        return false
    }

    private func updateTrigger(
        _ mutation: (inout TriggerConfigurationDraft) throws -> Void
    ) {
        guard !isBusy, var updated = draft else { return }
        do {
            try mutation(&updated)
            draft = updated
            objectWillChange.send()
        } catch {
            presentedAlert = TriggerEditorAlert(
                kind: .message,
                title: "Trigger Field Could Not Be Changed",
                message: error.localizedDescription
            )
        }
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

    private func install(
        _ trigger: TriggerConfigurationDocument,
        retainingResolutions: Bool
    ) {
        draft = TriggerConfigurationDraft(trigger: trigger)
        pendingCreatedTrigger = nil
        identifierInput = trigger.identifier ?? ""
        triggerTypeInput = trigger.triggerType
            ?? TriggerKindUICatalog.defaultRegistration.wireValue
        initialIdentifierInput = identifierInput
        initialTriggerTypeInput = triggerTypeInput
        if !retainingResolutions {
            resolutions = Dictionary(
                uniqueKeysWithValues: trigger.actions.compactMap { action in
                    guard action.controlSet != nil else { return nil }
                    return (action.index, .resolving)
                }
            )
        }
        actionErrors = [:]
        loadingCurrentValues = []
    }

    private func resolveControls() async {
        guard let trigger else { return }
        let controlSets = trigger.actions.compactMap(\.controlSet)
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

    private func handleSaveError(_ error: TriggerConfigurationSaveError) {
        switch error {
        case .conflict:
            presentedAlert = conflictAlert(message: error.localizedDescription)

        case .invalidDerivedFilename:
            presentedAlert = TriggerEditorAlert(
                kind: .message,
                title: draft?.isNew == true
                    ? "Trigger Cannot Be Created"
                    : "Trigger File Cannot Be Renamed",
                message: error.localizedDescription
            )

        case .renameRollbackFailed:
            presentedAlert = TriggerEditorAlert(
                kind: .conflict,
                title: "Trigger File Rename Needs Attention",
                message: error.localizedDescription
            )

        case .fileAlreadyExists, .triggerAlreadyExists,
             .creationPreflightFailed:
            presentedAlert = TriggerEditorAlert(
                kind: .message,
                title: "Trigger Could Not Be Created",
                message: error.localizedDescription
            )

        case .creationReloadFailed(let message, let presumedTrigger):
            install(presumedTrigger, retainingResolutions: true)
            pendingCreatedTrigger = presumedTrigger
            presentedAlert = TriggerEditorAlert(
                kind: .message,
                title: "Trigger File Created but Not Loaded",
                message: message
                    + " The file remains on the server. You can retry with the checkmark or continue editing it."
            )

        case .reloadFailed(let message, let recovery, let presumedTrigger):
            install(presumedTrigger, retainingResolutions: true)
            pendingRecovery = recovery
            presentedAlert = TriggerEditorAlert(
                kind: .reloadFailed,
                title: "Trigger Saved but Not Loaded",
                message: message
                    + " The previous trigger remains active. You can restore the original file or keep editing the saved file."
            )

        case .verificationFailed(let message, let presumedTrigger):
            install(presumedTrigger, retainingResolutions: true)
            pendingRecovery = nil
            saveConfirmation = "Saved and reloaded; verification pending"
            presentedAlert = TriggerEditorAlert(
                kind: .message,
                title: "Trigger Saved",
                message: message
            )
        }
    }

    private func conflictAlert(message: String) -> TriggerEditorAlert {
        TriggerEditorAlert(
            kind: .conflict,
            title: "Trigger Changed on Server",
            message: message
        )
    }
}
