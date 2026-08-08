//
//  HomeBasePairingCode.swift
//  HomeBase-GUI
//

import Foundation

enum HomeBasePairingCode {
    static let scheme = "homebasews"

    static func endpoint(from payload: String) -> HomeBaseEndpoint? {
        guard let url = URL(string: payload) else {
            return nil
        }

        return endpoint(from: url)
    }

    static func endpoint(from url: URL) -> HomeBaseEndpoint? {
        guard url.scheme?.lowercased() == scheme,
              let host = url.host,
              let port = url.port else {
            return nil
        }

        return HomeBaseEndpoint(host: host, port: port)
    }
}
