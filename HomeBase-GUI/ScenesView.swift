//
//  ScenesView.swift
//  HomeBase-GUI
//

import Combine
import HomeBaseProtocol
import SwiftUI

struct ScenesView: View {
    @Environment(\.scenePhase) private var scenePhase

    let server: PairedServer
    @StateObject private var model: ServerScenesModel

    init(
        server: PairedServer,
        client: HomeBaseWebSocketClient
    ) {
        self.server = server
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
                                    model.isActive(sceneNamed: scene.name)
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
                        .disabled(
                            model.state != .live
                                || model.isUpdating(sceneNamed: scene.name)
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
            } footer: {
                connectionStatus
            }
        }
        .navigationTitle(server.endpoint.host)
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
    private var connectionStatus: some View {
        switch model.state {
        case .idle:
            Label("Not Monitoring", systemImage: "pause.circle")
                .foregroundStyle(.secondary)

        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Loading scenes…")
            }
            .foregroundStyle(.secondary)

        case .live:
            Label(
                "Connected",
                systemImage: "dot.radiowaves.left.and.right"
            )
            .foregroundStyle(.green)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 5) {
                Label(
                    "Monitoring Failed",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.red)
                Button("Try Again") {
                    Task {
                        await model.run()
                    }
                }
            }
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

    func isActive(sceneNamed name: String) -> Bool {
        scenes.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        })?.isActive ?? false
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

        let previousState = scenes[sceneIndex].isActive
        scenes[sceneIndex].isActive = active
        actionError = nil

        defer {
            updatingSceneNames.remove(normalizedName)
        }

        do {
            let result = try await client.setScene(
                named: name,
                active: active
            )
            guard let updatedIndex = index(ofSceneNamed: result.name) else {
                return
            }
            scenes[updatedIndex].isActive = result.isActive
            scenes[updatedIndex].discoveredActivation =
                result.discoveredActivation
        } catch {
            if let currentIndex = index(ofSceneNamed: name) {
                scenes[currentIndex].isActive = previousState
            }
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
