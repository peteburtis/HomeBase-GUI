//
//  SceneLiveEditingSession.swift
//  HomeBase-GUI
//

import Foundation
import HomeBaseProtocol

nonisolated struct SceneLiveEditingTarget: Equatable, Sendable {
    let controlPath: String
    let value: HBJSONValue

    var normalizedControlPath: String {
        controlPath.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    @MainActor
    static func targets(
        for actions: [SceneActionConfiguration]
    ) -> [Self] {
        var targetsByPath: [String: Self] = [:]
        var orderedPaths: [String] = []

        for action in actions {
            guard let controlSet = action.controlSet else { continue }
            let target = Self(
                controlPath: controlSet.controlPath,
                value: controlSet.value
            )
            let path = target.normalizedControlPath

            // If a hand-authored scene contains the same control more than
            // once, its last ControlSet is the scene's final intent.
            orderedPaths.removeAll { $0 == path }
            orderedPaths.append(path)
            targetsByPath[path] = target
        }

        return orderedPaths.compactMap { targetsByPath[$0] }
    }
}

/// Owns the temporary manual holds used by scene live editing.
///
/// Keeping token ownership here makes the eventual move to server-side
/// session-scoped holds a transport-level change rather than an editor change.
actor SceneLiveEditingSession {
    private enum SessionError: LocalizedError {
        case missingSessionIdentifier

        var errorDescription: String? {
            switch self {
            case .missingSessionIdentifier:
                "HomeBase opened a connection without a session identifier."
            }
        }
    }

    private struct HeldTarget: Sendable {
        let target: SceneLiveEditingTarget
        let token: String
    }

    private let client: any SceneLiveEditingRemoteClient
    private var currentHolds: [String: HeldTarget] = [:]
    private var currentOrder: [String] = []
    private var cleanupHolds: [String: HeldTarget] = [:]
    private var owningSessionIdentifier: UUID?
    private var active = false

    init(client: any SceneLiveEditingRemoteClient) {
        self.client = client
    }

    func start(targets: [SceneLiveEditingTarget]) async throws {
        guard !active, currentHolds.isEmpty, cleanupHolds.isEmpty else {
            return
        }

        active = true
        do {
            try await reconcile(targets: targets)
        } catch {
            try? await stop()
            throw error
        }
    }

    func reconcile(targets: [SceneLiveEditingTarget]) async throws {
        guard active else { return }
        try await prepareActiveSession()

        // A structurally removed token that failed release still owns its
        // original leaf footprint. Resolve that cleanup before calculating or
        // acquiring a replacement order for any path.
        for hold in cleanupHolds.values.sorted(by: { $0.token < $1.token }) {
            try await release(hold)
        }

        var desired: [String: SceneLiveEditingTarget] = [:]
        var desiredPaths: [String] = []
        for target in targets {
            let path = target.normalizedControlPath
            desiredPaths.removeAll { $0 == path }
            desiredPaths.append(path)
            desired[path] = target
        }

        let orderedCurrentPaths = currentOrder.filter {
            currentHolds[$0] != nil
        }
        let survivingCurrentPaths = orderedCurrentPaths.filter {
            desired[$0] != nil
        }
        var survivingIndex = 0
        var rebuildStart: Int?
        for (index, path) in desiredPaths.enumerated() {
            guard currentHolds[path] != nil,
                  survivingIndex < survivingCurrentPaths.count,
                  survivingCurrentPaths[survivingIndex] == path else {
                rebuildStart = index
                break
            }
            survivingIndex += 1
        }
        let rebuildPaths = Set(
            rebuildStart.map {
                desiredPaths[$0...].filter { currentHolds[$0] != nil }
            } ?? []
        )

        // A value-only edit retains its logical layer and authored order.
        // Structural insertion or reordering releases the affected existing
        // suffix first, then reacquires that suffix in authored order.
        let stablePaths = rebuildStart.map {
            Array(desiredPaths[..<$0])
        } ?? desiredPaths
        for path in stablePaths {
            guard let target = desired[path] else { continue }
            if let current = currentHolds[path] {
                guard current.target != target else { continue }
                let result = try await client.replaceControlHold(
                    token: current.token,
                    with: target.value,
                    transitionSeconds: nil
                )
                currentHolds[path] = HeldTarget(
                    target: target,
                    token: result.token
                )
            }
        }

        for path in orderedCurrentPaths where rebuildPaths.contains(path) {
            try await stageAndRelease(path: path)
        }

        let acquisitionPaths = rebuildStart.map {
            Array(desiredPaths[$0...])
        } ?? []
        for path in acquisitionPaths {
            guard let target = desired[path], currentHolds[path] == nil else {
                continue
            }
            let result = try await client.holdControl(
                target.controlPath,
                at: target.value,
                transitionSeconds: nil,
                priority: Int(AutomationPresentationFormat.userPriority),
                lifetime: .session
            )
            currentHolds[path] = HeldTarget(
                target: target,
                token: result.token
            )
            currentOrder.append(path)
        }

        let removedPaths = orderedCurrentPaths.filter { desired[$0] == nil }
        for path in removedPaths {
            try await stageAndRelease(path: path)
        }
        currentOrder = desiredPaths.filter { currentHolds[$0] != nil }
    }

    func stop() async throws {
        let allHolds = Dictionary(
            uniqueKeysWithValues: (
                Array(currentHolds.values) + Array(cleanupHolds.values)
            )
                .map { ($0.token, $0) }
        )

        guard !allHolds.isEmpty else {
            currentOrder.removeAll()
            active = false
            owningSessionIdentifier = nil
            return
        }

        try await client.reactivate()
        guard let sessionIdentifier = await client.currentSessionIdentifier()
        else {
            throw SessionError.missingSessionIdentifier
        }
        if let owningSessionIdentifier,
           owningSessionIdentifier != sessionIdentifier {
            // The server releases session-scoped holds with the old session.
            // Its tokens cannot belong to this replacement session.
            currentHolds.removeAll()
            currentOrder.removeAll()
            cleanupHolds.removeAll()
            self.owningSessionIdentifier = nil
            active = false
            return
        }
        var firstError: Error?

        for hold in allHolds.values.sorted(by: { $0.token < $1.token }) {
            do {
                try await release(hold)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstError = firstError ?? error
            }
        }

        if let firstError {
            throw firstError
        }
        owningSessionIdentifier = nil
        currentOrder.removeAll()
        active = false
    }

    func isActive() -> Bool {
        active
    }

    func hasOutstandingHolds() -> Bool {
        !currentHolds.isEmpty || !cleanupHolds.isEmpty
    }

    private func release(_ hold: HeldTarget) async throws {
        do {
            _ = try await client.releaseControlHold(token: hold.token)
        } catch let error as HBProtocolError
            where error.code == HBProtocolErrorCodes.notFound {
            // Session expiration or a server restart can erase an otherwise
            // valid token. The hold is already gone, which is our goal.
        }

        let releasedPaths = Set(
            currentHolds.compactMap { path, current in
                current.token == hold.token ? path : nil
            }
        )
        currentHolds = currentHolds.filter { $0.value.token != hold.token }
        currentOrder.removeAll { releasedPaths.contains($0) }
        cleanupHolds[hold.token] = nil
    }

    private func stageAndRelease(path: String) async throws {
        guard let removed = currentHolds.removeValue(forKey: path) else {
            currentOrder.removeAll { $0 == path }
            return
        }
        currentOrder.removeAll { $0 == path }
        cleanupHolds[removed.token] = removed
        try await release(removed)
    }

    private func prepareActiveSession() async throws {
        try await client.reactivate()
        guard let sessionIdentifier = await client.currentSessionIdentifier()
        else {
            throw SessionError.missingSessionIdentifier
        }

        if let owningSessionIdentifier,
           owningSessionIdentifier != sessionIdentifier {
            // A replacement session means the server has retired (or will
            // retire) the old session-scoped holds. Reacquire every desired
            // target rather than trusting now-stale local tokens.
            currentHolds.removeAll()
            currentOrder.removeAll()
            cleanupHolds.removeAll()
        }
        owningSessionIdentifier = sessionIdentifier
    }
}
