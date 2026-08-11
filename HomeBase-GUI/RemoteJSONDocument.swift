//
//  RemoteJSONDocument.swift
//  HomeBase-GUI
//

import CryptoKit
import Foundation
import HomeBaseProtocol

/// A read snapshot of one remotely stored JSON configuration file.
///
/// The original source remains authoritative until an explicit user edit is
/// eventually saved. `root` is a semantic projection for browsing and draft
/// construction; merely decoding it must never cause a write.
struct RemoteJSONDocument: Equatable, Sendable {
    let path: String
    let originalSource: String
    let sourceRevision: String
    let root: HBJSONValue

    init(path: String, source: String) throws {
        let data = Data(source.utf8)
        self.path = path
        originalSource = source
        sourceRevision = Self.revision(for: source)
        root = try JSONDecoder().decode(HBJSONValue.self, from: data)
    }

    static func revision(for source: String) -> String {
        SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

extension HBJSONValue {
    var compactConfigurationJSON: String {
        configurationJSON(prettyPrinted: false)
    }

    var prettyConfigurationJSON: String {
        configurationJSON(prettyPrinted: true)
    }

    func configurationJSONSource(
        prettyPrinted: Bool
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        if prettyPrinted {
            encoder.outputFormatting.insert(.prettyPrinted)
        }
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    private func configurationJSON(prettyPrinted: Bool) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        if prettyPrinted {
            encoder.outputFormatting.insert(.prettyPrinted)
        }
        guard let data = try? encoder.encode(self) else {
            return "null"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
