//
//  HomeBasePairingCode.swift
//  HomeBase-GUI
//

import Foundation
import HomeBaseProtocol

nonisolated enum HomeBasePairingCode {
    static let scheme = "homebasews"

    static func invitation(from payload: String) -> HomeBasePairingInvitation? {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 2_048, let components = URLComponents(string: text),
              components.scheme?.lowercased() == scheme,
              components.user == nil, components.password == nil, components.query == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host, let port = components.port,
              let fragment = components.percentEncodedFragment,
              !fragment.contains("%"), !fragment.contains("+") else { return nil }
        let pairs = fragment.split(separator: "&", omittingEmptySubsequences: false)
        guard pairs.count == 2 else { return nil }
        var values: [String: String] = [:]
        for pair in pairs {
            let fields = pair.split(separator: "=", omittingEmptySubsequences: false)
            guard fields.count == 2, values[String(fields[0])] == nil else { return nil }
            values[String(fields[0])] = String(fields[1])
        }
        guard Set(values.keys) == ["fp", "token"], let rawFingerprint = values["fp"],
              let fingerprint = try? HBBase64URL.decode(rawFingerprint, expectedByteCount: 32),
              let token = values["token"], (try? HBBase64URL.decode(token, expectedByteCount: 32)) != nil,
              let endpoint = HomeBaseEndpoint(host: host, port: port, serverFingerprint: fingerprint) else { return nil }
        return .init(endpoint: endpoint, creationToken: token)
    }

    static func invitation(from url: URL) -> HomeBasePairingInvitation? { invitation(from: url.absoluteString) }
}
