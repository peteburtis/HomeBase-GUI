//
//  TriggerOverviewView.swift
//  HomeBase-GUI
//

import Combine
import Foundation
import HomeBaseProtocol
import SwiftUI

struct TriggerOverviewView: View {
    @Environment(\.scenePhase) private var scenePhase

    private let triggerName: String
    private let client: HomeBaseWebSocketClient
    @StateObject private var model: TriggerOverviewModel

    init(triggerName: String, client: HomeBaseWebSocketClient) {
        self.triggerName = triggerName
        self.client = client
        _model = StateObject(
            wrappedValue: TriggerOverviewModel(
                triggerName: triggerName,
                client: client
            )
        )
    }

    var body: some View {
        Group {
            if let state = model.triggerState {
                overview(state)
            } else if case .failed(let message) = model.state {
                ContentUnavailableView {
                    Label(
                        "Trigger Could Not Be Loaded",
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") {
                        Task { await model.run(reactivating: true) }
                    }
                }
            } else {
                ProgressView("Loading trigger…")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(triggerName)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    TriggerConfigurationDetailView(
                        triggerName: triggerName,
                        client: client
                    )
                } label: {
                    Label("Edit Trigger", systemImage: "pencil.line")
                        .labelStyle(.iconOnly)
                }
                .disabled(model.state != .live)
            }
        }
        .connectionStatusOverlay(connectionStatus) {
            Task { await model.run(reactivating: true) }
        }
        .task(id: scenePhase) {
            if scenePhase == .active {
                await model.run(reactivating: true)
            } else {
                await model.stop()
            }
        }
    }

    private func overview(_ state: HBTriggerStateResult) -> some View {
        List {
            Section {
                TriggerOverviewTextRow(
                    label: "Mode",
                    value: TriggerModeUICatalog.registration(
                        for: state.trigger.mode
                    ).displayName
                )
                TriggerOverviewTextRow(
                    label: "State",
                    value: TriggerOverviewPresentation.stateLabel(
                        state.trigger.state
                    )
                )
                switch TriggerOverviewPresentation.lastFired(
                    for: state.trigger
                ) {
                case .omitted:
                    EmptyView()
                case .never:
                    TriggerOverviewTextRow(
                        label: "Last fired",
                        value: "Never"
                    )
                case .date(let lastFiredAt):
                    LabeledContent("Last fired") {
                        Text(lastFiredAt, style: .relative)
                    }
                }
                if !state.trigger.schedulerRunning {
                    Label("Trigger scheduler is paused", systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                }
                if !state.trigger.valid {
                    Label(
                        "One or more conditions are invalid",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                }
            } header: {
                Text("Trigger")
            }

            Section {
                if state.conditions.isEmpty {
                    Text("This trigger has no conditions.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(
                        TriggerOverviewPresentation.flatten(state.conditions)
                    ) { condition in
                        TriggerConditionOverviewRow(condition: condition)
                    }
                }
            } header: {
                Text("Conditions")
            }

            Section {
                switch model.configurationState {
                case .idle, .loading:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading actions…")
                            .foregroundStyle(.secondary)
                    }

                case .loaded(let trigger):
                    if trigger.actions.isEmpty {
                        Text("This trigger contains no actions.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(trigger.actions) { action in
                            TriggerActionOverviewRow(action: action)
                        }
                    }

                case .failed(let message):
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Actions could not be loaded.")
                            .foregroundStyle(.secondary)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Try Again") {
                            Task { await model.reloadConfiguration() }
                        }
                    }
                }
            } header: {
                Text("Actions")
            }

            if case .loaded(let trigger) = model.configurationState {
                Section {
                    TriggerOverviewTextRow(
                        label: "File",
                        value: trigger.source.path,
                        monospaced: true
                    )
                    TriggerOverviewTextRow(
                        label: "JSON location",
                        value: trigger.jsonPath,
                        monospaced: true
                    )
                    ForEach(trigger.additionalFields, id: \.key) { field in
                        TriggerOverviewTextRow(
                            label: field.key,
                            value: field.value.compactConfigurationJSON,
                            monospaced: true
                        )
                    }
                } header: {
                    Text("Source")
                }
            }
        }
        .refreshable {
            await model.reloadConfiguration()
        }
    }

    private var connectionStatus: ConnectionStatusPresentation {
        switch model.state {
        case .idle:
            .disconnected("Not Monitoring", systemImage: "pause.circle")
        case .loading:
            .pending("Loading trigger…")
        case .live:
            .connected
        case .failed(let message):
            .failed(title: "Monitoring Failed", message: message)
        }
    }
}

