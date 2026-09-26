//
//  ContentView.swift
//  HomeBase-GUI
//
//  Created by bitwise on 8/7/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var serverStore: PairedServerStore

    @State private var isShowingServers = false
    @State private var pendingPairingNotice: PairingNotice?
    @State private var pairingNotice: PairingNotice?

    var body: some View {
        presentingServerPicker {
            applicationRoot
        }
        .task {
            if serverStore.selectedServer == nil {
                isShowingServers = true
            }
        }
        .onChange(of: serverStore.selectedServerID) { _, selectedServerID in
            if selectedServerID == nil {
                isShowingServers = true
            }
        }
        .onOpenURL { url in
            guard let endpoint = HomeBasePairingCode.endpoint(from: url) else {
                return
            }

            let server = serverStore.add(endpoint)
            serverStore.select(server)
            let notice = PairingNotice(server: server)
            if isShowingServers {
                pendingPairingNotice = notice
                isShowingServers = false
            } else {
                pairingNotice = notice
            }
        }
        .alert(item: $pairingNotice) { notice in
            Alert(
                title: Text("HomeBase Server Found"),
                message: Text(notice.server.endpoint.host),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ViewBuilder
    private var applicationRoot: some View {
        Group {
            if let server = serverStore.selectedServer {
                ServerDetailView(
                    server: server,
                    showServers: showServers
                )
                .id(server.id)
            } else {
                UnconfiguredServerTabView(showServers: showServers)
            }
        }
    }

    @ViewBuilder
    private func presentingServerPicker<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
#if os(iOS)
        content()
        .fullScreenCover(
            isPresented: $isShowingServers,
            onDismiss: serverPickerDidDismiss
        ) {
            ServerSelectionView { server in
                pendingPairingNotice = PairingNotice(server: server)
            }
            .environmentObject(serverStore)
        }
#else
        content()
        .sheet(
            isPresented: $isShowingServers,
            onDismiss: serverPickerDidDismiss
        ) {
            ServerSelectionView { server in
                pendingPairingNotice = PairingNotice(server: server)
            }
            .environmentObject(serverStore)
        }
#endif
    }

    private func showServers() {
        isShowingServers = true
    }

    private func serverPickerDidDismiss() {
        guard let pendingPairingNotice else { return }
        self.pendingPairingNotice = nil
        pairingNotice = pendingPairingNotice
    }
}

private struct ServerSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var serverStore: PairedServerStore

    let onPaired: (PairedServer) -> Void

    @State private var isShowingScanner = false
    @State private var isShowingManualEntry = false
    @State private var pairedServer: PairedServer?

    var body: some View {
        NavigationStack {
            Group {
                if serverStore.servers.isEmpty {
                    emptyState
                } else {
                    serverList
                }
            }
            .navigationTitle("Servers")
            .toolbar {
                if serverStore.selectedServer != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Label("Close Server List", systemImage: "xmark")
                                .labelStyle(.iconOnly)
                        }
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button("Pair a Server", systemImage: "plus") {
                        beginPairing()
                    }
                }
            }
        }
        .interactiveDismissDisabled(serverStore.selectedServer == nil)
#if os(iOS)
        .fullScreenCover(
            isPresented: $isShowingScanner,
            onDismiss: pairingDidDismiss
        ) {
            PairingScannerView { endpoint in
                pairedServer = serverStore.add(endpoint)
                isShowingScanner = false
            }
        }
#else
        .sheet(
            isPresented: $isShowingManualEntry,
            onDismiss: pairingDidDismiss
        ) {
            ManualServerEntryView { endpoint in
                pairedServer = serverStore.add(endpoint)
                isShowingManualEntry = false
            }
        }
#endif
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Paired Servers", systemImage: "server.rack")
        } description: {
            Text("Scan a HomeBase pairing code or enter its LAN address to add a server.")
        } actions: {
            Button("Pair a Server", systemImage: "qrcode.viewfinder") {
                beginPairing()
            }
        }
    }

    private var serverList: some View {
        List {
            ForEach(serverStore.servers) { server in
                Button {
                    serverStore.select(server)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Label {
                            VStack(alignment: .leading) {
                                Text(server.endpoint.host)
                                    .foregroundStyle(.primary)
                                Text("Port \(server.endpoint.port)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "server.rack")
                        }

                        Spacer()

                        if server.id == serverStore.selectedServerID {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Selected")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onDelete(perform: serverStore.remove)

            if let persistenceError = serverStore.persistenceError {
                Section {
                    Label(
                        persistenceError,
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.red)
                }
            }
        }
    }

    private func beginPairing() {
#if os(iOS)
        isShowingScanner = true
#else
        isShowingManualEntry = true
#endif
    }

    private func pairingDidDismiss() {
        guard let pairedServer else { return }
        self.pairedServer = nil
        serverStore.select(pairedServer)
        onPaired(pairedServer)
        dismiss()
    }
}

private struct UnconfiguredServerTabView: View {
    let showServers: () -> Void

    var body: some View {
        TabView {
            NavigationStack {
                unavailableView
                    .navigationTitle("Home")
                    .toolbar { serverToolbar }
            }
            .tabItem {
                Label("Home", systemImage: "house")
            }

            NavigationStack {
                unavailableView
                    .navigationTitle("Scenes")
                    .toolbar { serverToolbar }
            }
            .tabItem {
                Label("Scenes", systemImage: "sparkles")
            }

            NavigationStack {
                unavailableView
                    .navigationTitle("Triggers")
                    .toolbar { serverToolbar }
            }
            .tabItem {
                Label("Triggers", systemImage: "bolt")
            }
        }
    }

    private var unavailableView: some View {
        ContentUnavailableView {
            Label("No Paired Server", systemImage: "server.rack")
        } description: {
            Text("Pair a HomeBase server to begin.")
        } actions: {
            Button("Choose a Server", action: showServers)
        }
    }

    @ToolbarContentBuilder
    private var serverToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Servers", systemImage: "list.bullet") {
                showServers()
            }
        }
    }
}

private struct PairingNotice: Identifiable {
    let id = UUID()
    let server: PairedServer
}

#Preview {
    ContentView()
        .environmentObject(PairedServerStore())
}
