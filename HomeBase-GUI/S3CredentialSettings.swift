import Combine
import HomeBaseProtocol
import SwiftUI

/// Settings inspects attributes only. Secrets are never loaded or displayed,
/// and adding here does not grant camera access or verify AWS permissions.
@MainActor
final class S3CredentialSettingsModel: ObservableObject {
    // Lifecycle cleanup is explicit; SwiftUI can release this outside a Swift task.
    nonisolated deinit {}

    @Published private(set) var presence: CameraS3CredentialPresence?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    private let store: any CameraS3CredentialStoring
    private let authenticator: any CameraBiometricAuthenticating
    private var attempt: CameraAuthenticationAttempt?
    private var generation = 0

    init(store: (any CameraS3CredentialStoring)? = nil,
         authenticator: (any CameraBiometricAuthenticating)? = nil) {
        self.store = store ?? CameraKeychainCredentialStore()
        self.authenticator = authenticator ?? CameraSystemBiometricAuthenticator()
    }

    static func destinations(in devices: [HBTopologyDeviceDescriptor]) -> [CameraS3Destination] {
        var seen: Set<String> = []
        return devices.compactMap { CameraS3Destination.advertised(in: $0.metadata) }
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.store.name, $0.store.bucket, $0.id) < ($1.store.name, $1.store.bucket, $1.id) }
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        let request = generation
        defer { isBusy = false }
        do {
            let result = try await store.inspect()
            try requireCurrent(request)
            presence = result
        } catch { report(error, request: request) }
    }

    func add(_ credentials: CameraS3Credentials, onChange: () -> Void) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        let request = generation
        let authentication = CameraAuthenticationAttempt(reason: "Save S3 recording access on this device.")
        attempt = authentication
        defer { authentication.invalidate(); attempt = nil; isBusy = false }
        do {
            guard !credentials.destinationID.isEmpty, !credentials.accessKeyID.isEmpty,
                  !credentials.secretAccessKey.isEmpty else { throw CameraAccessError.invalidCredentials }
            let existing = try await store.inspect()
            try requireCurrent(request)
            presence = existing
            guard existing == .missing else { throw CameraAccessError.credentialsAlreadySaved }
            try await withTaskCancellationHandler {
                try await authenticator.authenticate(using: authentication)
            } onCancel: { authentication.invalidate() }
            try requireCurrent(request)
            // The Keychain add is atomic: a concurrent camera setup cannot be
            // overwritten even if it saved after the inspection above.
            try await store.add(credentials, using: authentication)
            presence = .biometricProtected
            onChange() // Invalidate old readers even if cancellation raced the committed write.
            return request == generation && !Task.isCancelled
        } catch { report(error, request: request); return false }
    }

    func delete(onChange: () -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        let request = generation
        defer { isBusy = false }
        do {
            try requireCurrent(request)
            // Deletion never reads or authenticates the saved secret.
            try await store.delete()
            presence = .missing
            onChange()
        } catch { report(error, request: request) }
    }

    func cancel() {
        generation += 1
        attempt?.invalidate()
        errorMessage = nil
    }

    private func requireCurrent(_ request: Int) throws {
        try Task.checkCancellation()
        guard request == generation else { throw CancellationError() }
    }

    private func report(_ error: Error, request: Int) {
        guard request == generation, !Task.isCancelled, !(error is CancellationError) else { return }
        switch error as? CameraAccessError {
        case .authenticationCancelled:
            errorMessage = "Authentication was cancelled. Try adding credentials again."
        case .authenticationFailed:
            errorMessage = "Authentication did not succeed. Try adding credentials again."
        case .biometryNotEnrolled:
            errorMessage = "Set up Face ID or Touch ID on this device to save credentials."
        case .credentialsAlreadySaved:
            if presence == .missing { presence = .authenticationRequired }
            errorMessage = CameraAccessError.credentialsAlreadySaved.errorDescription
        default:
            errorMessage = (error as? CameraAccessError ?? .credentialManagementUnavailable).errorDescription
        }
    }
}

#if os(macOS)
struct MacSettingsRoot: View {
    @EnvironmentObject private var serverStore: PairedServerStore

