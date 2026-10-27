//
//  ManualServerEntryView.swift
//  HomeBase-GUI
//

import SwiftUI

struct ManualServerEntryView: View {
    @Environment(\.dismiss) private var dismiss

    let onEndpoint: (HomeBasePairingInvitation) -> Void

    @State private var pairingURL = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case pairingURL
    }

    private var endpoint: HomeBasePairingInvitation? { HomeBasePairingCode.invitation(from: pairingURL) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Pairing URL", text: $pairingURL)
                        .focused($focusedField, equals: .pairingURL)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .submitLabel(.done)
                        .onSubmit(addServer)
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
#endif

                } header: {
                    Text("HomeBase Server")
                } footer: {
                    Text("Paste the complete pairing URL printed below the HomeBase QR code.")
                }
            }
            .navigationTitle("Enter Pairing URL")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Add Server", action: addServer)
                        .disabled(endpoint == nil)
                }
            }
        }
        .onAppear {
            focusedField = .pairingURL
        }
    }

    private func addServer() {
        guard let endpoint else { return }
        onEndpoint(endpoint)
        dismiss()
    }
}

#Preview {
    ManualServerEntryView { _ in }
}
