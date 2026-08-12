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

        var desired: [String: SceneLiveEditingTarget] = [:]
        var desiredPaths: [String] = []
        for target in targets {
            let path = target.normalizedControlPath
            desiredPaths.removeAll { $0 == path }
            desiredPaths.append(path)
            desired[path] = target
        }

        // Acquire each addition or replacement before releasing the hold it
        // supersedes. That prevents the real device from briefly falling
        // through to its lower-priority state as an editor value changes.
        for path in desiredPaths {
            guard let target = desired[path] else { continue }
            if currentHolds[path]?.target == target {
                continue
            }

            let result = try await client.holdControl(
                target.controlPath,
                at: target.value,
                transitionSeconds: nil,
                priority: Int(AutomationPresentationFormat.userPriority),
                lifetime: .session
            )
            let replacement = HeldTarget(
                target: target,
                token: result.token
            )

            if let previous = currentHolds.updateValue(
                replacement,
                forKey: path
            ) {
                cleanupHolds[previous.token] = previous
                try await release(previous)
            }
        }

        let removedPaths = currentHolds.keys.filter { desired[$0] == nil }
        for path in removedPaths {
            guard let removed = currentHolds.removeValue(forKey: path) else {
                continue
            }
            cleanupHolds[removed.token] = removed
            try await release(removed)
        }
    }

    func stop() async throws {
        let allHolds = Dictionary(
            uniqueKeysWithValues: (
                Array(currentHolds.values) + Array(cleanupHolds.values)
            )
                .map { ($0.token, $0) }
        )

        guard !allHolds.isEmpty else {
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

        currentHolds = currentHolds.filter { $0.value.token != hold.token }
        cleanupHolds[hold.token] = nil
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
            cleanupHolds.removeAll()
        }
        owningSessionIdentifier = sessionIdentifier
    }
}
