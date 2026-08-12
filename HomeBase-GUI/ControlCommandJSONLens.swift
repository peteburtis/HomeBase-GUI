//
//  ControlCommandJSONLens.swift
//  HomeBase-GUI
//

import HomeBaseProtocol

/// A lossless view of a control command's primary value.
///
/// HomeBase accepts either a bare primary value or an array whose first
/// element is the primary value and whose remaining elements are command
/// metadata, currently the transition. Replacing the primary through this
/// lens retains the original container and every unedited metadata value.
struct ControlCommandJSONLens: Equatable, Sendable {
    let rawValue: HBJSONValue
    let primaryValue: HBJSONValue

    init?(_ rawValue: HBJSONValue) {
        self.rawValue = rawValue
        if let components = rawValue.arrayValue {
            guard let primaryValue = components.first else { return nil }
            self.primaryValue = primaryValue
        } else {
            primaryValue = rawValue
        }
    }

    func replacingPrimaryValue(with value: HBJSONValue) -> HBJSONValue {
        guard var components = rawValue.arrayValue else { return value }
        components[0] = value
        return .array(components)
    }
}
