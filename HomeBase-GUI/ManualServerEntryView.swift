//
//  ManualServerEntryView.swift
//  HomeBase-GUI
//

import SwiftUI

struct ManualServerEntryView: View {
    @Environment(\.dismiss) private var dismiss

    let onEndpoint: (HomeBaseEndpoint) -> Void

    @State private var host = ""
    @State private var port = String(HomeBaseEndpoint.defaultPort)
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case host
        case port
    }

    private var endpoint: HomeBaseEndpoint? {
        guard let port = Int(port) else { return nil }
        return HomeBaseEndpoint(host: host, port: port)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("IP Address or Hostname", text: $host)
                        .focused($focusedField, equals: .host)
                        .submitLabel(.next)
                        .onSubmit {
                            focusedField = .port
                        }
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
#endif

                    TextField("Port", text: $port)
                        .focused($focusedField, equals: .port)
                        .submitLabel(.done)
                        .onSubmit(addServer)
#if os(iOS)
                        .keyboardType(.numberPad)
#endif
                } header: {
                    Text("HomeBase Server")
                } footer: {
                    Text("Enter the server's LAN address. The default HomeBase WebSocket port is \(HomeBaseEndpoint.defaultPort).")
                }
            }
            .navigationTitle("Enter Server Address")
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
            focusedField = .host
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
