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
    @State private var pairingError: String?

    var body: some View {
        presentingServerPicker {
            applicationRoot
#if os(macOS)
                // An outer, closed inspector owns a stable trailing toolbar
                // section independently of the selected screen's navigation.
                .inspector(isPresented: .constant(false)) {
                    Color.clear
                        .toolbar { ServerToolbar(showServers: showServers) }
                }
#endif
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
            guard let endpoint = HomeBasePairingCode.invitation(from: url) else {
                pairingError = HomeBaseAuthenticationError.invalidPairingURL.localizedDescription
                return
            }
            Task {
                do {
                    let server = try await serverStore.add(endpoint)
                    serverStore.select(server)
                    let notice = PairingNotice(server: server)
                    if isShowingServers {
                        pendingPairingNotice = notice
                        isShowingServers = false
                    } else { pairingNotice = notice }
                } catch { pairingError = error.localizedDescription }
            }
        }
        .alert(item: $pairingNotice) { notice in
            Alert(
                title: Text("HomeBase Server Found"),
                message: Text(notice.server.endpoint.host),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert("Unable to Pair", isPresented: Binding(get: { pairingError != nil }, set: { if !$0 { pairingError = nil } })) {
            Button("OK") { pairingError = nil }
        } message: { Text(pairingError ?? "") }
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
    @State private var pairingError: String?

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
        .frame(minHeight: 320)
        .interactiveDismissDisabled(serverStore.selectedServer == nil)
        .alert("Unable to Pair", isPresented: Binding(get: { pairingError != nil }, set: { if !$0 { pairingError = nil } })) {
            Button("OK") { pairingError = nil }
        } message: { Text(pairingError ?? "") }
#if os(iOS)
        .fullScreenCover(
            isPresented: $isShowingScanner,
            onDismiss: pairingDidDismiss
        ) {
            PairingScannerView { endpoint in
                accept(endpoint)
            }
        }
#else
        .sheet(
            isPresented: $isShowingManualEntry,
            onDismiss: pairingDidDismiss
        ) {
            ManualServerEntryView { endpoint in
                accept(endpoint)
            }
        }
#endif
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Paired Servers", systemImage: "server.rack")
        } description: {
            Text("Scan a HomeBase pairing code or paste its pairing URL to add a server.")
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

    private func accept(_ invitation: HomeBasePairingInvitation) {
        Task {
            do {
                pairedServer = try await serverStore.add(invitation)
                isShowingScanner = false
                isShowingManualEntry = false
            } catch {
                isShowingScanner = false
                isShowingManualEntry = false
                pairingError = error.localizedDescription
            }
        }
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
#if os(macOS)
    @State private var selectedDestination: MacSidebarDestination = .container(.allDevices)
#endif

    var body: some View {
#if os(macOS)
        NavigationSplitView {
            List(selection: Binding<MacSidebarDestination?>(
                get: { selectedDestination },
                set: { if let destination = $0 { selectedDestination = destination } }
            )) {
                Label("All Devices", systemImage: "square.grid.2x2")
                    .tag(MacSidebarDestination.container(.allDevices))
                Label("Cameras", systemImage: "video")
                    .tag(MacSidebarDestination.cameras)
                Label("Scenes", systemImage: "sparkles")
                    .tag(MacSidebarDestination.scenes)
                Label("Triggers", systemImage: "bolt")
                    .tag(MacSidebarDestination.triggers)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            NavigationStack {
                unavailableView
                    .navigationTitle(selectedDestinationTitle)
            }
        }
#else
        TabView {
            NavigationStack {
                unavailableView
                    .navigationTitle("Home")
                    .toolbar {
#if os(iOS)
                        ToolbarItem(placement: .topBarTrailing) { HomeSettingsButton() }
#endif
                        serverToolbar
                    }
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
#endif
    }

#if os(macOS)
    private var selectedDestinationTitle: String {
        switch selectedDestination {
        case .container(.allDevices): "All Devices"
        case .scenes: "Scenes"
        case .triggers: "Triggers"
        default: "Cameras"
        }
    }
#endif

    private var unavailableView: some View {
        ContentUnavailableView {
            Label("No Paired Server", systemImage: "server.rack")
        } description: {
            Text("Pair a HomeBase server to begin.")
        } actions: {
            Button("Choose a Server", action: showServers)
        }
    }

    private var serverToolbar: some ToolbarContent {
        ServerToolbar(showServers: showServers)
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