    var body: some View {
        Group {
            if let server = serverStore.selectedServer {
                MacServerSettingsView(server: server)
                    .id(server.id)
            } else {
                S3CredentialSettingsView(destinations: [], serverName: nil)
            }
        }
        .connectionStatusScopeDisabled()
    }
}

private struct MacServerSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    let server: PairedServer
    @StateObject private var connection: ServerConnectionModel

    init(server: PairedServer) {
        self.server = server
        _connection = StateObject(wrappedValue: ServerConnectionModel(server: server))
    }

    var body: some View {
        S3CredentialSettingsView(
            destinations: S3CredentialSettingsModel.destinations(in: connection.topology.devices),
            serverName: server.endpoint.host,
            server: server, client: connection.client,
            isConnected: connection.state == .connected && connection.route == .webSocket,
            serverConnectionState: connection.state,
            retryConnection: { Task { await connection.reactivate() } }
        )
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await connection.reactivate()
        }
    }
}
#endif

#if os(iOS)
struct HomeSettingsButton: View {
    var destinations: [CameraS3Destination] = []
    var serverName: String? = nil
    var server: PairedServer? = nil
    var client: HomeBaseWebSocketClient? = nil
    var isConnected = false
    @State private var isPresented = false

    var body: some View {
        Button("Settings", systemImage: "gearshape") { isPresented = true }
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("home.settings")
            .sheet(isPresented: $isPresented) {
                S3CredentialSettingsView(destinations: destinations, serverName: serverName,
                    server: server, client: client, isConnected: isConnected)
                    .connectionStatusScopeDisabled()
            }
    }
}
#endif

struct S3CredentialSettingsView: View {
    let destinations: [CameraS3Destination]
    let serverName: String?
    var server: PairedServer?
    var client: HomeBaseWebSocketClient?
    var isConnected: Bool
    var serverConnectionState: ServerConnectionModel.State?
    var retryConnection: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.cameraAccessSession) private var access
    @StateObject private var model: S3CredentialSettingsModel
    @State private var addingDestination: CameraS3Destination?
    @State private var confirmingDeletion = false
    @State private var deletionTask: Task<Void, Never>?

    init(destinations: [CameraS3Destination], serverName: String?, model: S3CredentialSettingsModel? = nil,
         server: PairedServer? = nil, client: HomeBaseWebSocketClient? = nil, isConnected: Bool = false,
         serverConnectionState: ServerConnectionModel.State? = nil, retryConnection: (() -> Void)? = nil) {
        self.destinations = destinations
        self.serverName = serverName
        self.server = server
        self.client = client
        self.isConnected = isConnected
        self.serverConnectionState = serverConnectionState
        self.retryConnection = retryConnection
        _model = StateObject(wrappedValue: model ?? S3CredentialSettingsModel())
    }

    var body: some View {
        NavigationStack {
            Form {
                if let server, let client {
                    BluetoothPresenceSettingsSection(server: server, client: client, isConnected: isConnected)
                }
                Section {
                    if model.presence == .missing {
                        Label("No saved S3 credentials", systemImage: "key")
                    } else if model.presence != nil {
                        Label("S3 credentials saved on this device", systemImage: "key.fill")
                    } else if model.isBusy {
                        ProgressView("Checking saved credentials…")
                    }
                    if model.presence != .missing {
                        Button("Delete Credentials", role: .destructive) { confirmingDeletion = true }
                            .disabled(model.isBusy)
                            .accessibilityIdentifier("settings.s3.delete")
                    }
                } header: { Text("Saved S3 access") } footer: {
                    Text("One credential set is shared across the app on this device. It is tied to the exact S3 store, not to a server. Delete it before adding a different set.")
                }
                if let error = model.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                        Button("Check Again") { Task { await model.refresh() } }
                            .disabled(model.isBusy)
                    }
                }
                Section {
                    if let serverName { LabeledContent("Selected server", value: serverName) }
                    switch serverConnectionState {
                    case .disconnected?, .connecting?:
                        ProgressView("Loading server settings…")
                    case .failed(let message)?:
                        Text(message).foregroundStyle(.red)
                        if let retryConnection { Button("Try Again", action: retryConnection) }
                    case .connected?, nil:
                        EmptyView()
                    }
                    if destinations.isEmpty {
                        if serverConnectionState == nil || serverConnectionState == .connected {
                            Text(serverName == nil ? "Choose a server to see its S3 stores and policies."
                                 : "This server is not currently advertising any S3 recording stores.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Stores advertised by the selected server")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(destinations) { destination in
                    Section(destination.store.name) {
                        S3SettingsStoreDetails(destination: destination)
                        Button("Add Credentials", systemImage: "key") { addingDestination = destination }
                            .disabled(model.presence != .missing || model.isBusy)
                            .accessibilityIdentifier("settings.s3.add")
                        NavigationLink {
                            CameraS3IAMPolicyView(destination: destination)
                        } label: { Label("Show Policy", systemImage: "doc.text") }
                    }
                }
            }
#if os(macOS)
            .formStyle(.grouped)
#endif
            .navigationTitle("Settings")
#if os(iOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
#endif
            .confirmationDialog("Delete saved S3 credentials?", isPresented: $confirmingDeletion,
                                titleVisibility: .visible) {
                Button("Delete Credentials", role: .destructive) {
                    deletionTask = Task {
                        await model.delete { access?.credentialsDidChange(presence: .missing) }
                        deletionTask = nil
                    }
                }
            } message: {
                Text("This removes the credentials from this device. Recordings and the AWS key are unchanged.")
            }
        }
#if os(macOS)
        .frame(minWidth: 440, minHeight: 460)
#endif
        .sheet(item: $addingDestination) { destination in
            S3SettingsAddCredentialsView(model: model, destination: destination) {
                access?.credentialsDidChange(presence: .biometricProtected)
            }
        }
#if os(macOS)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.refresh()
        }
#else
        .task { await model.refresh() }
#endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { cancel() }
        }
        .onDisappear(perform: cancel)
    }

    private func cancel() {
        deletionTask?.cancel()
        model.cancel()
    }
}

