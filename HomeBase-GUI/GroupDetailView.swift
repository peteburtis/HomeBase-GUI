//
//  GroupDetailView.swift
//  HomeBase-GUI
//

import HomeBaseProtocol
import SwiftUI

struct GroupDetailView: View {
    let group: HBTopologyGroupDescriptor
    let topology: HBTopologyListResult
    let client: HomeBaseWebSocketClient

    var body: some View {
        TopologyDetailView(
            group: group,
            topology: topology,
            client: client
        )
    }
}

struct TopologyGroupRow: View {
    let group: HBTopologyGroupDescriptor

    var body: some View {
        VStack(alignment: .leading) {
            Text(group.displayName)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        let deviceCount = group.resolvedDeviceIdentifiers.count
        let devices = deviceCount == 1 ? "1 device" : "\(deviceCount) devices"
        return "\(group.role.displayName) · \(group.origin.displayName) · \(devices)"
    }
}

private extension HBTopologyGroupOrigin {
    var displayName: String {
        switch self {
        case .configured:
            "Configured"
        case .roomSynthesized:
            "Room generated"
        case .globalSynthesized:
            "Global generated"
        }
    }
}

private extension HBTopologyGroupRole {
    var displayName: String {
        switch self {
        case .general:
            "General"
        case .lights:
            "Lights"
        case .coloredLights:
            "Colored lights"
        case .temperatureLights:
            "Temperature lights"
        }
    }
}
