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

    private struct Snapshot: Codable {
        let version: Int
        var servers: [PairedServer]
    }

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "pairedServers",
        selectionStorageKey: String = "selectedPairedServerID"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.selectionStorageKey = selectionStorageKey

        guard let data = defaults.data(forKey: storageKey) else {
            servers = []
            selectedServerID = nil
            return
        }

        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.version == 1 else {
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
    func add(_ endpoint: HomeBaseEndpoint) -> PairedServer {
        if let existing = servers.first(where: {
            $0.endpoint.port == endpoint.port
                && $0.endpoint.host.caseInsensitiveCompare(endpoint.host)
                    == .orderedSame
        }) {
            return existing
        }

        let server = PairedServer(endpoint: endpoint)
        servers.append(server)
        if selectedServerID == nil {
            selectedServerID = server.id
            persistSelection()
        }
        persist()
        return server
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
        for index in offsets.sorted(by: >) {
            servers.remove(at: index)
        }
        if !servers.contains(where: { $0.id == selectedServerID }) {
            selectedServerID = servers.first?.id
            persistSelection()
        }
        persist()
    }

    private func persist() {
        do {
            let snapshot = Snapshot(version: 1, servers: servers)
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
