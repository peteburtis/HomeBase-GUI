#if os(iOS)
import AccessorySetupKit
import CoreBluetooth
import Foundation
import HomeBaseProtocol
import UIKit

/// CoreBluetooth owns idle radio connections while the app is suspended. This
/// object sends only the initial presence request; it never polls for liveness.
@MainActor
final class BluetoothPresenceCentral: NSObject, BluetoothPresenceTransporting,
    @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate,
    @preconcurrency StreamDelegate {
    var onEvent: ((BluetoothPresenceTransportEvent) -> Void)?
    private var registrations: [BluetoothPresenceRegistration] = []
    private var central: CBCentralManager?
    private var accessorySession: ASAccessorySession?
    private var accessorySessionReady = false
    private var pickerRegistration: BluetoothPresenceRegistration?
    private var pickerShown = false
    private var accessoryRemovals: Set<UUID> = []
    private var accessoryRemovalsInFlight: Set<UUID> = []
    private var contexts: [UUID: Link] = [:]
    private var peripheralsToDisconnect: [UUID: CBPeripheral] = [:]
    private let serviceUUID = CBUUID(string: HBBluetoothProtocol.serviceUUID)
    private let identityUUID = CBUUID(string: HBBluetoothProtocol.identityCharacteristicUUID)
    private let recoveryUUID = CBUUID(string: HBBluetoothProtocol.recoveryCharacteristicUUID)

    private final class Link {
        var registration: BluetoothPresenceRegistration
        let peripheral: CBPeripheral
        var connection = BluetoothPresenceConnectionState()
        var identity: CBCharacteristic?
        var recovery: CBCharacteristic?
        var channel: CBL2CAPChannel?
        var opening = false
        var authenticated = false
        var discovering = false
        var retries = 0
        var recoveryBudget = BluetoothPresenceRecoveryBudget()
        var handshake: BluetoothPresenceHandshake?
        var output = Data()
        var decoder = HBBluetoothFrameDecoder()
        var timeout: Task<Void, Never>?
        init(registration: BluetoothPresenceRegistration, peripheral: CBPeripheral) {
            self.registration = registration
            self.peripheral = peripheral
        }
    }

    func synchronize(_ registrations: [BluetoothPresenceRegistration]) {
        self.registrations = registrations.filter { $0.phase != .removing && $0.offer != nil }
        if let item = pickerRegistration,
           !self.registrations.contains(where: { $0.registrationID == item.registrationID }) {
            pickerRegistration = nil
        }
        for (identifier, link) in contexts where !self.registrations.contains(where: { $0.peripheralID == identifier }) {
            close(link)
            disconnectWhenReady(link.peripheral)
            contexts.removeValue(forKey: identifier)
        }
        for item in registrations where item.phase == .removing && !item.accessoryRemovalComplete {
            if let identifier = item.peripheralID { removeAccessory(peripheralID: identifier) }
        }
        guard !self.registrations.isEmpty else { return }
        if self.registrations.contains(where: { $0.peripheralID != nil }) {
            activate()
            connectSavedPeripherals()
        } else {
            // Initial setup uses the system accessory picker before asking
            // CoreBluetooth to access the newly authorized peripheral.
            activateAccessorySession()
        }
    }

    private func activate() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main, options: [
                CBCentralManagerOptionRestoreIdentifierKey: "io.pjb.HomeBase-GUI.bluetooth-presence.central",
                CBCentralManagerOptionShowPowerAlertKey: false
            ])
        }
        activateAccessorySession()
    }

    private func activateAccessorySession() {
        if accessorySession == nil {
            let session = ASAccessorySession()
            accessorySession = session
            session.activate(on: .main) { [weak self] event in
                MainActor.assumeIsolated { self?.accessoryEvent(event) }
            }
        }
    }

    func showPicker(for registration: BluetoothPresenceRegistration) throws {
        guard pickerRegistration == nil || pickerRegistration?.serverID == registration.serverID else {
            throw BluetoothPresenceError.busy
        }
        pickerRegistration = registration
        activateAccessorySession()
        // A saved selection can resume after the server redeemed the token but
        // the phone died before recording its acknowledgement.
        if registration.peripheralID != nil {
            pickerRegistration = nil
            synchronize(registrations.map { $0.serverID == registration.serverID ? registration : $0 })
            return
        }
        presentPickerIfReady()
    }

    private func presentPickerIfReady() {
        guard accessorySessionReady, let session = accessorySession,
              let item = pickerRegistration, !pickerShown else { return }
        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = serviceUUID
        descriptor.bluetoothNameSubstring = HBBluetoothProtocol.advertisedNamePrefix
        descriptor.bluetoothNameSubstringCompareOptions = [.anchored]
        let displayItem = ASPickerDisplayItem(name: item.offer?.controllerName ?? "HomeBase",
            productImage: UIImage(systemName: "desktopcomputer")!, descriptor: descriptor)
        pickerShown = true
        session.showPicker(for: [displayItem]) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                guard let self, self.pickerRegistration == nil || self.pickerRegistration?.registrationID == item.registrationID else { return }
                let message = "Bluetooth setup could not finish: \(error.localizedDescription) Try pairing again."
                if self.pickerRegistration != nil { self.cancelPicker(message: message) }
                else {
                    self.onEvent?(.cancelled(serverID: item.serverID, registrationID: item.registrationID, message: message))
                }
            }
        }
    }

    private func accessoryEvent(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated:
            accessorySessionReady = true
            flushAccessoryRemovals()
            presentPickerIfReady()
            connectSavedPeripherals()
        case .accessoryAdded, .accessoryChanged:
            guard let item = pickerRegistration, let identifier = event.accessory?.bluetoothIdentifier else { return }
            pickerRegistration = nil
            onEvent?(.selected(serverID: item.serverID, peripheralID: identifier))
        case .pickerDidDismiss:
            cancelPicker()
        case .accessoryRemoved:
            guard let identifier = event.accessory?.bluetoothIdentifier else { return }
            if accessoryRemovals.remove(identifier) != nil {
                accessoryRemovalsInFlight.remove(identifier)
                onEvent?(.accessoryRemoved(peripheralID: identifier))
                return
            }
            guard
                  let item = registrations.first(where: { $0.peripheralID == identifier }) else { return }
            if let link = contexts.removeValue(forKey: identifier) {
                close(link)
                disconnectWhenReady(link.peripheral)
            }
            onEvent?(.revoked(serverID: item.serverID))
        case .invalidated:
            accessorySessionReady = false
            accessorySession = nil
            cancelPicker(message: "Bluetooth setup was interrupted. Try pairing again.")
        default: break
        }
    }

    private func cancelPicker(message: String? = nil) {
        pickerShown = false
        guard let item = pickerRegistration else { return }
        pickerRegistration = nil
        onEvent?(.cancelled(serverID: item.serverID, registrationID: item.registrationID, message: message))
    }

    func removeAccessory(peripheralID: UUID) {
        accessoryRemovals.insert(peripheralID)
        activateAccessorySession()
        flushAccessoryRemovals()
    }

    private func flushAccessoryRemovals() {
        guard accessorySessionReady, let session = accessorySession else { return }
        for identifier in accessoryRemovals where !accessoryRemovalsInFlight.contains(identifier) {
            guard let accessory = session.accessories.first(where: { $0.bluetoothIdentifier == identifier }) else {
                accessoryRemovals.remove(identifier)
                onEvent?(.accessoryRemoved(peripheralID: identifier))
                continue
            }
            accessoryRemovalsInFlight.insert(identifier)
            session.removeAccessory(accessory) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.accessoryRemovalsInFlight.remove(identifier)
                    if error == nil, self.accessoryRemovals.remove(identifier) != nil {
                        self.onEvent?(.accessoryRemoved(peripheralID: identifier))
                    }
                    // A failed system removal stays queued for activation or
                    // the next CnC cleanup event; no polling timer is needed.
                }
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            for peripheral in peripheralsToDisconnect.values {
                central.cancelPeripheralConnection(peripheral)
            }
            peripheralsToDisconnect.removeAll()
            connectSavedPeripherals()
            return
        }
        for link in contexts.values {
            close(link)
            link.connection.disconnected()
        }
        let message: String
        switch central.state {
        case .poweredOff: message = "Bluetooth is turned off on this iPhone."
        case .unauthorized: message = "Allow Bluetooth access in Settings."
        case .unsupported: message = "Bluetooth presence is not supported on this device."
        default: message = "Bluetooth is temporarily unavailable."
        }
        for item in registrations { onEvent?(.status(serverID: item.serverID, message: message)) }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        for peripheral in dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? [] {
            guard let item = registrations.first(where: { $0.peripheralID == peripheral.identifier }) else {
                disconnectWhenReady(peripheral)
                continue
            }
            let link = Link(registration: item, peripheral: peripheral)
            link.connection = BluetoothPresenceConnectionState(
                restoredConnected: peripheral.state == .connected,
                restoredConnecting: peripheral.state == .connecting)
            contexts[peripheral.identifier] = link
            peripheral.delegate = self
            // Restoration arrives before the manager's state callback. Retain
            // its local connection, but wait for poweredOn before GATT work.
            // Streams and the dynamically allocated PSM are never restored.
        }
    }

    private func connectSavedPeripherals() {
        guard let central, central.state == .poweredOn else { return }
        for item in registrations {
            guard let identifier = item.peripheralID else { continue }
            if let existing = contexts[identifier] {
                existing.registration = item
                continueConnection(existing)
                continue
            }
            guard let peripheral = central.retrievePeripherals(withIdentifiers: [identifier]).first else {
                onEvent?(.status(serverID: item.serverID, message: "Controller could not be restored. Remove pairing and set it up again."))
                continue
            }
            let link = Link(registration: item, peripheral: peripheral)
            contexts[identifier] = link
            peripheral.delegate = self
            // A retrieved peripheral may already be connected system-wide.
            // This process must still establish its own CoreBluetooth connection.
            continueConnection(link)
        }
    }

    private func continueConnection(_ link: Link) {
        guard let central else { return }
        switch link.connection.action(poweredOn: central.state == .poweredOn,
                                      peripheralConnected: link.peripheral.state == .connected,
                                      sessionActive: link.channel != nil || link.discovering || link.opening) {
        case .wait: break
        case .connect:
            onEvent?(.status(serverID: link.registration.serverID,
                message: "Waiting for the controller to come within Bluetooth range"))
            central.connect(link.peripheral)
        case .discover:
            discover(link)
        }
    }

    private func disconnectWhenReady(_ peripheral: CBPeripheral) {
        if let central, central.state == .poweredOn {
            central.cancelPeripheralConnection(peripheral)
        } else {
            peripheralsToDisconnect[peripheral.identifier] = peripheral
        }
    }

    func retryConnections() {
        for link in contexts.values {
            link.retries = 0
            link.recoveryBudget = BluetoothPresenceRecoveryBudget()
        }
        connectSavedPeripherals()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let link = contexts[peripheral.identifier] else { return }
        link.recoveryBudget = BluetoothPresenceRecoveryBudget()
        link.connection.connected()
        discover(link)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let link = contexts[peripheral.identifier] else { return }
        close(link)
        link.connection.disconnected()
        onEvent?(.status(serverID: link.registration.serverID, message: "Waiting for the controller to come within Bluetooth range"))
        // This request is left pending in CoreBluetooth while away. There is no
        // scan loop or timer waking the application to look for the controller.
        continueConnection(link)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let link = contexts[peripheral.identifier] else { return }
        link.connection.disconnected()
        failed(link, message: "Bluetooth could not connect. Try again when near the controller.", retry: false)
        if central.state == .poweredOn, link.retries < 2 {
            link.retries += 1
            continueConnection(link)
        }
    }

    private func discover(_ link: Link) {
        guard central?.state == .poweredOn, link.peripheral.state == .connected,
              link.connection.isLocallyConnected,
              !link.discovering, !link.opening, link.channel == nil else { return }
        link.discovering = true
        link.identity = nil
        link.recovery = nil
        link.peripheral.delegate = self
        link.peripheral.discoverServices([serviceUUID])
        startTimeout(link)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let link = contexts[peripheral.identifier] else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            failed(link, message: "The selected accessory does not provide HomeBase Bluetooth presence.", retry: false)
            return
        }
        peripheral.discoverCharacteristics([identityUUID, recoveryUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let link = contexts[peripheral.identifier] else { return }
        link.identity = service.characteristics?.first(where: { $0.uuid == identityUUID })
        link.recovery = service.characteristics?.first(where: { $0.uuid == recoveryUUID })
        guard error == nil, link.identity != nil, let recovery = link.recovery else {
            failed(link, message: "The controller is missing required Bluetooth characteristics.", retry: false)
            return
        }
        if recovery.isNotifying { readIdentity(link) }
        else { peripheral.setNotifyValue(true, for: recovery) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let link = contexts[peripheral.identifier], characteristic.uuid == recoveryUUID else { return }
        guard error == nil, characteristic.isNotifying else {
            failed(link, message: "Bluetooth recovery notifications could not be enabled.", retry: false)
            return
        }
        readIdentity(link)
    }

    private func readIdentity(_ link: Link) {
        if let identity = link.identity { link.peripheral.readValue(for: identity) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let link = contexts[peripheral.identifier] else { return }
        if characteristic.uuid == recoveryUUID {
            // A delayed notification must never replace a healthy connection.
            if link.channel == nil, !link.opening, !link.discovering { recover(link) }
            return
        }
        guard characteristic.uuid == identityUUID, link.channel == nil, !link.opening else { return }
        do {
            guard error == nil, let data = characteristic.value, let offer = link.registration.offer else {
                throw BluetoothPresenceError.invalidReply
            }
            let identity = try JSONDecoder().decode(HBBluetoothControllerIdentity.self, from: data)
            link.handshake = try BluetoothPresenceHandshake(identity: identity, offer: offer)
            link.discovering = false
            link.opening = true
            peripheral.openL2CAPChannel(identity.psm)
        } catch {
            // Identity mismatch is terminal for this selection. No token leaves
            // the phone before this verification succeeds.
            failed(link, message: error.localizedDescription, retry: false)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let link = contexts[peripheral.identifier] else {
            channel?.inputStream.close(); channel?.outputStream.close(); return
        }
        guard link.opening else { channel?.inputStream.close(); channel?.outputStream.close(); return }
        link.opening = false
        guard error == nil, let channel, let handshake = link.handshake else {
            failed(link, message: "The controller's Bluetooth channel could not open.", retry: true)
            return
        }
        do {
            link.output = try handshake.framedRequest()
            link.channel = channel
            for stream in [channel.inputStream as Stream, channel.outputStream as Stream] {
                stream.delegate = self
                stream.schedule(in: .main, forMode: .common)
                stream.open()
            }
        } catch { failed(link, message: error.localizedDescription, retry: false) }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard let link = contexts[peripheral.identifier], invalidatedServices.contains(where: { $0.uuid == serviceUUID }) else { return }
        close(link)
        discover(link)
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard let link = contexts.values.first(where: { $0.channel?.inputStream === aStream || $0.channel?.outputStream === aStream }) else { return }
        if eventCode.contains(.endEncountered) || eventCode.contains(.errorOccurred) {
            failed(link, message: "Bluetooth disconnected; reconnecting.", retry: true)
            return
        }
        if eventCode.contains(.hasSpaceAvailable), let output = link.channel?.outputStream {
            while output.hasSpaceAvailable && !link.output.isEmpty {
                let count = link.output.withUnsafeBytes { bytes in
                    output.write(bytes.bindMemory(to: UInt8.self).baseAddress!, maxLength: bytes.count)
                }
                if count < 0 { failed(link, message: "Bluetooth disconnected; reconnecting.", retry: true); return }
                if count == 0 { break }
                link.output.removeFirst(count)
            }
        }
        if eventCode.contains(.hasBytesAvailable) {
            read(link)
        }
    }

    private func read(_ link: Link) {
        guard let input = link.channel?.inputStream else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        while input.hasBytesAvailable {
            let count = input.read(&bytes, maxLength: bytes.count)
            guard count > 0 else {
                failed(link, message: "Bluetooth disconnected; reconnecting.", retry: true)
                return
            }
            do {
                for payload in try link.decoder.append(Data(bytes.prefix(count))) {
                    guard !link.authenticated, let handshake = link.handshake else { throw BluetoothPresenceError.invalidReply }
                    try handshake.accept(payload)
                    link.authenticated = true
                    link.retries = 0
                    link.timeout?.cancel(); link.timeout = nil
                    onEvent?(.opened(serverID: link.registration.serverID))
                }
            } catch { failed(link, message: error.localizedDescription, retry: false); return }
        }
    }

    private func startTimeout(_ link: Link) {
        link.timeout?.cancel()
        link.timeout = Task { [weak self, weak link] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self, let link, !link.authenticated else { return }
            self.failed(link, message: "Bluetooth setup timed out. Try again near the controller.", retry: false)
        }
    }

    private func failed(_ link: Link, message: String, retry: Bool) {
        close(link)
        onEvent?(.status(serverID: link.registration.serverID, message: message))
        if retry, link.retries < 2, link.peripheral.state == .connected {
            link.retries += 1
            recover(link)
        }
    }

    private func recover(_ link: Link) {
        guard link.recoveryBudget.consume(now: ProcessInfo.processInfo.systemUptime) else {
            onEvent?(.status(serverID: link.registration.serverID,
                message: "Bluetooth recovery paused after repeated connection losses. Use Reconnect Bluetooth to try again."))
            return
        }
        discover(link)
    }

    private func close(_ link: Link) {
        link.timeout?.cancel(); link.timeout = nil
        if let channel = link.channel {
            for stream in [channel.inputStream as Stream, channel.outputStream as Stream] {
                stream.delegate = nil
                stream.remove(from: .main, forMode: .common)
                stream.close()
            }
        }
        link.channel = nil
        link.opening = false
        link.discovering = false
        link.authenticated = false
        link.handshake = nil
        link.output = Data()
        link.decoder = HBBluetoothFrameDecoder()
    }
}
#endif

import Foundation
import HomeBaseProtocol

/// Distinguish this app's connection from the system-wide peripheral state.
/// Only genuine restoration or didConnect establishes local ownership.
struct BluetoothPresenceConnectionState {
    enum Action: Equatable { case wait, connect, discover }
    private(set) var isLocallyConnected: Bool
    private var connectionPending: Bool

    init(restoredConnected: Bool = false, restoredConnecting: Bool = false) {
        isLocallyConnected = restoredConnected
        connectionPending = restoredConnecting && !restoredConnected
    }

    mutating func action(poweredOn: Bool, peripheralConnected: Bool, sessionActive: Bool) -> Action {
        guard poweredOn else { return .wait }
        if isLocallyConnected && peripheralConnected {
            return sessionActive ? .wait : .discover
        }
        guard !connectionPending else { return .wait }
        isLocallyConnected = false
        connectionPending = true
        return .connect
    }

    mutating func connected() {
        isLocallyConnected = true
        connectionPending = false
    }

    mutating func disconnected() {
        isLocallyConnected = false
        connectionPending = false
    }
}

/// Replenished only when an event arrives; this never schedules a wakeup. Short
/// successful handshakes do not erase the budget for repeated stream failures.
struct BluetoothPresenceRecoveryBudget {
    private var attempts: [TimeInterval] = []
    mutating func consume(now: TimeInterval) -> Bool {
        attempts.removeAll { now - $0 >= 300 || now < $0 }
        guard attempts.count < 3 else { return false }
        attempts.append(now)
        return true
    }
}

/// Shared, testable identity gate and request/response matching. Transport
/// framing remains independent of GATT and can carry future CnC envelopes.
struct BluetoothPresenceHandshake {
    let request: HBProtocolEnvelope
    let offer: HBBluetoothPairingOffer
    let maximumMessageBytes: Int

    init(identity: HBBluetoothControllerIdentity, offer: HBBluetoothPairingOffer) throws {
        try identity.validate(expectedControllerID: offer.controllerID)
        try offer.validate() // Already redeemed tokens remain valid after offer expiry.
        self.offer = offer
        maximumMessageBytes = identity.maximumMessageBytes
        request = try HBProtocolEnvelope.request(operation: HBBluetoothProtocol.presenceOpenOperation,
            clientID: offer.registrationID,
            payload: HBBluetoothPresenceOpenRequest(controllerID: offer.controllerID,
                registrationID: offer.registrationID, token: offer.token))
    }

    func framedRequest() throws -> Data {
        let data = try JSONEncoder().encode(request)
        guard data.count <= maximumMessageBytes else { throw BluetoothPresenceError.invalidReply }
        return try HBBluetoothFrameCodec.frame(payload: data)
    }

    func accept(_ payload: Data) throws {
        guard payload.count <= maximumMessageBytes else { throw BluetoothPresenceError.invalidReply }
        let reply = try JSONDecoder().decode(HBProtocolEnvelope.self, from: payload)
        try reply.validate()
        guard reply.messageKind == .response, reply.requestID == request.requestID,
              reply.clientID == request.clientID, reply.operation == request.operation,
              reply.sessionID == nil, reply.subscriptionID == nil, reply.deliverySequence == nil else {
            throw BluetoothPresenceError.invalidReply
        }
        let body = try reply.decodedPayload(as: HBProtocolResponse.self)
        try body.validate()
        let result = try body.decodedResult(as: HBBluetoothPresenceOpenResult.self)
        try result.validate(expectedControllerID: offer.controllerID, expectedRegistrationID: offer.registrationID)
    }
}
