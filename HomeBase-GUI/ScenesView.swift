//
//  ScenesView.swift
//  HomeBase-GUI
//

import Combine
import Foundation
import HomeBaseProtocol
import SwiftUI

struct ScenesView: View {
    @Environment(\.scenePhase) private var scenePhase

    private let client: HomeBaseWebSocketClient
    @StateObject private var model: ServerScenesModel
    @State private var isEditingScenes = false

    init(client: HomeBaseWebSocketClient) {
        self.client = client
        _model = StateObject(
            wrappedValue: ServerScenesModel(client: client)
        )
    }

    var body: some View {
        List {
            Section {
                if model.scenes.isEmpty {
                    Text(emptyScenesMessage)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.scenes, id: \.name) { scene in
                        sceneRow(scene)
                    }
                }

                if let actionError = model.actionError {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            actionError,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Scenes")
            }
        }
        .navigationTitle("Scenes")
        .toolbar {
            if isEditingScenes {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        SceneConfigurationDetailView(
                            newSceneIdentifier: suggestedNewSceneIdentifier,
                            client: client
                        )
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(model.state != .live)
                    .accessibilityLabel("Create Scene")
                    .transition(.scale.combined(with: .opacity))
                }

                ToolbarSpacer(.fixed, placement: .primaryAction)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isEditingScenes.toggle()
                    }
                } label: {
                    Text(isEditingScenes ? "Done" : "Edit")
                        .contentTransition(.opacity)
                }
                .disabled(model.state != .live)
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

    @ViewBuilder
    private func sceneRow(_ scene: HBSceneStateResult) -> some View {
        if isEditingScenes {
            NavigationLink {
                SceneConfigurationDetailView(
                    sceneName: scene.name,
                    client: client
                )
            } label: {
                Text(scene.name)
            }
            .transition(.opacity)
        } else {
            Toggle(
                isOn: Binding(
                    get: {
                        model.isPresented(sceneNamed: scene.name)
                    },
                    set: { isActive in
                        Task {
                            await model.setScene(
                                named: scene.name,
                                active: isActive
                            )
                        }
                    }
                )
            ) {
                HStack(spacing: 8) {
                    Text(scene.name)
                    Spacer(minLength: 8)
                    SceneActivationAccessory(
                        countdownDeadline: model.activationDeadline(
                            sceneNamed: scene.name
                        ),
                        priority: model.activePriority(
                            sceneNamed: scene.name
                        )
                    )
                }
            }
            .tint(
                model.isMatchedOnly(sceneNamed: scene.name)
                    ? .orange
                    : .accentColor
            )
            .disabled(
                model.state != .live
                    || model.isUpdating(sceneNamed: scene.name)
                    || !model.canToggle(sceneNamed: scene.name)
            )
            .accessibilityValue(
                model.accessibilityValue(sceneNamed: scene.name)
            )
            .transition(.opacity)
        }
    }

    private var connectionStatus: ConnectionStatusPresentation {
        switch model.state {
        case .idle:
            .disconnected("Not Monitoring", systemImage: "pause.circle")

        case .loading:
            .pending("Loading scenes…")

        case .live:
            .connected

        case .failed(let message):
            .failed(title: "Monitoring Failed", message: message)
        }
    }

    private var emptyScenesMessage: String {
        switch model.state {
        case .live:
            isEditingScenes
                ? "No scenes are configured. Tap + to create one."
                : "No scenes are configured."
        case .failed:
            "Scenes could not be loaded."
        case .idle, .loading:
            "Scenes will appear when monitoring begins."
        }
    }

    private var suggestedNewSceneIdentifier: String {
        let existing = Set(model.scenes.map { $0.name.lowercased() })
        let base = "UntitledScene"
        guard existing.contains(base.lowercased()) else { return base }

        var suffix = 2
        while existing.contains("\(base)\(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(base)\(suffix)"
    }
}

private struct SceneActivationAccessory: View {
    private static let userPriority = Int(Int32.max)
    private static let userPriorityLabel = "P-User"

