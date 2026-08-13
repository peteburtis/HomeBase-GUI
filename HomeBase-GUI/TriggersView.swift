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
                            triggerRow(trigger)
                        }
                    } header: {
                        Text("Active & Satisfied")
                    }
                }

                if !inactiveTriggers.isEmpty {
                    Section {
                        ForEach(inactiveTriggers, id: \.name) { trigger in
                            triggerRow(trigger)
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
    private func triggerRow(_ trigger: HBTriggerSummaryDescriptor) -> some View {
        NavigationLink {
            TriggerOverviewView(
                triggerName: trigger.name,
                client: client
            )
        } label: {
            TriggerRowLabel(trigger: trigger)
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
                            TriggerRowLabel(trigger: trigger)
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

            TriggerStatusAccessory(trigger: trigger)
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            VStack(alignment: .trailing, spacing: 4) {
                Image(systemName: statusSystemImage)
                    .font(.system(size: 30, weight: .regular))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(statusStyle(at: context.date))
                    .accessibilityLabel(statusAccessibilityLabel)

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

    private func statusStyle(at date: Date) -> AnyShapeStyle {
        if !trigger.enabled {
            return AnyShapeStyle(.secondary)
        }
        if !trigger.schedulerRunning {
            return AnyShapeStyle(Color.orange)
        }
        switch trigger.state {
        case .inactive:
            return AnyShapeStyle(.tertiary)
        case .satisfied:
            return AnyShapeStyle(
                firedWithinLastMinute(at: date) ? Color.green : Color.orange
            )
        case .active:
            return AnyShapeStyle(Color.green)
        }
    }

    private func firedWithinLastMinute(at date: Date) -> Bool {
        guard let lastFiredAt = trigger.lastFiredAt else { return false }
        return (0...60).contains(date.timeIntervalSince(lastFiredAt))
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

    private let client: HomeBaseWebSocketClient
    private var subscriptionID: UUID?
    private var runGeneration: UUID?

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
