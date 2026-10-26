import SwiftUI

struct BluetoothPresenceSettingsSection: View {
    let server: PairedServer
    let client: HomeBaseWebSocketClient
    let isConnected: Bool
    @ObservedObject private var presence = BluetoothPresenceService.shared
    @State private var name = "My iPhone"
    @State private var confirmingRemoval = false

    var body: some View {
        Section {
#if os(iOS)
            let registration = presence.settingsRegistration(for: server.id)
            let busy = presence.busyServers.contains(server.id)
            let bluetoothConnected = presence.connectedServerIDs.contains(server.id)
            if registration?.phase == .removing {
                Label("Disabled on this iPhone", systemImage: "iphone.slash")
                Text(presence.messages[server.id] ?? "Server removal will finish when connected.")
                    .foregroundStyle(.secondary)
            } else {
                TextField("Phone name", text: $name)
                    .textContentType(.nickname)
                    .disabled(busy || registration?.phase == .pending)
                if let registration {
                    Label(registration.phase == .paired ? (bluetoothConnected ? "Paired, connected" : "Paired") : "Setup incomplete", systemImage: "antenna.radiowaves.left.and.right")
                    if let message = presence.messages[server.id] {
                        Text(message).foregroundStyle(.secondary)
                    }
                    if registration.phase == .pending {
                        Button("Resume Pairing") { pair() }
                            .disabled(!isConnected || busy)
                    } else {
                        if name.trimmingCharacters(in: .whitespacesAndNewlines) != registration.name {
                            Button("Save Phone Name") {
                                Task { await presence.rename(serverID: server.id, name: name, client: client) }
                            }.disabled(!isConnected || busy)
                        }
                        if !bluetoothConnected {
                            Button("Reconnect Bluetooth") { presence.reconnect() }
                        }
                    }
                    Button(registration.phase == .pending ? "Cancel Pairing" : "Remove Pairing", role: .destructive) {
                        confirmingRemoval = true
                    }
                } else {
                    Button("Pair This iPhone", systemImage: "antenna.radiowaves.left.and.right") { pair() }
                        .disabled(!isConnected || busy)
                        .accessibilityIdentifier("settings.bluetooth.pair")
                }
                if !isConnected {
                    Text("Connect to this server to set up Bluetooth presence or rename this phone.")
                        .foregroundStyle(.secondary)
                }
            }
            if let error = presence.errorMessage { Text(error).foregroundStyle(.red) }
#else
            Text("Set up Bluetooth presence from the HomeBase iPhone app. Paired phones appear in the Bluetooth Controllers device.")
                .foregroundStyle(.secondary)
#endif
        } header: { Text("Bluetooth Presence") } footer: {
            Text("Once paired, this iPhone can report when it is nearby without Wi-Fi or a VPN. Bluetooth must remain enabled. The controller determines departure when the Bluetooth connection is lost.")
        }
        .onAppear {
            presence.start()
            if let registration = presence.settingsRegistration(for: server.id) { name = registration.name }
        }
        .confirmationDialog("Remove Bluetooth pairing?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Pairing", role: .destructive) {
                presence.remove(serverID: server.id)
                if isConnected { Task { await presence.connected(serverID: server.id, client: client) } }
            }
        } message: {
            Text("Presence tracking stops on this iPhone immediately. The saved phone is removed from HomeBase when its server is connected.")
        }
    }

    private func pair() {
        Task { await presence.pair(serverID: server.id, name: name, client: client) }
    }
}
