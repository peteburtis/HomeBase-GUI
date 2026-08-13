//
//  TriggersView.swift
//  HomeBase-GUI
//

import Combine
import Foundation
import HomeBaseProtocol
import SwiftUI

struct TriggersView: View {
    @Environment(\.scenePhase) private var scenePhase

    private let client: HomeBaseWebSocketClient
    @StateObject private var model: ServerTriggersModel

    init(client: HomeBaseWebSocketClient) {
        self.client = client
        _model = StateObject(
            wrappedValue: ServerTriggersModel(client: client)
        )
    }

    var body: some View {
        List {
            if model.triggers.isEmpty {
                Section {
                    Text(emptyTriggersMessage)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Triggers")
                }
            } else {
                if !activeTriggers.isEmpty {
                    Section {
                        ForEach(activeTriggers, id: \.name) { trigger in
                            triggerRow(
                                trigger,
                                firedAt: model.recentFireDate(for: trigger.name)
                            )
                        }
                    } header: {
                        Text("Active & Satisfied")
                    }
                }

                if !inactiveTriggers.isEmpty {
                    Section {
                        ForEach(inactiveTriggers, id: \.name) { trigger in
                            triggerRow(
                                trigger,
                                firedAt: model.recentFireDate(for: trigger.name)
                            )
                        }
                    } header: {
                        Text("Inactive")
                    }
                }

                if !hiddenTriggers.isEmpty {
                    Section("Hidden") {
                        NavigationLink {
                            HiddenTriggersView(client: client)
                        } label: {
                            HiddenItemsRowLabel(
                                title: "Hidden Triggers",
                                count: hiddenTriggers.count
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle("Triggers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    TriggerConfigurationDetailView(
                        newTriggerIdentifier: suggestedNewTriggerIdentifier,
                        client: client
                    )
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(model.state != .live)
                .accessibilityLabel("Create Trigger")
            }
        }
        .connectionStatusOverlay(connectionStatus) {
            Task {
                await model.run()
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active {
                await model.run(reactivating: true)
            } else {
                await model.stop()
            }
        }
        .onDisappear {
            Task {
                await model.stop()
            }
        }
    }

    private var activeTriggers: [HBTriggerSummaryDescriptor] {
        visibleTriggers.filter { trigger in
            switch trigger.state {
            case .active, .satisfied:
                true
            case .inactive:
                false
            }
        }
    }

    private var inactiveTriggers: [HBTriggerSummaryDescriptor] {
        visibleTriggers.filter { $0.state == .inactive }
    }

    private var visibleTriggers: [HBTriggerSummaryDescriptor] {
        model.triggers.filter { !$0.metadata.hasHiddenFlag }
    }

    private var hiddenTriggers: [HBTriggerSummaryDescriptor] {
        model.triggers.filter { $0.metadata.hasHiddenFlag }
    }

    @ViewBuilder
    private func triggerRow(
        _ trigger: HBTriggerSummaryDescriptor,
        firedAt: Date?
    ) -> some View {
        NavigationLink {
            TriggerOverviewView(
                triggerName: trigger.name,
                client: client
            )
        } label: {
            TriggerRowLabel(trigger: trigger, firedAt: firedAt)
        }
        .id(trigger.name)
    }

    private var connectionStatus: ConnectionStatusPresentation {
        switch model.state {
        case .idle:
            .disconnected("Not Monitoring", systemImage: "pause.circle")

        case .loading:
            .pending("Loading triggers…")

        case .live:
            .connected

        case .failed(let message):
            .failed(title: "Monitoring Failed", message: message)
        }
    }

    private var emptyTriggersMessage: String {
        switch model.state {
        case .live:
            "No triggers are configured. Tap + to create one."
        case .failed:
            "Triggers could not be loaded."
        case .idle, .loading:
            "Triggers will appear when monitoring begins."
        }
    }

    private var suggestedNewTriggerIdentifier: String {
        let existing = Set(model.triggers.map { $0.name.lowercased() })
        let base = "UntitledTrigger"
        guard existing.contains(base.lowercased()) else { return base }

        var suffix = 2
        while existing.contains("\(base)\(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(base)\(suffix)"
    }

}

private struct HiddenTriggersView: View {
    @Environment(\.scenePhase) private var scenePhase

    private let client: HomeBaseWebSocketClient
    @StateObject private var model: ServerTriggersModel

    init(client: HomeBaseWebSocketClient) {
        self.client = client
        _model = StateObject(wrappedValue: ServerTriggersModel(client: client))
    }

    var body: some View {
        List {
            Section("Triggers") {
                if hiddenTriggers.isEmpty {
                    Text(emptyMessage)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hiddenTriggers, id: \.name) { trigger in
                        NavigationLink {
                            TriggerOverviewView(
                                triggerName: trigger.name,
                                client: client
                            )
                        } label: {
                            TriggerRowLabel(
                                trigger: trigger,
                                firedAt: model.recentFireDate(
                                    for: trigger.name
                                )
                            )
                        }
                        .id(trigger.name)
                    }
                }
            }
        }
        .navigationTitle("Hidden Triggers")
        .connectionStatusOverlay(connectionStatus) {
            Task { await model.run() }
        }
        .task(id: scenePhase) {
            if scenePhase == .active {
                await model.run(reactivating: true)
            } else {
                await model.stop()
            }
        }
        .onDisappear {
            Task { await model.stop() }
        }
    }

    private var hiddenTriggers: [HBTriggerSummaryDescriptor] {
        model.triggers.filter { $0.metadata.hasHiddenFlag }
    }

    private var emptyMessage: String {
        switch model.state {
        case .live:
            "No triggers are currently hidden."
        case .failed:
            "Hidden triggers could not be loaded."
        case .idle, .loading:
            "Hidden triggers will appear when monitoring begins."
        }
    }

    private var connectionStatus: ConnectionStatusPresentation {
        switch model.state {
        case .idle:
            .disconnected("Not Monitoring", systemImage: "pause.circle")
        case .loading:
            .pending("Loading hidden triggers…")
        case .live:
            .connected
        case .failed(let message):
            .failed(title: "Monitoring Failed", message: message)
        }
    }
}

private struct TriggerRowLabel: View {
    let trigger: HBTriggerSummaryDescriptor
    let firedAt: Date?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(trigger.name)
                    .foregroundStyle(.primary)
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            TriggerStatusAccessory(trigger: trigger, firedAt: firedAt)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: Text {
        let modeName = TriggerModeUICatalog.registration(for: trigger.mode)
            .displayName
        switch TriggerOverviewPresentation.lastFired(for: trigger) {
        case .omitted:
            return Text(modeName)
        case .never:
            return Text("\(modeName) • Never fired")
        case .date(let lastFiredAt):
            return Text(
                "\(modeName) • Last fired \(lastFiredAt, style: .relative)"
            )
        }
    }
}

private struct TriggerStatusAccessory: View {
    let trigger: HBTriggerSummaryDescriptor
    let firedAt: Date?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ZStack {
                Image(systemName: statusSystemImage)
                    .font(.system(size: 30, weight: .regular))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(statusStyle)
                    .accessibilityLabel(statusAccessibilityLabel)

                if let firedAt, trigger.state != .active,
                   trigger.enabled, trigger.schedulerRunning {
                    TriggerFiredPulse(firedAt: firedAt)
                }
            }

            if !trigger.valid {
                Label(
                    "Invalid",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.red)
            }
        }
        .font(.caption)
    }

    private var statusAccessibilityLabel: String {
        if !trigger.enabled {
            return "Disabled"
        }
        if !trigger.schedulerRunning {
            return "Paused"
        }
        switch trigger.state {
        case .inactive:
            return "Inactive"
        case .satisfied:
            return "Satisfied"
        case .active:
            return "Active"
        }
    }

    private var statusSystemImage: String {
        if !trigger.enabled {
            return "slash.circle"
        }
        if !trigger.schedulerRunning {
            return "pause.circle.fill"
        }
        switch trigger.state {
        case .inactive:
            return "circle"
        case .satisfied:
            return "checkmark.circle"
        case .active:
            return "checkmark.circle.fill"
        }
    }

    private var statusStyle: AnyShapeStyle {
        if !trigger.enabled {
            return AnyShapeStyle(.secondary)
        }
        if !trigger.schedulerRunning {
            return AnyShapeStyle(.secondary)
        }
        switch trigger.state {
        case .inactive:
            return AnyShapeStyle(.tertiary)
        case .satisfied:
            return AnyShapeStyle(Color.green)
        case .active:
            return AnyShapeStyle(Color.green)
        }
    }
}

private struct TriggerFiredPulse: View {
    let firedAt: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30, weight: .regular))
                .frame(width: 32, height: 32)
                .foregroundStyle(Color.green)
                .opacity(
                    TriggerFiredPulsePresentation.opacity(
                        elapsed: context.date.timeIntervalSince(firedAt)
                    )
                )
                .accessibilityHidden(true)
        }
    }
}

