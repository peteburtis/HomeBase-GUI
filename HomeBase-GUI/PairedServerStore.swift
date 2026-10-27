//
//  PairedServerStore.swift
//  HomeBase-GUI
//

import Combine
import Foundation

@MainActor
final class PairedServerStore: ObservableObject {
    @Published private(set) var servers: [PairedServer]
    @Published private(set) var selectedServerID: UUID?
    @Published private(set) var persistenceError: String?

    private let defaults: UserDefaults
    private let storageKey: String
    private let selectionStorageKey: String
    private let didRemoveServer: (UUID) -> Void
    private let authenticationStore: HomeBaseAuthenticationStore
    private var additions: [HomeBaseEndpoint: Task<PairedServer, Error>] = [:]

    private struct Snapshot: Codable {
        let version: Int
        var servers: [PairedServer]
    }

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "pairedServers",
        selectionStorageKey: String = "selectedPairedServerID",
        didRemoveServer: ((UUID) -> Void)? = nil,
        authenticationStore: HomeBaseAuthenticationStore = .shared
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.selectionStorageKey = selectionStorageKey
        self.didRemoveServer = didRemoveServer ?? { BluetoothPresenceService.shared.remove(serverID: $0) }
        self.authenticationStore = authenticationStore

        guard let data = defaults.data(forKey: storageKey) else {
            servers = []
            selectedServerID = nil
            return
        }

        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.version == 2, snapshot.servers.allSatisfy({ $0.endpoint.serverFingerprint?.count == 32 }) else {
                servers = []
                selectedServerID = nil
                persistenceError = "The saved server list uses an unsupported format."
                return
            }
            servers = snapshot.servers
            let persistedSelection = defaults
                .string(forKey: selectionStorageKey)
                .flatMap(UUID.init(uuidString:))
            selectedServerID = snapshot.servers.contains {
                $0.id == persistedSelection
            } ? persistedSelection : snapshot.servers.first?.id
            persistSelection()
        } catch {
            servers = []
            selectedServerID = nil
            persistenceError = "The saved server list could not be read: \(error.localizedDescription)"
        }
    }

    var selectedServer: PairedServer? {
        guard let selectedServerID else { return nil }
        return servers.first { $0.id == selectedServerID }
    }

    @discardableResult
    func add(_ invitation: HomeBasePairingInvitation) async throws -> PairedServer {
        let endpoint = invitation.endpoint
        if let existing = servers.first(where: {
            $0.endpoint.port == endpoint.port
                && $0.endpoint.host.caseInsensitiveCompare(endpoint.host)
                    == .orderedSame
                && $0.endpoint.serverFingerprint == endpoint.serverFingerprint
        }) {
            try await authenticationStore.prepare(serverID: existing.id, invitation: invitation)
            return existing
        }
        // Two simultaneous URL opens must share one pending key/enrollment ID.
        guard let key = HomeBaseEndpoint(host: endpoint.host.lowercased(), port: endpoint.port,
                                        serverFingerprint: endpoint.serverFingerprint) else {
            throw HomeBaseAuthenticationError.invalidPairingURL
        }
        if let addition = additions[key] { return try await addition.value }
        let addition = Task { @MainActor in
            let server = PairedServer(endpoint: endpoint)
            try await authenticationStore.prepare(serverID: server.id, invitation: invitation)
            servers.append(server)
            if selectedServerID == nil {
                selectedServerID = server.id
                persistSelection()
            }
            persist()
            return server
        }
        additions[key] = addition
        defer { additions[key] = nil }
        return try await addition.value
    }

    func select(_ server: PairedServer) {
        guard servers.contains(where: { $0.id == server.id }),
              selectedServerID != server.id else {
            return
        }
        selectedServerID = server.id
        persistSelection()
    }

    func remove(at offsets: IndexSet) {
        let ids = offsets.map { servers[$0].id }
        Task {
            do {
                for id in ids {
                    try await authenticationStore.remove(serverID: id)
                    didRemoveServer(id)
                    servers.removeAll { $0.id == id }
                }
                if !servers.contains(where: { $0.id == selectedServerID }) {
                    selectedServerID = servers.first?.id
                    persistSelection()
                }
                persist()
            } catch {
                persistenceError = "The saved identity could not be removed securely. Unlock this device and try again."
            }
        }
    }

    private func persist() {
        do {
            let snapshot = Snapshot(version: 2, servers: servers)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            defaults.set(try encoder.encode(snapshot), forKey: storageKey)
            persistenceError = nil
        } catch {
            persistenceError = "The server list could not be saved: \(error.localizedDescription)"
        }
    }

    private func persistSelection() {
        if let selectedServerID {
            defaults.set(selectedServerID.uuidString, forKey: selectionStorageKey)
        } else {
            defaults.removeObject(forKey: selectionStorageKey)
        }
    }
}
