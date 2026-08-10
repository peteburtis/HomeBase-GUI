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
        TopologyRowLabel(
            title: group.displayName,
            technicalName: group.controlDeviceIdentifier,
            detail: TopologyRowLabel.deviceCountDescription(
                group.resolvedDeviceIdentifiers.count
            )
        )
    }
}

struct TopologyRowLabel: View {
    let title: String
    let technicalName: String?
    let detail: String?

    init(
        title: String,
        technicalName: String? = nil,
        detail: String? = nil
    ) {
        self.title = title
        self.technicalName = technicalName
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text(title)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func deviceCountDescription(_ count: Int) -> String {
        count == 1 ? "1 device" : "\(count) devices"
    }

    private var subtitle: String {
        [technicalName, detail]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }
}