enum TriggerFiredPulsePresentation {
    static let fadeInDuration: TimeInterval = 0.15
    static let totalDuration: TimeInterval = 5

    static func opacity(elapsed: TimeInterval) -> Double {
        guard elapsed >= 0, elapsed < totalDuration else { return 0 }
        if elapsed < fadeInDuration {
            return elapsed / fadeInDuration
        }
        return 1 - (elapsed - fadeInDuration)
            / (totalDuration - fadeInDuration)
    }
}

@MainActor
private final class ServerTriggersModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case live
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var triggers: [HBTriggerSummaryDescriptor] = []
    @Published private(set) var recentFireDates: [String: Date] = [:]

    private let client: HomeBaseWebSocketClient
    private var subscriptionID: UUID?
    private var runGeneration: UUID?
    private var fireExpirationTasks: [String: Task<Void, Never>] = [:]

    init(client: HomeBaseWebSocketClient) {
        self.client = client
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

            let subscription = try await client.subscribeToTriggers()
            ownedSubscriptionID = subscription.identifier
            if Task.isCancelled || runGeneration != generation {
                try? await client.cancelSubscription(
                    subscription.identifier
                )
                throw CancellationError()
            }
            subscriptionID = subscription.identifier
            install(subscription.triggers)
            state = .live

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
        state = .idle
        clearRecentFires()
        guard let subscriptionID else { return }
        self.subscriptionID = nil
        try? await client.cancelSubscription(subscriptionID)
    }

    private func install(_ results: [HBTriggerStateResult]) {
        var installed: [HBTriggerSummaryDescriptor] = []
        for result in results {
            let trigger = result.trigger
            if let index = Self.index(
                ofTriggerNamed: trigger.name,
                in: installed
            ) {
                installed[index] = trigger
            } else {
                installed.append(trigger)
            }
        }
        installed.sort(by: Self.triggerOrder)
        triggers = installed
    }

    private func apply(_ event: HBTriggerWatchStreamEvent) {
        switch event.kind {
        case .change, .triggerAdded, .fired:
            guard let trigger = event.trigger?.trigger else { return }
            if event.kind == .fired {
                recordFire(for: trigger.name)
            }
            var updated = triggers
            if let index = Self.index(
                ofTriggerNamed: trigger.name,
                in: updated
            ) {
                updated[index] = trigger
            } else {
                updated.append(trigger)
            }
            updated.sort(by: Self.triggerOrder)
            withAnimation(.default) {
                triggers = updated
            }

        case .triggerRemoved:
            guard let name = event.trigger?.trigger.name else { return }
            removeRecentFire(for: name)
            var updated = triggers
            updated.removeAll(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            })
            withAnimation(.default) {
                triggers = updated
            }

        case .heartbeat:
            break
        }
    }

    func recentFireDate(for triggerName: String) -> Date? {
        recentFireDates[Self.normalizedName(triggerName)]
    }

    private func recordFire(for triggerName: String) {
        let name = Self.normalizedName(triggerName)
        let firedAt = Date.now
        fireExpirationTasks[name]?.cancel()
        recentFireDates[name] = firedAt
        fireExpirationTasks[name] = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: .seconds(
                        TriggerFiredPulsePresentation.totalDuration
                    )
                )
            } catch {
                return
            }
            guard let self,
                  recentFireDates[name] == firedAt else { return }
            recentFireDates.removeValue(forKey: name)
            fireExpirationTasks.removeValue(forKey: name)
        }
    }

    private func removeRecentFire(for triggerName: String) {
        let name = Self.normalizedName(triggerName)
        fireExpirationTasks.removeValue(forKey: name)?.cancel()
        recentFireDates.removeValue(forKey: name)
    }

    private func clearRecentFires() {
        fireExpirationTasks.values.forEach { $0.cancel() }
        fireExpirationTasks.removeAll()
        recentFireDates.removeAll()
    }

    nonisolated private static func normalizedName(_ name: String) -> String {
        name.lowercased()
    }

    private func index(ofTriggerNamed name: String) -> Int? {
        Self.index(ofTriggerNamed: name, in: triggers)
    }

    private static func index(
        ofTriggerNamed name: String,
        in triggers: [HBTriggerSummaryDescriptor]
    ) -> Int? {
        triggers.firstIndex(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        })
    }

    private static func triggerOrder(
        _ lhs: HBTriggerSummaryDescriptor,
        _ rhs: HBTriggerSummaryDescriptor
    ) -> Bool {
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.name < rhs.name
    }

    private func stopSubscription(_ identifier: UUID) async {
        if subscriptionID == identifier {
            subscriptionID = nil
        }
        try? await client.cancelSubscription(identifier)
    }
}
