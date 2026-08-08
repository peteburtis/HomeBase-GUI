//
//  PairedServerStore.swift
//  HomeBase-GUI
//

import Combine
import Foundation

@MainActor
final class PairedServerStore: ObservableObject {
    @Published private(set) var servers: [PairedServer]
    @Published private(set) var persistenceError: String?

    private let defaults: UserDefaults
    private let storageKey: String

    private struct Snapshot: Codable {
        let version: Int
        var servers: [PairedServer]
    }

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "pairedServers"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey

        guard let data = defaults.data(forKey: storageKey) else {
            servers = []
            return
        }

        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.version == 1 else {
                servers = []
                persistenceError = "The saved server list uses an unsupported format."
                return
            }
            servers = snapshot.servers
        } catch {
            servers = []
            persistenceError = "The saved server list could not be read: \(error.localizedDescription)"
        }
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
        persist()
        return server
    }

    func remove(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            servers.remove(at: index)
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
}
