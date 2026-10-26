import Combine
import Foundation
import HomeBaseProtocol
import Security
#if os(iOS)
import UIKit
#endif

/// Enrollment is saved before either network can complete it. A lost reply or
/// process exit can therefore resume the same registration instead of duplicating it.
struct BluetoothPresenceRegistration: Codable, Equatable, Identifiable {
    enum Phase: String, Codable { case pending, paired, removing }
    var id: UUID { serverID }
    let serverID: UUID
    let registrationID: UUID
    var name: String
    var phase: Phase
    var offer: HBBluetoothPairingOffer?
    var peripheralID: UUID?
    var controllerID: UUID?
    var serverRemovalComplete = false
    var accessoryRemovalComplete = false
    // Optional for compatibility with enrollments saved before automatic cleanup.
    var cancelsPendingOfferOnly: Bool? = nil
    // Optional fields preserve existing presence-only enrollments during upgrade.
    var cncCredential: HBBluetoothCnCCredential? = nil
    var cncClientID: UUID? = nil

    var isCancelledDiscovery: Bool { phase == .removing && cancelsPendingOfferOnly == true }
}

@MainActor
protocol BluetoothPresenceStoring {
    func load() throws -> [BluetoothPresenceRegistration]
    func save(_ registrations: [BluetoothPresenceRegistration]) throws
}

/// Background reconnection must work after first unlock without prompting for
/// biometrics. Tokens stay in this device's Keychain, never in defaults or logs.
final class BluetoothPresenceKeychainStore: BluetoothPresenceStoring {
    private let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.pjb.HomeBase-GUI.bluetooth-presence",
        kSecAttrAccount as String: "registrations"
    ]

    func load() throws -> [BluetoothPresenceRegistration] {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else {
            throw BluetoothPresenceError.persistence
        }
        return try JSONDecoder().decode([BluetoothPresenceRegistration].self, from: data)
    }

    func save(_ registrations: [BluetoothPresenceRegistration]) throws {
        let data = try JSONEncoder().encode(registrations)
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(addition as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw BluetoothPresenceError.persistence }
    }
}

enum BluetoothPresenceError: Error, LocalizedError {
    case persistence, unsupported, duplicateController, invalidReply, busy, removalPending
    var errorDescription: String? {
        switch self {
        case .persistence: "Bluetooth pairing could not be saved securely on this device."
        case .unsupported: "Set up Bluetooth presence from the HomeBase iPhone app."
        case .duplicateController: "This controller is already paired under another saved server."
        case .invalidReply: "The controller returned an unexpected Bluetooth pairing response."
        case .busy: "Finish or cancel the current Bluetooth pairing first."
        case .removalPending: "Bluetooth setup cleanup is still finishing. Try pairing again shortly."
        }
    }
}

protocol BluetoothPresenceCommanding: Sendable {
    func bluetoothStatus() async throws -> HBBluetoothControlStatus
    func beginBluetoothPairing(registrationID: UUID, name: String) async throws -> HBBluetoothPairingOffer
    func cancelBluetoothPairing(registrationID: UUID) async throws
    func removeBluetoothController(registrationID: UUID) async throws
    func renameBluetoothController(registrationID: UUID, name: String) async throws
}

enum BluetoothPresenceTransportEvent {
    case selected(serverID: UUID, peripheralID: UUID)
    case opened(serverID: UUID)
    case closed(serverID: UUID)
    case status(serverID: UUID, message: String)
    case cancelled(serverID: UUID, registrationID: UUID, message: String?)
    case revoked(serverID: UUID)
    case accessoryRemoved(peripheralID: UUID)
}

@MainActor
protocol BluetoothPresenceTransporting: AnyObject {
    var onEvent: ((BluetoothPresenceTransportEvent) -> Void)? { get set }
    func synchronize(_ registrations: [BluetoothPresenceRegistration])
    func showPicker(for registration: BluetoothPresenceRegistration) throws
    func removeAccessory(peripheralID: UUID)
    func retryConnections()
    func setForeground(_ isForeground: Bool)
    func controlTransport(serverID: UUID, clientID: UUID) async throws -> any HomeBaseControlTransport
}

extension BluetoothPresenceTransporting {
    func setForeground(_ isForeground: Bool) {}

    func controlTransport(serverID: UUID, clientID: UUID) async throws -> any HomeBaseControlTransport {
        throw HomeBaseControlTransportError.unavailable
    }
}

