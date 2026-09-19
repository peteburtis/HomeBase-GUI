import CryptoKit
import HomeBaseProtocol
import SwiftUI

/// Public destination metadata is not evidence that any recording exists.
/// No AWS request is made by discovery, button presentation, or this editor.
struct CameraS3Destination: Equatable, Identifiable {
    let store: HBCameraPlaybackMetadata.S3Store

    var id: String {
        // Bind credentials to the exact destination, not a display name or a
        // server-supplied store ID alone. Camera renames do not change it.
        let fields = [store.id, store.bucket, store.region, store.prefix,
                      store.expectedOwner ?? ""]
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func advertised(in metadata: [String: HBJSONValue]) -> Self? {
        guard let value = metadata[HBDeviceMetadataKeys.cameraPlayback],
              let playback = try? value.decoded(HBCameraPlaybackMetadata.self),
              playback.provider == "hbnvr", let store = playback.s3Store,
              UUID(uuidString: store.id) != nil,
              !store.bucket.isEmpty, store.bucket.utf8.count <= 63,
              !store.region.isEmpty, store.region.utf8.count <= 64,
              store.prefix.utf8.count <= 1024,
              [store.bucket, store.region, store.prefix, store.name].allSatisfy({
                  $0.rangeOfCharacter(from: .controlCharacters) == nil
              }) else { return nil }
        // In particular, available=false describes LOCAL playback and must not
        // suppress a known S3 destination when the NVR is disconnected.
        return Self(store: store)
    }
}

enum CameraS3AccessPolicy {
    static func showsPadlock(isLive: Bool, showsVideo: Bool,
                            historyState: CameraHistoryPlayback.State,
                            resolvingTime: Bool, destination: CameraS3Destination?,
                            unlockedDestinationID: String?) -> Bool {
        guard !isLive, !showsVideo, !resolvingTime, let destination,
              destination.id != unlockedDestinationID else { return false }
        if case .loading = historyState { return false }
        // Includes confirmed gaps, local read errors and an exhausted live
        // buffer. None of these imply that S3 has (or lacks) the same footage.
        return true
    }
}

struct CameraS3PadlockButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "lock.fill")
                .font(.title3.weight(.semibold))
                .frame(width: CameraPTZOverlayMetrics.buttonSize, height: CameraPTZOverlayMetrics.buttonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .cameraGlassBacker(in: Circle(), interactive: true)
        .accessibilityLabel("Unlock S3 history")
        .accessibilityHint("Set up read-only credentials for the advertised S3 store. Recording availability has not been checked.")
    }
}

/// Credential setup only. AWS reads/manifests are a later slice; don't claim
/// that a successful Keychain save validated AWS permissions or found footage.
struct CameraS3CredentialsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var access: CameraAccessSession
    let destination: CameraS3Destination
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var encryptionPassword = ""
    @State private var errorMessage: String?
    @State private var saving = false
    @State private var saved = false
    @State private var confirmingReplacement = false
    @State private var saveTask: Task<Void, Never>?

    private var canSave: Bool {
        access.isUnlocked && !saving && !accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretAccessKey.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("S3 store") {
                    LabeledContent("Name", value: destination.store.name)
                    LabeledContent("Bucket", value: destination.store.bucket)
                    LabeledContent("Region", value: destination.store.region)
                    LabeledContent("Prefix", value: destination.store.prefix.isEmpty ? "Bucket root" : destination.store.prefix)
                }
                if saved {
                    Section {
                        Label("Credentials saved on this device", systemImage: "checkmark.shield")
                        Text("S3 video retrieval is not connected yet. Your AWS credentials have not been verified against S3, and no recording availability has been checked.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        NavigationLink {
                            CameraS3IAMPolicyView(destination: destination)
                        } label: {
                            Label("Suggested IAM policy", systemImage: "doc.text")
                        }
                    }
                    Section {
                        TextField("Access key ID", text: $accessKeyID)
                        SecureField("Secret access key", text: $secretAccessKey)
                        SecureField("Encryption password (optional)", text: $encryptionPassword)
                    } header: { Text("Read-only credentials") } footer: {
                        Text("Use a separate read-only AWS key, not the recorder's write-only key. The encryption password is needed to play encrypted recordings. Credentials are saved only on this device and require Face ID or Touch ID to unlock.")
                    }
                    .autocorrectionDisabled()
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                    .disabled(saving)
                    Section {
                        Text("This step saves credentials securely. S3 playback and AWS credential validation are coming in a separate step.")
                            .foregroundStyle(.secondary)
                    }
                    if let errorMessage {
                        Section { Text(errorMessage).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle("S3 Access")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(saved ? "Done" : "Cancel") { dismiss() }
                }
                if !saved {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "Saving…" : "Save") {
                            if let existing = access.unlockedCredentials, existing.destinationID != destination.id {
                                confirmingReplacement = true
                            } else { save() }
                        }
                        .disabled(!canSave)
                    }
                }
            }
            .confirmationDialog("Replace the saved S3 credentials?", isPresented: $confirmingReplacement, titleVisibility: .visible) {
                Button("Replace Credentials", role: .destructive, action: save)
            } message: {
                Text("Only one S3 store can be saved on this device. This replaces the previous store's credentials, not its recordings.")
            }
        }
#if os(macOS)
        .frame(minWidth: 440, minHeight: 460)
#endif
        // Authentication's temporary inactive transition must not dismiss its
        // own sheet; a real background transition does discard the editor.
        .overlay { if scenePhase != .active { Color.black.ignoresSafeArea() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { clear(); dismiss() }
        }
        .onChange(of: access.isUnlocked) { _, unlocked in
            if !unlocked { clear(); dismiss() }
        }
        .onDisappear(perform: clear)
    }

    private func save() {
        guard canSave else { return }
        saving = true; errorMessage = nil
        let credentials = CameraS3Credentials(destinationID: destination.id,
            accessKeyID: accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines),
            secretAccessKey: secretAccessKey,
            encryptionPassword: encryptionPassword.isEmpty ? nil : encryptionPassword)
        saveTask = Task {
            do {
                try await access.saveCredentials(credentials)
                try Task.checkCancellation()
                accessKeyID = ""; secretAccessKey = ""; encryptionPassword = ""
                saved = true
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            saving = false
        }
    }

    private func clear() {
        saveTask?.cancel(); saveTask = nil
        accessKeyID = ""; secretAccessKey = ""; encryptionPassword = ""
    }
}
