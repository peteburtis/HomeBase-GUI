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
    @State private var selectedActionPlugin: AnyAutomationActionTypePlugin?
    @State private var pendingAddedActionIndex: Int?
    @State private var newlyAddedActionIndex: Int?

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
                SceneConfigurationContents(
                    model: model,
                    newlyAddedActionIndex: $newlyAddedActionIndex,
                    chooseAction: beginAddingAction
                )
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
                .disabled(model.isBusy)
                .accessibilityLabel("Cancel Editing")
            }

            if model.state == .loaded {
                ToolbarItem(placement: .primaryAction) {
                    if model.isBusy {
                        ProgressView()
                            .accessibilityLabel(
                                model.isDeleting
                                    ? "Deleting scene"
                                    : model.isUpdatingLiveEditing
                                        ? "Updating live editing"
                                        : "Saving scene"
                            )
                    } else {
                        Button {
                            Task {
                                if await model.saveIfNeeded(),
                                   await model.stopLiveEditingForExit() {
                                    dismiss()
                                }
                            }
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .buttonStyle(.glassProminent)
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
        .task {
            await model.loadIfNeeded()
        }
    }

    private var actionCreationOperations: AutomationActionCreationOperations {
        AutomationActionCreationOperations(
            controlRepository: repository,
            excludedControlPaths: model.configuredControlPaths,
            configurationKind: "scene",
            addControlSet: { deviceAddressableName, control, valueSource in
                let index = try await model.addControlSet(
                    deviceAddressableName: deviceAddressableName,
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

    private func beginAddingAction(_ plugin: AnyAutomationActionTypePlugin) {
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
            Task {
                if await model.stopLiveEditingForExit() {
                    dismiss()
                }
            }
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

        case .discardAndClose:
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .destructive(Text("Discard Changes")) {
                    Task {
                        if await model.stopLiveEditingForExit() {
                            dismiss()
                        }
                    }
                },
                secondaryButton: .cancel(Text("Keep Editing"))
            )

        case .deleteScene:
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .destructive(Text("Delete Scene")) {
                    Task {
                        if await model.stopLiveEditingForExit(),
                           await model.deleteScene() {
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
    @Binding var newlyAddedActionIndex: Int?
    let chooseAction: (AnyAutomationActionTypePlugin) -> Void

    @State private var highlightedActionIndex: Int?

    var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                if let scene = model.scene {
                    Section {
                        Toggle(
                            "Live Editing",
                            isOn: Binding(
                                get: { model.isLiveEditing },
                                set: { enabled in
                                    Task {
                                        await model.setLiveEditingEnabled(
                                            enabled
                                        )
                                    }
                                }
                            )
                        )
                        .disabled(!model.canToggleLiveEditing)

                        if model.isUpdatingLiveEditing {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Updating the live preview…")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text(
                                model.isLiveEditing
                                    ? "Control changes are temporarily applied at P-User. Saving, canceling, or turning this off returns the home to its underlying state."
                                    : "Preview this scene while editing. Control changes apply immediately; transitions and other action types are not run."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } header: {
                        SceneConfigurationSectionHeader("Preview")
                    }

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
                            prompt: "Per action (P-0 if unset)",
                            kind: .integer,
                            validationMessage: model.priorityValidationMessage
                        )
                        SceneConfigurationEditableTextRow(
                            label: "Transition",
                            text: Binding(
                                get: { model.timingInput },
                                set: model.setTimingInput
                            ),
                            prompt: "Per action (seconds)",
                            kind: .decimal,
                            validationMessage: model.timingValidationMessage
                        )

                        Text(
                            "Priority and transition are optional scene-wide overrides. Leave them empty to keep each action’s own setting."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        ForEach(scene.additionalFields, id: \.key) { field in
                            SceneConfigurationValueRow(
                                label: field.key,
                                value: field.value
                            )
                        }
                    } header: {
                        SceneConfigurationSectionHeader("Scene")
                    }

                    if let message =
                        model.actionApplicabilityValidationMessage {
                        Section {
                            Label(
                                message,
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.red)
                        } header: {
                            SceneConfigurationSectionHeader("Actions")
                        }
                    }

                    if scene.actions.isEmpty {
                        Section {
                            Text("This scene contains no actions.")
                                .foregroundStyle(.secondary)
                            newActionButton
                        } header: {
                            SceneConfigurationSectionHeader("Actions")
                        }
                    } else {
                        ForEach(scene.actions) { action in
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
                        if model.showsDeleteAction {
                            Button(role: .destructive) {
                                model.confirmDeletion()
                            } label: {
                                if model.isDeleting {
                                    HStack(spacing: 10) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Deleting Scene…")
                                    }
                                } else {
                                    Label("Delete Scene", systemImage: "trash")
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

    private var newActionButton: some View {
        Menu {
            ForEach(
                AutomationActionTypeRegistry.standard.creationPlugins(
                    for: .scene
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
        "scene-action-\(actionIndex)"
    }

    private func reveal(
        _ actionIndex: Int,
        using scrollProxy: ScrollViewProxy
    ) {
        withAnimation(.easeInOut(duration: 0.3)) {
            highlightedActionIndex = actionIndex
            scrollProxy.scrollTo(
                actionScrollID(actionIndex),
                anchor: .center
            )
        }

        Task { @MainActor in
            do {
                try await Task<Never, Never>.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard highlightedActionIndex == actionIndex else { return }
            withAnimation(.easeOut(duration: 0.35)) {
                highlightedActionIndex = nil
            }
        }
    }
}

struct SceneConfigurationSectionHeader: View {
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

struct SceneConfigurationFileRow: View {
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

struct SceneConfigurationTextRow: View {
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

struct SceneConfigurationValueRow: View {
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

private struct SceneEditorAlert: Identifiable {
    enum Kind {
        case discardChanges
        case discardAndClose
        case deleteScene
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
private final class SceneConfigurationDetailModel: AutomationActionEditingModel {
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
    @Published private(set) var isDeleting = false
    @Published private(set) var isLiveEditing = false
    @Published private(set) var isUpdatingLiveEditing = false
    @Published private(set) var saveConfirmation: String?
    @Published private(set) var identifierInput = ""
    @Published private(set) var priorityInput = ""
    @Published private(set) var timingInput = ""
    @Published var presentedAlert: SceneEditorAlert?

    private let source: SceneConfigurationEditingSource
    private let repository: SceneConfigurationRepository
    private let liveEditingSession: SceneLiveEditingSession
    private var resolutions: [Int: AutomationControlResolution] = [:]
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
        liveEditingSession = SceneLiveEditingSession(
            client: repository.client
        )

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

    var isBusy: Bool {
        isSaving || isDeleting || isUpdatingLiveEditing
    }

    var canToggleLiveEditing: Bool {
        state == .loaded && !isSaving && !isDeleting
            && !isUpdatingLiveEditing
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
            && actionApplicabilityValidationMessage == nil
            && !isBusy
    }

    var canMutateStructure: Bool {
        state == .loaded && !isBusy && loadingCurrentValues.isEmpty
    }

    var canEditControlValues: Bool {
        state == .loaded && !isSaving && !isDeleting
            && loadingCurrentValues.isEmpty
    }

    var isUpdatingControlValues: Bool {
        isUpdatingLiveEditing
    }

    var supportsGenericActionMutation: Bool { true }

    var showsDeleteAction: Bool {
        draft?.isNew == false
    }

    var canDelete: Bool {
        state == .loaded && showsDeleteAction && !isBusy
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

    var actionApplicabilityValidationMessage: String? {
        guard let actions = scene?.actions else { return nil }
        let registry = AutomationActionTypeRegistry.standard
        let incompatible = actions.compactMap { action -> String? in
            let plugin = registry.resolve(action).plugin
            guard !plugin.supports(action: action, in: .scene) else {
                return nil
            }
            return "\(plugin.displayName) (action \(action.index + 1))"
        }
        guard !incompatible.isEmpty else { return nil }
        let actionList = incompatible.formatted(
            .list(type: .and, width: .standard)
        )
        return "\(actionList) cannot be used in a scene. Remove the incompatible action before saving."
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

    func setLiveEditingEnabled(_ enabled: Bool) async {
        guard state == .loaded,
              !isSaving,
              !isDeleting,
              !isUpdatingLiveEditing,
              enabled != isLiveEditing else {
            return
        }

        if !enabled {
            _ = await stopLiveEditingForExit()
            return
        }

        isUpdatingLiveEditing = true
        defer { isUpdatingLiveEditing = false }

        do {
            try await liveEditingSession.start(
                targets: liveEditingTargets
            )
            isLiveEditing = true
        } catch is CancellationError {
            await recoverFromLiveEditingFailure(
                title: "Live Editing Was Interrupted",
                error: CancellationError()
            )
        } catch {
            await recoverFromLiveEditingFailure(
                title: "Live Editing Could Not Start",
                error: error
            )
        }
    }

    func stopLiveEditingForExit() async -> Bool {
        guard !isUpdatingLiveEditing else { return false }
        let sessionIsActive = await liveEditingSession.isActive()
        let hasOutstandingHolds =
            await liveEditingSession.hasOutstandingHolds()
        guard isLiveEditing || sessionIsActive || hasOutstandingHolds else {
            return true
        }

        isUpdatingLiveEditing = true
        defer { isUpdatingLiveEditing = false }

        do {
            try await liveEditingSession.stop()
            isLiveEditing = false
            return true
        } catch is CancellationError {
            isLiveEditing = true
            return false
        } catch {
            isLiveEditing = true
            presentedAlert = SceneEditorAlert(
                kind: .message,
                title: "Live Editing Could Not Stop",
                message:
                    "HomeBase could not release every temporary scene hold. The editor will remain open so you can try again. \(error.localizedDescription)"
            )
            return false
        }
    }

    func confirmDiscardAndClose() {
        guard !isBusy else { return }
        presentedAlert = SceneEditorAlert(
            kind: .discardAndClose,
            title: "Discard Scene Changes?",
            message: "Your unsaved scene changes will be lost."
        )
    }

    func confirmDeletion() {
        guard canDelete, let original = draft?.original else { return }
        let name = original.identifier ?? "this scene"
        let message: String
        if original.occupiesEntireSourceFile {
            message =
                "This permanently deletes the scene and its configuration file, \(original.source.path). This cannot be undone."
        } else {
            message =
                "This permanently removes the scene from \(original.source.path). Other scenes in that file will be preserved. This cannot be undone."
        }
        presentedAlert = SceneEditorAlert(
            kind: .deleteScene,
            title: "Delete \"\(name)\"?",
            message: hasChangesToDiscard
                ? message + " Unsaved changes will also be discarded."
                : message
        )
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
        guard !isBusy,
              case .existing(let sceneName) = source else {
            return
        }
        guard await stopLiveEditingForExit() else { return }
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
        guard !isBusy, var updated = draft else { return }
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
        guard !isBusy, var updated = draft else {
            throw EditorError.unavailable
        }
        try updated.setControlValue(actionIndex: actionIndex, value: value)
        draft = updated
        actionErrors[actionIndex] = nil
        saveConfirmation = nil
        objectWillChange.send()
        try await reconcileLiveEditingAfterMutation()
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

        let needsResolution = updated.scene.actions[actionIndex].controlSet != nil
        if needsResolution {
            resolutions[actionIndex] = .resolving
        }
        objectWillChange.send()

        do {
            try await reconcileLiveEditingAfterMutation()
        } catch {
            if needsResolution {
                await resolveControls()
            }
            throw error
        }

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
            scheduleLiveEditingReconciliation()
        } catch {
            presentedAlert = SceneEditorAlert(
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

        let needsResolution = updated.scene.actions[actionIndex].controlSet != nil
        if needsResolution {
            resolutions[actionIndex] = .resolving
        }
        objectWillChange.send()

        do {
            try await reconcileLiveEditingAfterMutation()
        } catch {
            if needsResolution {
                await resolveControls()
            }
            throw error
        }

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
            scheduleLiveEditingReconciliation()
        } catch {
            presentedAlert = SceneEditorAlert(
                kind: .message,
                title: "Control Set Could Not Be Removed",
                message: error.localizedDescription
            )
        }
    }

    func addControlSet(
        deviceAddressableName: String,
        control: HBControlDescriptor,
        valueSource: SceneControlSetValueSource
    ) async throws -> Int {
        guard canMutateStructure, var updated = draft else {
            throw EditorError.unavailable
        }

        let resolved = SceneResolvedControl(
            path: "\(deviceAddressableName):\(control.identifier)",
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
            device: deviceAddressableName,
            control: control.identifier,
            value: value
        )

        draft = updated
        resolutions[actionIndex] = .resolved(resolved)
        actionErrors[actionIndex] = nil
        saveConfirmation = nil
        objectWillChange.send()
        try await reconcileLiveEditingAfterMutation()
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

    func saveIfNeeded() async -> Bool {
        guard state == .loaded, !isBusy else { return false }
        if let metadataValidationMessage {
            presentedAlert = SceneEditorAlert(
                kind: .message,
                title: "Scene Fields Need Attention",
                message: metadataValidationMessage
            )
            return false
        }
        if let actionApplicabilityValidationMessage {
            presentedAlert = SceneEditorAlert(
                kind: .message,
                title: "Scene Actions Need Attention",
                message: actionApplicabilityValidationMessage
            )
            return false
        }
        guard draft?.isDirty == true || pendingCreatedScene != nil else {
            return true
        }
        return await save()
    }

    func deleteScene() async -> Bool {
        guard canDelete, let original = draft?.original else { return false }
        isDeleting = true
        actionErrors = [:]
        saveConfirmation = nil
        defer { isDeleting = false }

        do {
            _ = try await repository.delete(original)
            return true
        } catch let error as SceneConfigurationDeleteError {
            if case .conflict = error {
                presentedAlert = conflictAlert(
                    message: error.localizedDescription
                )
            } else {
                presentedAlert = SceneEditorAlert(
                    kind: .message,
                    title: "Scene Could Not Be Deleted",
                    message: error.localizedDescription
                )
            }
        } catch is CancellationError {
            return false
        } catch {
            presentedAlert = SceneEditorAlert(
                kind: .message,
                title: "Scene Could Not Be Deleted",
                message: error.localizedDescription
            )
        }
        return false
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
        guard let recovery = pendingRecovery, !isBusy else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            let restored = try await repository.restore(recovery)
            install(restored, retainingResolutions: true)
            pendingRecovery = nil
            saveConfirmation = "Original file restored and reloaded"
            try? await reconcileLiveEditingAfterMutation()
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

    private var liveEditingTargets: [SceneLiveEditingTarget] {
        SceneLiveEditingTarget.targets(for: scene?.actions ?? [])
    }

    private func reconcileLiveEditingAfterMutation() async throws {
        guard isLiveEditing else { return }
        isUpdatingLiveEditing = true
        defer { isUpdatingLiveEditing = false }

        do {
            try await liveEditingSession.reconcile(
                targets: liveEditingTargets
            )
        } catch {
            await recoverFromLiveEditingFailure(
                title: "Live Editing Stopped",
                error: error
            )
            throw error
        }
    }

    private func scheduleLiveEditingReconciliation() {
        guard isLiveEditing, !isUpdatingLiveEditing else { return }
        isUpdatingLiveEditing = true

        Task { [weak self] in
            guard let self else { return }
            defer { isUpdatingLiveEditing = false }
            do {
                try await liveEditingSession.reconcile(
                    targets: liveEditingTargets
                )
            } catch {
                await recoverFromLiveEditingFailure(
                    title: "Live Editing Stopped",
                    error: error
                )
            }
        }
    }

    private func recoverFromLiveEditingFailure(
        title: String,
        error: Error
    ) async {
        do {
            try await liveEditingSession.stop()
            isLiveEditing = false
            presentedAlert = SceneEditorAlert(
                kind: .message,
                title: title,
                message:
                    "The live preview could not be updated, so its temporary holds were released. \(error.localizedDescription)"
            )
        } catch let cleanupError {
            isLiveEditing = true
            presentedAlert = SceneEditorAlert(
                kind: .message,
                title: "Live Editing Needs Attention",
                message:
                    "The live preview failed and HomeBase could not release every temporary hold. Keep this editor open and try turning Live Editing off again. Preview error: \(error.localizedDescription) Cleanup error: \(cleanupError.localizedDescription)"
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

        case .renameRollbackFailed:
            presentedAlert = SceneEditorAlert(
                kind: .conflict,
                title: "Scene File Rename Needs Attention",
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