@MainActor
final class BluetoothPresenceService: ObservableObject {
    static let shared = BluetoothPresenceService()
    @Published private(set) var registrations: [BluetoothPresenceRegistration] = []
    @Published private(set) var messages: [UUID: String] = [:]
    @Published private(set) var connectedServerIDs: Set<UUID> = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var busyServers: Set<UUID> = []
    private let store: any BluetoothPresenceStoring
    private var transport: (any BluetoothPresenceTransporting)?
    private var loaded = false
    private let notificationCenter: NotificationCenter
    private let applicationIsForeground: () -> Bool
    private var lifecycleObservations: Set<AnyCancellable> = []
    private var isForeground: Bool?
    private var locallyDisabled: Set<UUID> = []
    private var cleaningServers: [UUID: Task<Void, Never>] = [:]
    // Retain CnC only while an unselected system picker needs a cancellation path.
    private var commandClients: [UUID: any BluetoothPresenceCommanding] = [:]

    init(store: (any BluetoothPresenceStoring)? = nil,
         transport: (any BluetoothPresenceTransporting)? = nil,
         notificationCenter: NotificationCenter = .default,
         applicationIsForeground: (() -> Bool)? = nil) {
        self.store = store ?? BluetoothPresenceKeychainStore()
        self.transport = transport
        self.notificationCenter = notificationCenter
        self.applicationIsForeground = applicationIsForeground ?? {
#if os(iOS)
            UIApplication.shared.applicationState != .background
#else
            true
#endif
        }
    }

    func start() {
        guard !loaded else { return }
        do {
            let saved = try store.load()
            // Without a persisted peripheral, no enrollment token could have
            // been transmitted. A previous discovery attempt has nothing to resume.
            let restored = saved.map { item in
                item.phase == .pending && item.peripheralID == nil ? cancelledDiscovery(item) : item
            }
            if restored != saved { try store.save(restored) }
            registrations = restored
            loaded = true
#if os(iOS)
            if transport == nil { transport = BluetoothPresenceCentral() }
#endif
            transport?.onEvent = { [weak self] event in self?.received(event) }
            transport?.synchronize(registrations)
            observeApplicationLifecycle()
        } catch { errorMessage = BluetoothPresenceError.persistence.localizedDescription }
    }

    private func observeApplicationLifecycle() {
#if os(iOS)
        // Observe the process once, independent of tabs, windows, or the CnC
        // route. Inactive transitions (including permission sheets) must not
        // interrupt a healthy presence connection or trigger repeated probes.
        notificationCenter.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.setForeground(false) }
            .store(in: &lifecycleObservations)
        // Reconcile before foreground screens resume their CnC requests.
        notificationCenter.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.setForeground(true) }
            .store(in: &lifecycleObservations)
        // An initial launch can become active without willEnterForeground.
        // Deduplication keeps this from repeating the foreground reconciliation.
        notificationCenter.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.setForeground(true) }
            .store(in: &lifecycleObservations)
