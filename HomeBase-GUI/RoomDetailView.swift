//
//  RoomDetailView.swift
//  HomeBase-GUI
//

import HomeBaseProtocol
import SwiftUI

struct RoomDetailView: View {
    let room: HBTopologyRoomDescriptor
    let topology: HBTopologyListResult
    let client: HomeBaseWebSocketClient
    let selection: Binding<TopologyDetailDestination?>

    var body: some View {
        TopologyDetailView(
            room: room,
            topology: topology,
            client: client,
            selection: selection
        )
    }
}
