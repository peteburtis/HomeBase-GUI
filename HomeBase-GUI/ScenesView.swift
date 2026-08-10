//
//  ScenesView.swift
//  HomeBase-GUI
//

import Combine
import HomeBaseProtocol
import SwiftUI

struct ScenesView: View {
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var model: ServerScenesModel

    init(client: HomeBaseWebSocketClient) {
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
                        Toggle(
                            scene.name,
                            isOn: Binding(
                                get: {
                                    model.isPresented(
                                        sceneNamed: scene.name
                                    )
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
                        )
                        .tint(
                            model.isMatchedOnly(sceneNamed: scene.name)
                                ? .orange
                                : .accentColor
                        )
                        .disabled(
                            model.state != .live
                                || model.isUpdating(sceneNamed: scene.name)
                                || !model.canToggle(
                                    sceneNamed: scene.name
                                )
                        )
                        .accessibilityValue(
                            model.accessibilityValue(
                                sceneNamed: scene.name
                            )
                        )
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
            "No scenes are configured."
        case .failed:
            "Scenes could not be loaded."
        case .idle, .loading:
            "Scenes will appear when monitoring begins."
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

    private let client: HomeBaseWebSocketClient
    private var subscriptionID: UUID?

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
            actionError = "Could not update \(name): \(error.localizedDescription)"
        }
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
            scenes.sort(by: Self.sceneOrder)

        case .sceneRemoved:
            guard let scene = event.scene,
                  let index = index(ofSceneNamed: scene.name) else {
                return
            }
            scenes.remove(at: index)
            updatingSceneNames.remove(scene.name.lowercased())

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
