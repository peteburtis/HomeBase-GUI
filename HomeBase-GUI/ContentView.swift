//
//  ContentView.swift
//  HomeBase-GUI
//
//  Created by bitwise on 8/7/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var serverStore: PairedServerStore

    @State private var isShowingScanner = false
    @State private var pendingPairingNotice: PairingNotice?
    @State private var pairingNotice: PairingNotice?

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
                ToolbarItem(placement: .primaryAction) {
                    Button("Pair a Server", systemImage: "plus") {
                        isShowingScanner = true
                    }
                }
            }
        }
#if os(iOS)
        .fullScreenCover(
            isPresented: $isShowingScanner,
            onDismiss: scannerDidDismiss
        ) {
            PairingScannerView { endpoint in
                receivePairingEndpoint(
                    endpoint,
                    dismissingScanner: true
                )
            }
        }
#endif
        .onOpenURL { url in
            guard let endpoint = HomeBasePairingCode.endpoint(from: url) else {
                return
            }

            receivePairingEndpoint(
                endpoint,
                dismissingScanner: isShowingScanner
            )
        }
        .alert(item: $pairingNotice) { notice in
            Alert(
                title: Text("HomeBase Server Found"),
                message: Text(notice.server.endpoint.host),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Paired Servers", systemImage: "server.rack")
        } description: {
            Text("Scan a HomeBase pairing code to add a server.")
        } actions: {
            Button("Pair a Server", systemImage: "qrcode.viewfinder") {
                isShowingScanner = true
            }
        }
    }

    private var serverList: some View {
        List {
            ForEach(serverStore.servers) { server in
                NavigationLink {
                    ServerDetailView(server: server)
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(server.endpoint.host)
                            Text("Port \(server.endpoint.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "server.rack")
                    }
                }
            }
            .onDelete(perform: serverStore.remove)

            if let persistenceError = serverStore.persistenceError {
                Section {
                    Label(persistenceError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func scannerDidDismiss() {
        guard let pendingPairingNotice else { return }
        self.pendingPairingNotice = nil
        pairingNotice = pendingPairingNotice
    }

    private func receivePairingEndpoint(
        _ endpoint: HomeBaseEndpoint,
        dismissingScanner: Bool
    ) {
        let notice = PairingNotice(server: serverStore.add(endpoint))
        if dismissingScanner {
            pendingPairingNotice = notice
            isShowingScanner = false
        } else {
            pairingNotice = notice
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