private struct S3SettingsStoreDetails: View {
    let destination: CameraS3Destination
    var body: some View {
        LabeledContent("Bucket", value: destination.store.bucket)
        LabeledContent("Region", value: destination.store.region)
        LabeledContent("Prefix", value: destination.store.prefix.isEmpty ? "Bucket root" : destination.store.prefix)
    }
}

struct S3SettingsAddCredentialsView: View {
    @ObservedObject var model: S3CredentialSettingsModel
    let destination: CameraS3Destination
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var encryptionPassword = ""
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section(destination.store.name) { S3SettingsStoreDetails(destination: destination) }
                Section {
                    TextField("Access key ID", text: $accessKeyID)
                    SecureField("Secret access key", text: $secretAccessKey)
                    SecureField("Encryption password (optional)", text: $encryptionPassword)
                } header: { Text("Read-only credentials") } footer: {
                    Text("Use a separate read-only AWS key. The encryption password is needed for encrypted recordings. Credentials stay on this device and require Face ID or Touch ID. Adding them does not verify AWS access.")
                }
                .autocorrectionDisabled()
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif
                .disabled(model.isBusy)
                if let error = model.errorMessage { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Add S3 Credentials")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { clear(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isBusy ? "Adding…" : "Add") { save() }
                        .disabled(model.isBusy || model.presence != .missing
                                  || accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || secretAccessKey.isEmpty)
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 440, minHeight: 460)
#endif
        .interactiveDismissDisabled(model.isBusy)
        .overlay { if scenePhase != .active { Color.black.ignoresSafeArea() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { clear(); dismiss() }
        }
        .onDisappear(perform: clear)
    }

    private func save() {
        let credentials = CameraS3Credentials(destinationID: destination.id,
            accessKeyID: accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines),
            secretAccessKey: secretAccessKey,
            encryptionPassword: encryptionPassword.isEmpty ? nil : encryptionPassword)
        saveTask = Task {
            if await model.add(credentials, onChange: onChange) { clear(); dismiss() }
            saveTask = nil
        }
    }

    private func clear() {
        if saveTask != nil { saveTask?.cancel(); model.cancel() }
        accessKeyID = ""; secretAccessKey = ""; encryptionPassword = ""
    }
}
