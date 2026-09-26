//
//  PairedServer.swift
//  HomeBase-GUI
//

import Foundation

struct HomeBaseEndpoint: Codable, Hashable, Sendable {
    static let defaultPort = 10_503

    let host: String
    let port: Int

    init?(host: String, port: Int) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, (1 ... 65_535).contains(port) else {
            return nil
        }

        self.host = trimmedHost
        self.port = port

        // Manual entry reaches this initializer without first passing through
        // URL parsing. Reject hosts that could not produce a usable WebSocket
        // URL rather than persisting an endpoint that can never connect.
        guard webSocketURL != nil else {
            return nil
        }
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
