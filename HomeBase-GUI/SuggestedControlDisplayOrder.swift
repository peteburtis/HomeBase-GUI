//
//  SuggestedControlDisplayOrder.swift
//  HomeBase-GUI
//

import HomeBaseProtocol

/// Applies a device's optional presentation hint without replacing the
/// canonical ordering a client surface already uses.
struct SuggestedControlDisplayOrder {
    private let ranksByIdentifier: [String: Int]

    init(metadata: [String: HBJSONValue] = [:]) {
        guard let entries = metadata[
            HBDeviceMetadataKeys.suggestedDisplayOrder
        ]?.arrayValue else {
            ranksByIdentifier = [:]
            return
        }

        var ranks: [String: Int] = [:]
        for entry in entries {
            guard let identifier = entry.stringValue,
                  !identifier.isEmpty else {
                continue
            }
            let normalized = Self.normalized(identifier)
            if ranks[normalized] == nil {
                ranks[normalized] = ranks.count
            }
        }
        ranksByIdentifier = ranks
    }

    func sorted<Element>(
        _ elements: [Element],
        identifier: (Element) -> String,
        canonicalOrder: (Element, Element) -> Bool
    ) -> [Element] {
        elements.sorted { left, right in
            let leftRank = ranksByIdentifier[
                Self.normalized(identifier(left))
            ]
            let rightRank = ranksByIdentifier[
                Self.normalized(identifier(right))
            ]

            switch (leftRank, rightRank) {
            case let (leftRank?, rightRank?) where leftRank != rightRank:
                return leftRank < rightRank
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return canonicalOrder(left, right)
            }
        }
    }

    private static func normalized(_ identifier: String) -> String {
        identifier.lowercased()
    }
}
