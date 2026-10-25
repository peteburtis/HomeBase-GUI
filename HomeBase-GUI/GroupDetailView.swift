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
    let selection: Binding<TopologyDetailDestination?>

    var body: some View {
        TopologyDetailView(
            group: group,
            topology: topology,
            client: client,
            selection: selection
        )
    }
}

struct GroupControlsDetailView: View {
    @Environment(\.returnToGroup) private var returnToGroup
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.homeSplitViewLayout) private var splitLayout
    let group: HBTopologyGroupDescriptor
    let client: HomeBaseWebSocketClient
    @StateObject private var model: LiveDeviceControlsModel
    @State private var monitoring = LiveMonitoringSession()

    init(
        group: HBTopologyGroupDescriptor,
        client: HomeBaseWebSocketClient
    ) {
        self.group = group
        self.client = client
        _model = StateObject(wrappedValue: LiveDeviceControlsModel(
            device: group.controlDeviceDescriptor,
            client: client
        ))
    }

    var body: some View {
        List {
            LiveDeviceControlSections(model: model, subjectKind: "group")
            Section {
                NavigationLink {
                    DeviceAdvancedView(device: group.controlDeviceDescriptor, client: client)
                } label: {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
            }
        }
        .navigationTitle(group.displayName)
        .connectionStatusReport(model.state.connectionStatusPresentation(
            isActive: scenePhase == .active && splitLayout == .expanded
        )) {
            monitoring.restart()
        }
        .task(id: splitLayout) {
            if splitLayout == .collapsed {
                returnToGroup()
            }
        }
        .onChange(of: scenePhase == .active && splitLayout == .expanded, initial: true) { _, active in
            monitoring.setActive(active) { [model] in
                await model.run(reactivating: true)
            }
        }
    }
}

extension HBTopologyGroupDescriptor {
    var controlDeviceDescriptor: HBTopologyDeviceDescriptor {
        HBTopologyDeviceDescriptor(
            identifier: controlDeviceIdentifier,
            addressableName: controlDeviceIdentifier,
            displayName: displayName,
            metadata: metadata
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

struct TopologyDeviceGroupRow: View {
    let group: HBTopologyGroupDescriptor

    var body: some View {
        TopologyRowLabel(
            title: group.displayName,
            technicalName: group.controlDeviceIdentifier
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
