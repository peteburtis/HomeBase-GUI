import HomeBaseProtocol
import SwiftUI

/// Leaf selections drive the detail column independently of container navigation.
enum TopologyDetailDestination: Hashable {
    case device(String)
    case groupControls(String)
    case groupAdvanced(String)
}

struct TopologyDetailDestinationView: View {
    let selection: TopologyDetailDestination?
    let topology: HBTopologyListResult
    let client: HomeBaseWebSocketClient

    var body: some View {
        NavigationStack {
            if let selection {
                detail(for: selection)
                    .id(selection)
            } else {
                ContentUnavailableView(
                    "Select a Device",
                    systemImage: "lightbulb",
                    description: Text("Choose a device to see its live state and controls.")
                )
            }
        }
        .ownsReturnToGroupAction()
    }

    @ViewBuilder
    private func detail(for destination: TopologyDetailDestination) -> some View {
        switch destination {
        case .device(let identifier):
            // Preserve the fallback for devices referenced by a room or
            // group but not included in the engine's device catalog.
            if let device = topology.devices(identifiedBy: [identifier]).first {
                DeviceDetailView(device: device, client: client)
            }
        case .groupControls(let identifier):
            if let group = topology.groups.first(where: { $0.controlDeviceIdentifier == identifier }) {
                GroupControlsDetailView(group: group, client: client)
            } else {
                ContentUnavailableView("Group Unavailable", systemImage: "questionmark.folder")
            }
        case .groupAdvanced(let identifier):
            if let group = topology.groups.first(where: { $0.controlDeviceIdentifier == identifier }) {
                DeviceAdvancedView(
                    device: group.controlDeviceDescriptor,
                    client: client
                )
            } else {
                ContentUnavailableView("Group Unavailable", systemImage: "questionmark.folder")
            }
        }
    }
}
