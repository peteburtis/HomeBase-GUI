//
//  HomeBasePairingCode.swift
//  HomeBase-GUI
//

import Foundation

enum HomeBasePairingCode {
    static let scheme = "homebasews"

    static func address(from payload: String) -> String? {
        guard let url = URL(string: payload) else {
            return nil
        }

        return address(from: url)
    }

    static func address(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme,
              let host = url.host,
              !host.isEmpty else {
            return nil
        }

        return host
    }
}
