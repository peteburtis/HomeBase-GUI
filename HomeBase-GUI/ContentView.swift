//
//  ContentView.swift
//  HomeBase-GUI
//
//  Created by bitwise on 8/7/26.
//

import SwiftUI

struct ContentView: View {
    @State private var isShowingScanner = false
    @State private var pendingPairingAddress: String?
    @State private var pairingAddress: PairingAddress?

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("No Paired Servers", systemImage: "server.rack")
            } description: {
                Text("Scan a HomeBase pairing code to add a server.")
            } actions: {
                Button("Pair a Server", systemImage: "qrcode.viewfinder") {
                    isShowingScanner = true
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
        .fullScreenCover(isPresented: $isShowingScanner, onDismiss: scannerDidDismiss) {
            PairingScannerView { address in
                receivePairingAddress(address, dismissingScanner: true)
            }
        }
#endif
        .onOpenURL { url in
            guard let address = HomeBasePairingCode.address(from: url) else {
                return
            }

            receivePairingAddress(address, dismissingScanner: isShowingScanner)
        }
        .alert(item: $pairingAddress) { pairingAddress in
            Alert(
                title: Text("HomeBase Server Found"),
                message: Text(pairingAddress.value),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func scannerDidDismiss() {
        guard let pendingPairingAddress else { return }
        self.pendingPairingAddress = nil
        pairingAddress = PairingAddress(value: pendingPairingAddress)
    }

    private func receivePairingAddress(_ address: String, dismissingScanner: Bool) {
        if dismissingScanner {
            pendingPairingAddress = address
            isShowingScanner = false
        } else {
            pairingAddress = PairingAddress(value: address)
        }
    }
}

private struct PairingAddress: Identifiable {
    let id = UUID()
    let value: String
}

#Preview {
    ContentView()
}