    let countdownDeadline: Date?
    let priority: Int?

    @State private var now = Date()

    var body: some View {
        Group {
            if remainingSeconds > 0 {
                Text(countdownText)
                    .accessibilityLabel(
                        "\(remainingSeconds) seconds remaining"
                    )
            } else if let priority {
                Text(priorityText(priority))
                    .accessibilityLabel(priorityAccessibilityText(priority))
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .task(id: countdownDeadline) {
            await runCountdown()
        }
    }

    private var remainingSeconds: Int {
        guard let countdownDeadline else { return 0 }
        return max(
            0,
            Int(ceil(countdownDeadline.timeIntervalSince(now)))
        )
    }

    private var countdownText: String {
        String(
            format: "%d:%02d",
            remainingSeconds / 60,
            remainingSeconds % 60
        )
    }

    private func priorityText(_ priority: Int) -> String {
        priority == Self.userPriority
            ? Self.userPriorityLabel
            : "P-\(priority)"
    }

    private func priorityAccessibilityText(_ priority: Int) -> String {
        priority == Self.userPriority
            ? "User priority"
            : "Priority \(priority)"
    }

    private func runCountdown() async {
        now = Date()
        guard let countdownDeadline else { return }
        while !Task.isCancelled, countdownDeadline > now {
            do {
                try await Task<Never, Never>.sleep(for: .seconds(1))
            } catch {
                return
            }
            now = Date()
        }
    }
}

@MainActor
private final class ServerScenesModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case live
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var scenes: [HBSceneStateResult] = []
    @Published private(set) var updatingSceneNames: Set<String> = []
    @Published private(set) var actionError: String?
    @Published private var optimisticPresentation: [String: Bool] = [:]
    @Published private var activationDeadlines: [String: Date] = [:]

    private let client: HomeBaseWebSocketClient
    private var subscriptionID: UUID?
    private var activationDurations: [String: TimeInterval] = [:]

    init(client: HomeBaseWebSocketClient) {
        self.client = client
    }

    func run(reactivating: Bool = false) async {
        guard state != .loading, state != .live else { return }
        state = .loading
        actionError = nil

        do {
            if reactivating {
                try await client.reactivate()
            } else {
                try await client.connect()
            }

            let subscription = try await client.subscribeToScenes()
            if Task.isCancelled {
                try? await client.cancelSubscription(
                    subscription.identifier
                )
                throw CancellationError()
            }
            subscriptionID = subscription.identifier
            let sceneDefinitions = (try? await client.listScenes()) ?? []
            try Task.checkCancellation()
            installDefinitions(sceneDefinitions)
            install(subscription.scenes)
            state = .live

            for try await event in subscription.events {
                try Task.checkCancellation()
                apply(event)
            }

            if Task.isCancelled {
                state = .idle
            } else if state == .live {
                state = .failed("The live subscription ended.")
            }
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }

        await stopSubscription()
    }

    func stop() async {
        state = .idle
        await stopSubscription()
    }

    func isPresented(sceneNamed name: String) -> Bool {
        let normalizedName = name.lowercased()
        if let optimistic = optimisticPresentation[normalizedName] {
            return optimistic
        }
        return scene(named: name)?.isPresented ?? false
    }

    func isMatchedOnly(sceneNamed name: String) -> Bool {
        scene(named: name)?.isMatchedOnly ?? false
    }

    func canToggle(sceneNamed name: String) -> Bool {
        guard let scene = scene(named: name) else { return false }
        return !scene.isMatchedOnly || scene.matchedDismissible
    }

    func accessibilityValue(sceneNamed name: String) -> String {
        guard let scene = scene(named: name) else { return "Off" }
        if scene.isActive {
            return "Active"
        }
        if scene.isMatchedOnly {
            return scene.matchedDismissible
                ? "Matched and dismissible"
                : "Matched and cannot be dismissed"
        }
        return "Off"
    }

    func isUpdating(sceneNamed name: String) -> Bool {
        updatingSceneNames.contains(name.lowercased())
    }

    func activationDeadline(sceneNamed name: String) -> Date? {
        activationDeadlines[name.lowercased()]
    }

    func activePriority(sceneNamed name: String) -> Int? {
        guard let scene = scene(named: name), scene.isActive else {
            return nil
        }
        return scene.owners.map(\.priority).max()
    }

    func setScene(named name: String, active: Bool) async {
        let normalizedName = name.lowercased()
        guard state == .live,
              let sceneIndex = index(ofSceneNamed: name) else {
            return
        }
        guard updatingSceneNames.insert(normalizedName).inserted else {
            return
        }

        let scene = scenes[sceneIndex]
        let dismissMatchedScene = !active && scene.isMatchedOnly
        guard !dismissMatchedScene || scene.matchedDismissible else {
            updatingSceneNames.remove(normalizedName)
            return
        }

        updateActivationCountdown(
            sceneNamed: name,
            activating: active
        )
        optimisticPresentation[normalizedName] = active
        actionError = nil

        defer {
            optimisticPresentation.removeValue(forKey: normalizedName)
            updatingSceneNames.remove(normalizedName)
        }

        do {
            let result = try await client.setScene(
                named: name,
                active: active,
                allowMatchedDismissal: dismissMatchedScene
            )
            guard let updatedIndex = index(ofSceneNamed: result.name) else {
                return
            }
            scenes[updatedIndex] = result
        } catch {
            activationDeadlines.removeValue(forKey: normalizedName)
            actionError = "Could not update \(name): \(error.localizedDescription)"
        }
    }

    private func installDefinitions(_ definitions: [HBSceneDescriptor]) {
        activationDurations.removeAll(keepingCapacity: true)
        for definition in definitions {
            guard let timing = definition.timing else { continue }
            let duration = max(0, timing.delay) + max(0, timing.duration)
            guard duration.isFinite else { continue }
            activationDurations[definition.name.lowercased()] = duration
        }
    }

    private func updateActivationCountdown(
        sceneNamed name: String,
        activating: Bool
    ) {
        let normalizedName = name.lowercased()
        guard activating,
              let duration = activationDurations[normalizedName],
              duration > 5 else {
            activationDeadlines.removeValue(forKey: normalizedName)
            return
        }
        activationDeadlines[normalizedName] = Date()
            .addingTimeInterval(duration)
    }

    private func install(_ scenes: [HBSceneStateResult]) {
        self.scenes = scenes.sorted(by: Self.sceneOrder)
    }

    private func apply(_ event: HBSceneWatchStreamEvent) {
        switch event.kind {
        case .change, .sceneAdded:
            guard let scene = event.scene else { return }
            if let index = index(ofSceneNamed: scene.name) {
                scenes[index] = scene
            } else {
                scenes.append(scene)
            }
            if !scene.isActive {
                activationDeadlines.removeValue(
                    forKey: scene.name.lowercased()
                )
            }
            scenes.sort(by: Self.sceneOrder)

        case .sceneRemoved:
            guard let scene = event.scene,
                  let index = index(ofSceneNamed: scene.name) else {
                return
            }
            scenes.remove(at: index)
            updatingSceneNames.remove(scene.name.lowercased())
            activationDeadlines.removeValue(
                forKey: scene.name.lowercased()
            )

        case .heartbeat:
            break
        }
    }

    private func index(ofSceneNamed name: String) -> Int? {
        scenes.firstIndex(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        })
    }

    private func scene(named name: String) -> HBSceneStateResult? {
        scenes.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        })
    }

    private static func sceneOrder(
        _ lhs: HBSceneStateResult,
        _ rhs: HBSceneStateResult
    ) -> Bool {
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.name < rhs.name
    }

    private func stopSubscription() async {
        guard let subscriptionID else { return }
        self.subscriptionID = nil
        try? await client.cancelSubscription(subscriptionID)
    }
}

private extension HBSceneStateResult {
    var isPresented: Bool {
        isActive || application.status == .applied
    }

    var isMatchedOnly: Bool {
        !isActive && application.status == .applied
    }
}
