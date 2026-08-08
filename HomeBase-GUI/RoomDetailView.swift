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

    var body: some View {
        TopologyDetailView(
            room: room,
            topology: topology,
            client: client
        )
    }
}