private struct TriggerOverviewTextRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .font(monospaced ? .body.monospaced() : .body)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

private struct TriggerConditionOverviewRow: View {
    let condition: TriggerOverviewCondition

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(condition.title)
                if let detail = condition.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(.leading, CGFloat(condition.depth) * 16)

            Spacer(minLength: 8)

            Image(systemName: condition.systemImage)
                .font(.system(size: 30, weight: .regular))
                .frame(width: 32, height: 32)
                .foregroundStyle(condition.color)
                .accessibilityLabel(condition.accessibilityLabel)
        }
    }
}

private struct TriggerActionOverviewRow: View {
    let action: SceneActionConfiguration

    private var presentation: AutomationActionPluginPresentation {
        AutomationActionTypeRegistry.standard.resolve(action).plugin
            .presentation(for: action)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(presentation.title)
            if let detail = presentation.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
    }
}

struct TriggerOverviewCondition: Identifiable, Equatable {
    let descriptor: HBTriggerConditionDescriptor
    let depth: Int

    var id: String { descriptor.path }

    var title: String {
        TriggerConditionTypeRegistry.standard
            .presentation(for: descriptor)
            .title
    }

    var detail: String? {
        TriggerConditionTypeRegistry.standard
            .presentation(for: descriptor)
            .detail
    }

    var systemImage: String {
        switch descriptor.status {
        case .invalid:
            "exclamationmark.circle.fill"
        case .satisfied:
            "checkmark.circle"
        case .unsatisfied:
            "circle"
        }
    }

    var color: AnyShapeStyle {
        switch descriptor.status {
        case .invalid:
            AnyShapeStyle(Color.red)
        case .satisfied:
            AnyShapeStyle(Color.green)
        case .unsatisfied:
            AnyShapeStyle(.tertiary)
        }
    }

    var accessibilityLabel: String {
        switch descriptor.status {
        case .invalid:
            descriptor.trueWhileInvalid
                ? "Invalid, treated as true"
                : "Invalid"
        case .satisfied:
            "True"
        case .unsatisfied:
            "False"
        }
    }
}

enum TriggerOverviewPresentation {
    enum LastFired: Equatable {
        case omitted
        case never
        case date(Date)
    }

    static func lastFired(
        for trigger: HBTriggerSummaryDescriptor
    ) -> LastFired {
        guard TriggerModeUICatalog.registration(for: trigger.mode)
            .showsLastFired else { return .omitted }
        return trigger.lastFiredAt.map(LastFired.date) ?? .never
    }

    static func flatten(
        _ conditions: [HBTriggerConditionDescriptor]
    ) -> [TriggerOverviewCondition] {
        var result: [TriggerOverviewCondition] = []
        func append(_ condition: HBTriggerConditionDescriptor, depth: Int) {
            result.append(
                TriggerOverviewCondition(
                    descriptor: condition,
                    depth: depth
                )
            )
            condition.children.forEach { append($0, depth: depth + 1) }
        }
        conditions.forEach { append($0, depth: 0) }
        return result
    }

    static func stateLabel(_ state: HBTriggerActivityState) -> String {
        switch state {
        case .inactive: "Inactive"
        case .satisfied: "Satisfied"
        case .active: "Active"
        }
    }

    static func conditionSummary(
        _ condition: HBTriggerConditionDescriptor
    ) -> String? {
        TriggerConditionTypeRegistry.standard
            .presentation(for: condition)
            .detail
    }

    private static func truncated(_ value: String) -> String {
        guard value.count > 220 else { return value }
        return String(value.prefix(217)) + "…"
    }
}

