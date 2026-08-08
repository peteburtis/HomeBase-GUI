//
//  PairedServer.swift
//  HomeBase-GUI
//

import Foundation

struct HomeBaseEndpoint: Codable, Hashable, Sendable {
    let host: String
    let port: Int

    init?(host: String, port: Int) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, (1 ... 65_535).contains(port) else {
            return nil
        }

        self.host = trimmedHost
        self.port = port
    }

    nonisolated var webSocketURL: URL? {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = port
        components.path = "/"
        return components.url
    }
}

struct PairedServer: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let endpoint: HomeBaseEndpoint
    let pairedAt: Date

    init(
        id: UUID = UUID(),
        endpoint: HomeBaseEndpoint,
        pairedAt: Date = Date()
    ) {
        self.id = id
        self.endpoint = endpoint
        self.pairedAt = pairedAt
    }
}