#endif
        setForeground(applicationIsForeground())
    }

    private func setForeground(_ isForeground: Bool) {
        guard self.isForeground != isForeground else { return }
        self.isForeground = isForeground
        transport?.setForeground(isForeground)
    }

    func registrationForControlUpgrade(serverID: UUID) -> BluetoothPresenceRegistration? {
        start()
        guard !locallyDisabled.contains(serverID), let item = registration(for: serverID), item.phase == .paired else { return nil }
        return item
    }

    func saveControlCredential(_ credential: HBBluetoothCnCCredential, serverID: UUID, clientID: UUID) throws {
        try credential.validate()
        guard var item = registrationForControlUpgrade(serverID: serverID),
              item.registrationID == credential.registrationID,
              item.controllerID == credential.controllerID || item.offer?.controllerID == credential.controllerID else {
            throw BluetoothPresenceError.invalidReply
        }
        if item.cncCredential != credential || item.cncClientID != clientID {
            item.cncCredential = credential
            item.cncClientID = clientID
            try replace(item)
        }
        transport?.synchronize(registrations.filter { !locallyDisabled.contains($0.serverID) })
    }

    func controlUpgradeFailed(serverID: UUID, error: Error) {
        messages[serverID] = "Bluetooth presence remains available. Control upgrade will retry on the next network connection: \(error.localizedDescription)"
    }

    func controlTransport(serverID: UUID, clientID: UUID) async throws -> any HomeBaseControlTransport {
        guard let item = registrationForControlUpgrade(serverID: serverID),
              item.cncCredential != nil, item.cncClientID == clientID, let transport else {
            throw HomeBaseControlTransportError.unavailable
        }
        return try await transport.controlTransport(serverID: serverID, clientID: clientID)
    }

    func registration(for serverID: UUID) -> BluetoothPresenceRegistration? {
        registrations.first { $0.serverID == serverID }
    }

    /// Offer cleanup is durable bookkeeping, not an incomplete user setup step.
    func settingsRegistration(for serverID: UUID) -> BluetoothPresenceRegistration? {
        guard let item = registration(for: serverID), !item.isCancelledDiscovery else { return nil }
        return item
    }

    func reconnect() {
        start()
        transport?.synchronize(registrations.filter { !locallyDisabled.contains($0.serverID) })
        transport?.retryConnections()
    }

    func pair(serverID: UUID, name: String, client: any BluetoothPresenceCommanding) async {
        start()
        guard loaded, !busyServers.contains(serverID) else { return }
        busyServers.insert(serverID)
        defer { busyServers.remove(serverID) }
        errorMessage = nil
        do {
            guard transport != nil else { throw BluetoothPresenceError.unsupported }
            if registrations.contains(where: { $0.serverID != serverID && $0.phase == .pending }) {
                throw BluetoothPresenceError.busy
            }
            await connected(serverID: serverID, client: client)
            if registration(for: serverID)?.phase == .removing {
                throw BluetoothPresenceError.removalPending
            }
            var item = registration(for: serverID) ?? BluetoothPresenceRegistration(
                serverID: serverID, registrationID: UUID(), name: normalizedName(name), phase: .pending)
            guard item.phase == .pending else { return }
            item.name = normalizedName(name)
            if item.controllerID == nil {
                item.controllerID = try await client.bluetoothStatus().controllerID
            }
            try replace(item) // Intent is durable even if the CnC reply is lost.
            // A pending saved offer may already have been redeemed before an
            // acknowledgement was lost. Resume it instead of rotating credentials.
            let offer: HBBluetoothPairingOffer
            var alreadyRegistered = false
            if let saved = item.offer {
                if saved.expiresAt > Date().timeIntervalSince1970 {
                    offer = saved
                } else {
                    let status = try await client.bluetoothStatus()
                    guard status.controllerID == saved.controllerID else { throw HBBluetoothValidationError.controllerMismatch }
                    alreadyRegistered = status.controllers.contains { $0.registrationID == item.registrationID }
                    if alreadyRegistered { offer = saved }
                    else { offer = try await client.beginBluetoothPairing(registrationID: item.registrationID, name: item.name) }
                }
            } else {
                offer = try await client.beginBluetoothPairing(registrationID: item.registrationID, name: item.name)
            }
            // Removal can race an in-flight CnC request. Never resurrect it.
            guard registration(for: serverID)?.phase == .pending else { return }
            try offer.validate(expectedControllerID: item.controllerID,
                               now: alreadyRegistered ? nil : Date().timeIntervalSince1970)
            guard offer.registrationID == item.registrationID else { throw BluetoothPresenceError.invalidReply }
            guard !registrations.contains(where: {
                $0.serverID != serverID && $0.phase != .removing && $0.offer?.controllerID == offer.controllerID
            }) else { throw BluetoothPresenceError.duplicateController }
            guard !registrations.contains(where: {
                $0.phase == .removing && $0.controllerID == offer.controllerID
            }) else { throw BluetoothPresenceError.removalPending }
            item.offer = offer
            item.controllerID = offer.controllerID
            try replace(item)
            transport?.synchronize(registrations.filter { !locallyDisabled.contains($0.serverID) })
            messages[serverID] = "Choose your HomeBase controller."
            if item.peripheralID == nil { commandClients[serverID] = client }
            try transport?.showPicker(for: item)
        } catch {
            // Once a peripheral was selected, a lost reply may conceal a
            // redeemed token. Only unselected discovery can be discarded.
            let message = error.localizedDescription
            commandClients.removeValue(forKey: serverID)
            if cancelUnselectedPairing(serverID: serverID) {
                await connected(serverID: serverID, client: client)
            }
            errorMessage = message
        }
    }

    private func cancelledDiscovery(_ item: BluetoothPresenceRegistration) -> BluetoothPresenceRegistration {
        var item = item
        item.phase = .removing
        item.controllerID = item.controllerID ?? item.offer?.controllerID
        item.offer = nil
        item.cncCredential = nil
        item.cncClientID = nil
        item.accessoryRemovalComplete = true
        item.cancelsPendingOfferOnly = true
        return item
    }

    @discardableResult
    private func cancelUnselectedPairing(serverID: UUID) -> Bool {
        guard let pending = registration(for: serverID), pending.phase == .pending,
              pending.peripheralID == nil else { return false }
        let item = cancelledDiscovery(pending)
        commandClients.removeValue(forKey: serverID)
        locallyDisabled.insert(serverID)
        do { try replace(item) }
        catch {
            // Stop discovery even if durable storage is temporarily unavailable.
            registrations = registrations.map { $0.serverID == serverID ? item : $0 }
            errorMessage = BluetoothPresenceError.persistence.localizedDescription
        }
        transport?.synchronize(registrations)
        messages.removeValue(forKey: serverID)
        return true
    }

    /// Local disable is immediate, including while CnC is unreachable. The
    /// tombstone survives relaunch until the server acknowledges its removal.
    func remove(serverID: UUID) {
        guard var item = registration(for: serverID) else { return }
        connectedServerIDs.remove(serverID)
        commandClients.removeValue(forKey: serverID)
        let peripheralID = item.peripheralID
        locallyDisabled.insert(serverID)
        item.phase = .removing
        item.controllerID = item.controllerID ?? item.offer?.controllerID
        item.offer = nil
        item.cncCredential = nil
        item.cncClientID = nil
        item.accessoryRemovalComplete = peripheralID == nil
        do {
            try replace(item)
            transport?.synchronize(registrations)
            if let peripheralID { transport?.removeAccessory(peripheralID: peripheralID) }
            messages[serverID] = "Disabled on this iPhone. Waiting to remove it from the server."
        } catch {
            // Even if Keychain is temporarily inaccessible, stop the live link.
            registrations = registrations.map { $0.serverID == serverID ? item : $0 }
            transport?.synchronize(registrations.filter { $0.serverID != serverID })
            errorMessage = BluetoothPresenceError.persistence.localizedDescription
        }
    }

    func connected(serverID: UUID, client: any BluetoothPresenceCommanding) async {
        start()
        let pending = registrations.filter { $0.phase == .removing }
        guard !pending.isEmpty else { return }
        do {
            // A saved server can be removed and re-added with a new local ID.
            // Match the persistent controller identity before revoking any old
            // registrations through this CnC connection.
            let status = try await client.bluetoothStatus()
            for item in pending where item.controllerID == status.controllerID {
                await finishServerRemoval(serverID: item.serverID, client: client)
            }
        } catch {
            if registration(for: serverID)?.phase == .removing {
                messages[serverID] = "Disabled on this iPhone. Server removal will retry when connected."
            }
        }
    }

    private func finishServerRemoval(serverID: UUID, client: any BluetoothPresenceCommanding) async {
        guard let item = registration(for: serverID), item.phase == .removing else { return }
        if let task = cleaningServers[serverID] {
            await task.value
            // A new connection may have joined an old connection's failing
            // request. Give this reconnect one attempt with its own client,
            // only while the same registration still needs server cleanup.
            guard let current = registration(for: serverID), current.phase == .removing,
                  current.registrationID == item.registrationID, !current.serverRemovalComplete else { return }
            if let retry = cleaningServers[serverID] {
                // Another waiter already started that retry; share it without
                // chaining further retries if this attempt also fails.
                await retry.value
                return
            }
        }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            // Clear ownership before waiters resume. An outside waiter must
            // never clear a replacement task installed after this one ends.
            defer { self.cleaningServers.removeValue(forKey: serverID) }
            await self.performServerRemoval(serverID: serverID, client: client)
        }
        cleaningServers[serverID] = task
        await task.value
    }

    private func performServerRemoval(serverID: UUID, client: any BluetoothPresenceCommanding) async {
        guard var item = registration(for: serverID), item.phase == .removing else { return }
        if item.serverRemovalComplete {
            if !item.accessoryRemovalComplete, let peripheralID = item.peripheralID {
                transport?.removeAccessory(peripheralID: peripheralID)
            }
            return
        }
        do {
            if item.cancelsPendingOfferOnly == true {
                try await client.cancelBluetoothPairing(registrationID: item.registrationID)
            } else {
                try await client.removeBluetoothController(registrationID: item.registrationID)
            }
            guard registration(for: serverID)?.registrationID == item.registrationID,
                  registration(for: serverID)?.phase == .removing else { return }
            item = registration(for: serverID)!
            item.serverRemovalComplete = true
            try finishRemovalOrSave(item)
            if !item.accessoryRemovalComplete, let peripheralID = item.peripheralID {
                transport?.removeAccessory(peripheralID: peripheralID)
            }
        } catch {
            messages[serverID] = "Disabled on this iPhone. Server removal will retry when connected."
        }
    }

    func rename(serverID: UUID, name: String, client: any BluetoothPresenceCommanding) async {
        guard let item = registration(for: serverID), item.phase == .paired else { return }
        let name = normalizedName(name)
        guard name != item.name, !busyServers.contains(serverID) else { return }
        busyServers.insert(serverID)
        defer { busyServers.remove(serverID) }
        do {
            try await client.renameBluetoothController(registrationID: item.registrationID, name: name)
            // Credential enrollment can update the pairing while the rename is in flight.
            guard var current = registration(for: serverID), current.phase == .paired,
                  current.registrationID == item.registrationID else { return }
            current.name = name
            try replace(current)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func received(_ event: BluetoothPresenceTransportEvent) {
        switch event {
        case .selected(let serverID, let peripheralID):
            guard !locallyDisabled.contains(serverID), var item = registration(for: serverID), item.phase != .removing else { return }
            commandClients.removeValue(forKey: serverID)
            item.peripheralID = peripheralID
            do {
                try replace(item) // Persist before transmitting the enrollment token.
                transport?.synchronize(registrations.filter { !locallyDisabled.contains($0.serverID) })
            } catch { errorMessage = BluetoothPresenceError.persistence.localizedDescription }
        case .opened(let serverID):
            guard !locallyDisabled.contains(serverID), var item = registration(for: serverID), item.phase != .removing else { return }
            connectedServerIDs.insert(serverID)
            commandClients.removeValue(forKey: serverID)
            item.phase = .paired
            do { try replace(item); messages[serverID] = "Connected over Bluetooth" }
            catch { errorMessage = BluetoothPresenceError.persistence.localizedDescription }
        case .closed(let serverID):
            connectedServerIDs.remove(serverID)
            if messages[serverID] == "Connected over Bluetooth" { messages.removeValue(forKey: serverID) }
        case .status(let serverID, let message): messages[serverID] = message
        case .cancelled(let serverID, let registrationID, let message):
            let item = registration(for: serverID)
            // A picker completion may arrive after dismissal and cleanup. Keep
            // its error useful, but never let it cancel a newer or selected attempt.
            guard item == nil || (item?.registrationID == registrationID && item?.peripheralID == nil) else { return }
            if let message { errorMessage = message }
            guard item?.phase == .pending else { return }
            let client = commandClients.removeValue(forKey: serverID)
            cancelUnselectedPairing(serverID: serverID)
            if let client {
                Task { [weak self] in await self?.connected(serverID: serverID, client: client) }
            }
        case .revoked(let serverID): remove(serverID: serverID)
        case .accessoryRemoved(let peripheralID):
            for var item in registrations where item.phase == .removing && item.peripheralID == peripheralID {
                item.accessoryRemovalComplete = true
                do { try finishRemovalOrSave(item) }
                catch { errorMessage = BluetoothPresenceError.persistence.localizedDescription }
            }
        }
    }

    private func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "My iPhone" : String(trimmed.prefix(80))
    }

    private func finishRemovalOrSave(_ item: BluetoothPresenceRegistration) throws {
        if item.serverRemovalComplete && item.accessoryRemovalComplete {
            try persist(registrations.filter { $0.serverID != item.serverID })
            locallyDisabled.remove(item.serverID)
            commandClients.removeValue(forKey: item.serverID)
            messages.removeValue(forKey: item.serverID)
        } else {
            try replace(item)
            if item.serverRemovalComplete {
                messages[item.serverID] = "Removed from the server. Finishing Bluetooth accessory removal on this iPhone."
            }
        }
    }

    private func replace(_ item: BluetoothPresenceRegistration) throws {
        var updated = registrations.filter { $0.serverID != item.serverID }
        updated.append(item)
        try persist(updated)
    }

    private func persist(_ items: [BluetoothPresenceRegistration]) throws {
        try store.save(items)
        registrations = items
    }
}