@MainActor
private final class TriggerOverviewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case live
        case failed(String)
    }

    enum ConfigurationState: Equatable {
        case idle
        case loading
        case loaded(TriggerConfigurationDocument)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var triggerState: HBTriggerStateResult?
    @Published private(set) var configurationState: ConfigurationState = .idle

    private let triggerName: String
    private let client: HomeBaseWebSocketClient
    private let repository: TriggerConfigurationRepository
    private var subscriptionID: UUID?
    private var runGeneration: UUID?
    private var configurationTask: Task<Void, Never>?

    init(triggerName: String, client: HomeBaseWebSocketClient) {
        self.triggerName = triggerName
        self.client = client
        repository = TriggerConfigurationRepository(client: client)
    }

    func run(reactivating: Bool = false) async {
        guard state != .loading, state != .live else { return }
        let generation = UUID()
        runGeneration = generation
        state = .loading
        var ownedSubscriptionID: UUID?

        do {
            if reactivating {
                try await client.reactivate()
            } else {
                try await client.connect()
            }

            let subscription = try await client.subscribeToTriggers(
                scope: .triggers,
                detail: .conditions,
                triggerNames: [triggerName]
            )
            ownedSubscriptionID = subscription.identifier
            if Task.isCancelled || runGeneration != generation {
                try? await client.cancelSubscription(subscription.identifier)
                throw CancellationError()
            }
            guard let initial = subscription.triggers.first else {
                throw TriggerConfigurationLoadingError(
                    message: "HomeBase did not return the selected trigger."
                )
            }
            subscriptionID = subscription.identifier
            triggerState = initial
            state = .live
            beginLoadingConfiguration(generation: generation)

            for try await event in subscription.events {
                try Task.checkCancellation()
                apply(event)
            }

            if Task.isCancelled, runGeneration == generation {
                state = .idle
            } else if runGeneration == generation, state == .live {
                state = .failed("The live subscription ended.")
            }
        } catch is CancellationError {
            if runGeneration == generation {
                state = .idle
            }
        } catch {
            if runGeneration == generation {
                state = .failed(error.localizedDescription)
            }
        }

        if let ownedSubscriptionID {
            await stopSubscription(ownedSubscriptionID)
        }
        if runGeneration == generation {
            runGeneration = nil
        }
    }

    func stop() async {
        runGeneration = nil
        configurationTask?.cancel()
        configurationTask = nil
        state = .idle
        guard let subscriptionID else { return }
        self.subscriptionID = nil
        try? await client.cancelSubscription(subscriptionID)
    }

    func reloadConfiguration() async {
        configurationTask?.cancel()
        configurationState = .loading
        do {
            let trigger = try await repository.loadTrigger(named: triggerName)
            try Task.checkCancellation()
            configurationState = .loaded(trigger)
        } catch is CancellationError {
            return
        } catch {
            configurationState = .failed(error.localizedDescription)
        }
    }

    private func beginLoadingConfiguration(generation: UUID) {
        configurationTask?.cancel()
        configurationState = .loading
        configurationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let trigger = try await repository.loadTrigger(
                    named: triggerName
                )
                try Task.checkCancellation()
                guard runGeneration == generation else { return }
                configurationState = .loaded(trigger)
            } catch is CancellationError {
                return
            } catch {
                guard runGeneration == generation else { return }
                configurationState = .failed(error.localizedDescription)
            }
        }
    }

    private func apply(_ event: HBTriggerWatchStreamEvent) {
        switch event.kind {
        case .change, .triggerAdded, .fired:
            guard let updated = event.trigger,
                  updated.trigger.name.caseInsensitiveCompare(triggerName)
                    == .orderedSame else { return }
            triggerState = updated

        case .triggerRemoved:
            guard event.trigger?.trigger.name.caseInsensitiveCompare(
                triggerName
            ) == .orderedSame else { return }
            state = .failed("This trigger is no longer loaded.")

        case .heartbeat:
            break
        }
    }

    private func stopSubscription(_ identifier: UUID) async {
        if subscriptionID == identifier {
            subscriptionID = nil
        }
        try? await client.cancelSubscription(identifier)
    }
}
