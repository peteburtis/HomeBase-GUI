//
//  MetadataPresentation.swift
//  HomeBase-GUI
//

import HomeBaseProtocol

extension Dictionary where Key == String, Value == HBJSONValue {
    var hasHiddenFlag: Bool {
        self["hidden"]?.boolValue == true
    }

    var topologyPresentationDisposition: TopologyPresentationDisposition? {
        guard let rawValue = self["presentationDisposition"]?.stringValue
        else {
            return nil
        }
        return TopologyPresentationDisposition(rawValue: rawValue)
    }
}

enum TopologyPresentationDisposition: String, Equatable, Sendable {
    case device
}
