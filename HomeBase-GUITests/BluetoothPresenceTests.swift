import Foundation
import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class BluetoothPresenceTests: XCTestCase {
    // Keep actor-owned teardown inside a Swift task. The iOS 26.1 XCTest
    // runtime cannot safely release nested isolated deinits from its ObjC entry.

    func testOpeningAndViewingNeverWritesOrEnrolls() async {
        let fixture = Fixture()
        fixture.service.start()
        fixture.service.start()
        XCTAssertNil(fixture.service.registration(for: fixture.serverID))
        XCTAssertEqual(fixture.store.saves.count, 0)
        XCTAssertEqual(fixture.commands.begins, 0)
        XCTAssertEqual(fixture.transport.pickers.count, 0)
    }

    func testEnrollmentPersistsIntentThenCredentialsThenPeripheralBeforeConnection() async throws {
        let fixture = Fixture()
        await fixture.pair()
        XCTAssertEqual(fixture.store.saves.count, 2)
        XCTAssertNil(fixture.store.saves[0].first?.offer)
        XCTAssertEqual(fixture.store.saves[1].first?.offer?.token, "fixture-token")
        XCTAssertEqual(fixture.transport.pickers.count, 1)
        let peripheral = UUID()
        fixture.transport.onEvent?(.selected(serverID: fixture.serverID, peripheralID: peripheral))
        XCTAssertEqual(fixture.store.saves.last?.first?.peripheralID, peripheral)
        XCTAssertEqual(fixture.transport.synchronized.last?.first?.peripheralID, peripheral)
        fixture.transport.onEvent?(.opened(serverID: fixture.serverID))
        XCTAssertEqual(fixture.service.registration(for: fixture.serverID)?.phase, .paired)
        XCTAssertEqual(fixture.service.registration(for: fixture.serverID)?.name, "My iPhone")
        XCTAssertTrue(fixture.service.connectedServerIDs.contains(fixture.serverID))
        fixture.service.controlUpgradeFailed(serverID: fixture.serverID, error: BluetoothPresenceError.invalidReply)
        XCTAssertTrue(fixture.service.connectedServerIDs.contains(fixture.serverID),
                      "A control-upgrade diagnostic does not close authenticated Bluetooth presence")
        fixture.transport.onEvent?(.closed(serverID: fixture.serverID))
        XCTAssertFalse(fixture.service.connectedServerIDs.contains(fixture.serverID))
        XCTAssertEqual(fixture.service.registration(for: fixture.serverID)?.phase, .paired,
                       "Disconnecting preserves pairing while clearing the connected diagnostic")
    }

    func testCnCClientIsRetainedOnlyWhileUnselectedPickerIsActive() async {
        let service = BluetoothPresenceService(store: Store(), transport: Transport())
        let serverID = UUID()
        var idleClient: Commands? = Commands()
        weak var observedIdleClient = idleClient
        await service.connected(serverID: serverID, client: idleClient!)
        idleClient = nil
        XCTAssertNil(observedIdleClient, "Ordinary server navigation must not retain its CnC client")

        let transport = Transport()
        let pairingService = BluetoothPresenceService(store: Store(), transport: transport)
        var pairingClient: Commands? = Commands()
        weak var observedPairingClient = pairingClient
        await pairingService.pair(serverID: serverID, name: "My iPhone", client: pairingClient!)
        pairingClient = nil
        XCTAssertNotNil(observedPairingClient, "Discovery needs CnC only until selection or cancellation")
        transport.onEvent?(.selected(serverID: serverID, peripheralID: UUID()))
        XCTAssertNil(observedPairingClient, "Selected Bluetooth recovery must not keep CnC alive")
    }

    func testUnselectedPickerDismissalReturnsToPairAndCancelsOfferWithoutRemovingController() async throws {
        let fixture = Fixture()
        await fixture.pair()
        let identifier = try XCTUnwrap(fixture.service.registration(for: fixture.serverID)?.registrationID)
        fixture.transport.onEvent?(.cancelled(serverID: fixture.serverID, registrationID: identifier, message: nil))
        XCTAssertNil(fixture.service.settingsRegistration(for: fixture.serverID))
        XCTAssertEqual(fixture.store.items.first?.phase, .removing, "Cleanup must survive an offline relaunch")
        XCTAssertNil(fixture.store.items.first?.offer)
        XCTAssertTrue(fixture.transport.synchronized.last?.allSatisfy { $0.phase == .removing } == true)
        await fixture.service.connected(serverID: fixture.serverID, client: fixture.commands)
        XCTAssertEqual(fixture.commands.cancellations, [identifier])
        XCTAssertEqual(fixture.commands.removals, 0)
        XCTAssertNil(fixture.service.registration(for: fixture.serverID))
        await fixture.pair()
        XCTAssertNotEqual(fixture.service.registration(for: fixture.serverID)?.registrationID, identifier)
        XCTAssertEqual(fixture.commands.begins, 2)
    }

    func testPickerFailureCancelsOfferAndKeepsUsefulError() async throws {
        let fixture = Fixture()
        await fixture.pair()
        let identifier = try XCTUnwrap(fixture.service.registration(for: fixture.serverID)?.registrationID)
        let message = "Accessory discovery timed out. Try pairing again."
        fixture.transport.onEvent?(.cancelled(serverID: fixture.serverID, registrationID: identifier, message: message))
        await fixture.service.connected(serverID: fixture.serverID, client: fixture.commands)
        XCTAssertNil(fixture.service.settingsRegistration(for: fixture.serverID))
        XCTAssertEqual(fixture.commands.cancellations, [identifier])
        XCTAssertEqual(fixture.service.errorMessage, message)
    }

    func testPickerErrorAfterDismissalAndCleanupStillExplainsFailure() async throws {
        let fixture = Fixture()
        await fixture.pair()
        let identifier = try XCTUnwrap(fixture.service.registration(for: fixture.serverID)?.registrationID)
        fixture.transport.onEvent?(.cancelled(serverID: fixture.serverID, registrationID: identifier, message: nil))
        await fixture.service.connected(serverID: fixture.serverID, client: fixture.commands)
        fixture.transport.onEvent?(.cancelled(serverID: fixture.serverID, registrationID: identifier, message: "Discovery timed out."))
        XCTAssertEqual(fixture.service.errorMessage, "Discovery timed out.")
        XCTAssertNil(fixture.service.settingsRegistration(for: fixture.serverID))
        XCTAssertEqual(fixture.commands.cancellations, [identifier])
    }

    func testThrowingPickerUsesSameAutomaticCleanup() async {
        let fixture = Fixture()
        fixture.transport.pickerError = BluetoothPresenceError.invalidReply
        await fixture.pair()
        XCTAssertNil(fixture.service.registration(for: fixture.serverID))
        XCTAssertEqual(fixture.commands.cancellations.count, 1)
        XCTAssertEqual(fixture.commands.removals, 0)
        XCTAssertEqual(fixture.service.errorMessage, BluetoothPresenceError.invalidReply.localizedDescription)
    }

    func testCancelledDiscoveryRetriesAfterOfflineRelaunchOnlyForMatchingController() async throws {
        let fixture = Fixture()
        await fixture.pair()
        let identifier = try XCTUnwrap(fixture.service.registration(for: fixture.serverID)?.registrationID)
        fixture.commands.failCancellation = true
        fixture.transport.onEvent?(.cancelled(serverID: fixture.serverID, registrationID: identifier, message: nil))
        await fixture.service.connected(serverID: fixture.serverID, client: fixture.commands)
        let restoredTransport = Transport()
        let restored = BluetoothPresenceService(store: fixture.store, transport: restoredTransport)
        restored.start()
        XCTAssertNil(restored.settingsRegistration(for: fixture.serverID))
        XCTAssertEqual(restored.registration(for: fixture.serverID)?.phase, .removing)
        let otherController = Commands()
        await restored.connected(serverID: UUID(), client: otherController)
        XCTAssertTrue(otherController.cancellations.isEmpty)
        XCTAssertEqual(restored.registration(for: fixture.serverID)?.phase, .removing)
        // Relaunch creates a new CnC client. Keep the simulated old process's
        // client offline so an outstanding callback cannot be revived by changing
        // the replacement connection's state.
        let reconnected = Commands(controllerID: fixture.commands.controllerID)
        await restored.connected(serverID: UUID(), client: reconnected)
        XCTAssertTrue(fixture.commands.cancellations.isEmpty)
        XCTAssertEqual(reconnected.cancellations, [identifier])
        XCTAssertNil(restored.registration(for: fixture.serverID))
        XCTAssertTrue(fixture.store.items.isEmpty)
    }

    func testReconnectedClientRetriesCleanupAfterJoinedDisconnectedRequestFails() async throws {
        let fixture = Fixture()
        await fixture.pair()
        fixture.service.remove(serverID: fixture.serverID)
        let oldRequestStarted = expectation(description: "Old connection started removal")
        fixture.commands.suspendRemoval = true
        fixture.commands.onRemoval = { oldRequestStarted.fulfill() }
        let oldCleanup = Task {
            await fixture.service.connected(serverID: fixture.serverID, client: fixture.commands)
        }
        await fulfillment(of: [oldRequestStarted], timeout: 2)
        let pendingRemoval = try XCTUnwrap(fixture.commands.pendingRemoval)

        let replacement = Commands(controllerID: fixture.commands.controllerID)
        let reconnectStarted = expectation(description: "Replacement connection verified controller identity")
        replacement.onStatus = { reconnectStarted.fulfill() }
        let reconnectedCleanup = Task {
            await fixture.service.connected(serverID: fixture.serverID, client: replacement)
        }
        await fulfillment(of: [reconnectStarted], timeout: 2)
        // Let the reconnect join the still-suspended old cleanup before failing it.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(replacement.removals, 0)
        fixture.commands.pendingRemoval = nil
        pendingRemoval.resume(throwing: BluetoothPresenceError.invalidReply)
        await oldCleanup.value
        await reconnectedCleanup.value

        XCTAssertEqual(fixture.commands.removalAttempts, 1)
        XCTAssertEqual(replacement.removalAttempts, 1)
        XCTAssertEqual(replacement.removals, 1, "Reconnect must use its own client after the old connection fails")
        XCTAssertNil(fixture.service.registration(for: fixture.serverID))
    }

    func testRelaunchCancelsLegacyUnselectedAttemptBeforeActivatingTransport() async {
        let fixture = Fixture()
        let identifier = UUID()
        fixture.store.items = [BluetoothPresenceRegistration(serverID: fixture.serverID,
            registrationID: identifier, name: "My iPhone", phase: .pending,
            offer: fixture.commands.offer(registrationID: identifier))]
        fixture.service.start()
        XCTAssertNil(fixture.service.settingsRegistration(for: fixture.serverID))
        XCTAssertEqual(fixture.store.items.first?.controllerID, fixture.commands.controllerID)
        XCTAssertEqual(fixture.store.items.first?.phase, .removing)
        XCTAssertNil(fixture.transport.synchronized.last?.first?.offer)
        await fixture.service.connected(serverID: fixture.serverID, client: fixture.commands)
        XCTAssertEqual(fixture.commands.cancellations, [identifier])
        XCTAssertNil(fixture.service.registration(for: fixture.serverID))
    }

    func testPickerDismissalCannotDiscardSelectedPendingCredentials() async throws {
        let fixture = Fixture()
        await fixture.pair()
        let identifier = try XCTUnwrap(fixture.service.registration(for: fixture.serverID)?.registrationID)
        fixture.transport.onEvent?(.selected(serverID: fixture.serverID, peripheralID: UUID()))
        fixture.transport.onEvent?(.cancelled(serverID: fixture.serverID, registrationID: identifier, message: "Late picker error"))
        await fixture.service.connected(serverID: fixture.serverID, client: fixture.commands)
        XCTAssertEqual(fixture.service.settingsRegistration(for: fixture.serverID)?.phase, .pending)
        XCTAssertEqual(fixture.service.registration(for: fixture.serverID)?.offer?.token, "fixture-token")
        XCTAssertTrue(fixture.commands.cancellations.isEmpty)
        XCTAssertNil(fixture.service.errorMessage)
    }

    func testLateCancellationCannotCancelReplacementAttempt() async throws {
        let fixture = Fixture()
        await fixture.pair()
        let oldIdentifier = try XCTUnwrap(fixture.service.registration(for: fixture.serverID)?.registrationID)
        fixture.transport.onEvent?(.cancelled(serverID: fixture.serverID, registrationID: oldIdentifier, message: nil))
        await fixture.service.connected(serverID: fixture.serverID, client: fixture.commands)
        await fixture.pair()
        let newIdentifier = fixture.service.registration(for: fixture.serverID)?.registrationID
        fixture.transport.onEvent?(.cancelled(serverID: fixture.serverID, registrationID: oldIdentifier, message: "Old picker error"))
        XCTAssertEqual(fixture.service.settingsRegistration(for: fixture.serverID)?.phase, .pending)
        XCTAssertEqual(fixture.service.registration(for: fixture.serverID)?.registrationID, newIdentifier)
        XCTAssertNil(fixture.service.errorMessage)
        XCTAssertEqual(fixture.commands.cancellations, [oldIdentifier])
    }

    func testRelaunchResumesSavedPendingCredentialsWithoutCnCOrDuplicatingEnrollment() async throws {
        let fixture = Fixture()
        await fixture.pair()
        fixture.transport.onEvent?(.selected(serverID: fixture.serverID, peripheralID: UUID()))
        let restoredTransport = Transport()
        let restored = BluetoothPresenceService(store: fixture.store, transport: restoredTransport)
        restored.start()
        XCTAssertEqual(restoredTransport.synchronized.last?.first?.offer?.token, "fixture-token")
        await restored.pair(serverID: fixture.serverID, name: "My iPhone", client: fixture.commands)
        XCTAssertEqual(fixture.commands.begins, 1, "A lost Bluetooth acknowledgement must not rotate an already redeemed token")
    }

    func testRemovalStopsTransportAndSurvivesOfflineRelaunchUntilAcknowledged() async {
        let fixture = Fixture()
        await fixture.pair()
        let peripheral = UUID()
        fixture.transport.onEvent?(.selected(serverID: fixture.serverID, peripheralID: peripheral))
        fixture.transport.onEvent?(.opened(serverID: fixture.serverID))
        fixture.service.remove(serverID: fixture.serverID)
        XCTAssertTrue(fixture.transport.synchronized.last?.allSatisfy { $0.phase == .removing } == true)
        XCTAssertFalse(fixture.service.connectedServerIDs.contains(fixture.serverID))
        XCTAssertEqual(fixture.transport.removed, [peripheral])
        XCTAssertNil(fixture.store.saves.last?.first?.offer)
        fixture.commands.failRemoval = true
        await fixture.service.connected(serverID: fixture.serverID, client: fixture.commands)
        XCTAssertEqual(fixture.service.registration(for: fixture.serverID)?.phase, .removing)
        let restoredTransport = Transport()
        let restored = BluetoothPresenceService(store: fixture.store, transport: restoredTransport)
        restored.start()
        fixture.commands.failRemoval = false
        await restored.connected(serverID: fixture.serverID, client: fixture.commands)
        XCTAssertEqual(restored.registration(for: fixture.serverID)?.phase, .removing,
                       "Server acknowledgement alone must not discard pending system accessory removal")
        restoredTransport.onEvent?(.accessoryRemoved(peripheralID: peripheral))
        XCTAssertNil(restored.registration(for: fixture.serverID))
        XCTAssertTrue(fixture.store.saves.last?.isEmpty == true)
    }

    func testExpiredSelectedButUnredeemedOfferRenewsWithoutDuplicatingPhone() async {
        let fixture = Fixture()
        let identifier = UUID()
        let peripheralID = UUID()
        fixture.store.items = [BluetoothPresenceRegistration(serverID: fixture.serverID,
            registrationID: identifier, name: "My iPhone", phase: .pending,
            offer: HBBluetoothPairingOffer(controllerID: fixture.commands.controllerID, registrationID: identifier,
                token: "expired-token", controllerName: "HomeBase", expiresAt: Date().timeIntervalSince1970 - 1),
            peripheralID: peripheralID)]
        await fixture.pair()
        XCTAssertEqual(fixture.commands.begins, 1)
        XCTAssertEqual(fixture.service.registration(for: fixture.serverID)?.registrationID, identifier)
        XCTAssertEqual(fixture.service.registration(for: fixture.serverID)?.peripheralID, peripheralID)
        XCTAssertEqual(fixture.service.registration(for: fixture.serverID)?.offer?.token, "fixture-token")
    }

    func testExpiredOfferWithLostAcknowledgementPreservesRedeemedToken() async {
        let fixture = Fixture()
        let identifier = UUID()
        fixture.commands.registered = [HBBluetoothRegisteredController(registrationID: identifier,
            displayName: "My iPhone", nearby: false, available: true, pairedAt: Date().timeIntervalSince1970 - 100)]
        fixture.store.items = [BluetoothPresenceRegistration(serverID: fixture.serverID,
            registrationID: identifier, name: "My iPhone", phase: .pending,
            offer: HBBluetoothPairingOffer(controllerID: fixture.commands.controllerID, registrationID: identifier,
                token: "redeemed-token", controllerName: "HomeBase", expiresAt: Date().timeIntervalSince1970 - 1),
            peripheralID: UUID())]
        await fixture.pair()
        XCTAssertEqual(fixture.commands.begins, 0)
        XCTAssertEqual(fixture.service.registration(for: fixture.serverID)?.offer?.token, "redeemed-token")
    }

    func testLateSelectedAndOpenedEventsCannotResurrectRemovedRegistration() async {
        let fixture = Fixture()
        await fixture.pair()
        fixture.service.remove(serverID: fixture.serverID)
        fixture.transport.onEvent?(.selected(serverID: fixture.serverID, peripheralID: UUID()))
        fixture.transport.onEvent?(.opened(serverID: fixture.serverID))
        XCTAssertEqual(fixture.service.registration(for: fixture.serverID)?.phase, .removing)
        XCTAssertNil(fixture.service.registration(for: fixture.serverID)?.offer)
    }

    func testReaddedServerCleansOldLocalIDOnlyAfterControllerIdentityMatches() async {
        let fixture = Fixture()
        await fixture.pair()
        fixture.service.remove(serverID: fixture.serverID)
        let differentController = Commands()
        await fixture.service.connected(serverID: UUID(), client: differentController)
        XCTAssertEqual(differentController.removals, 0)
        XCTAssertEqual(fixture.service.registration(for: fixture.serverID)?.phase, .removing)
        await fixture.service.connected(serverID: UUID(), client: fixture.commands)
        XCTAssertEqual(fixture.commands.removals, 1)
        XCTAssertNil(fixture.service.registration(for: fixture.serverID))
    }

    func testForgettingServerDisablesOnlyItsBluetoothRegistration() async throws {
        let suite = "BluetoothPresenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var removed: [UUID] = []
        let servers = PairedServerStore(defaults: defaults, didRemoveServer: { removed.append($0) })
        let first = servers.add(try XCTUnwrap(HomeBaseEndpoint(host: "first.local", port: 10503)))
        let second = servers.add(try XCTUnwrap(HomeBaseEndpoint(host: "second.local", port: 10503)))
        servers.select(second)
        XCTAssertTrue(removed.isEmpty, "Navigation must not disable Bluetooth")
        servers.remove(at: IndexSet(integer: 0))
        XCTAssertEqual(removed, [first.id])
        XCTAssertEqual(servers.selectedServerID, second.id)
    }

    func testPersistenceFailureStopsTrackingWithoutSendingEnrollmentToken() async {
        let fixture = Fixture()
        fixture.store.failSave = true
        await fixture.pair()
        XCTAssertEqual(fixture.commands.begins, 0)
        XCTAssertTrue(fixture.transport.pickers.isEmpty)
        XCTAssertNotNil(fixture.service.errorMessage)
    }

    func testUnchangedRenameNeverWritesToServer() async {
        let fixture = Fixture()
        await fixture.pair()
        fixture.transport.onEvent?(.opened(serverID: fixture.serverID))
        let saves = fixture.store.saves.count
        await fixture.service.rename(serverID: fixture.serverID, name: " My iPhone ", client: fixture.commands)
        XCTAssertEqual(fixture.commands.renames, 0)
        XCTAssertEqual(fixture.store.saves.count, saves)
        let identifier = fixture.service.registration(for: fixture.serverID)?.registrationID
        await fixture.service.rename(serverID: fixture.serverID, name: "Kitchen Phone", client: fixture.commands)
        XCTAssertEqual(fixture.service.registration(for: fixture.serverID)?.name, "Kitchen Phone")
        XCTAssertEqual(fixture.service.registration(for: fixture.serverID)?.registrationID, identifier)
    }

    func testHandshakeRejectsWrongControllerBeforeBuildingCredentialRequest() async throws {
        let fixture = Fixture()
        let offer = fixture.commands.offer(registrationID: UUID())
        let identity = HBBluetoothControllerIdentity(controllerID: UUID(), displayName: "Wrong HomeBase", psm: 128)
        XCTAssertThrowsError(try BluetoothPresenceHandshake(identity: identity, offer: offer)) { error in
            XCTAssertEqual(error as? HBBluetoothValidationError, .controllerMismatch)
        }
    }

    func testFreshProcessConnectsBeforeDiscoveringAnOSConnectedPeripheral() async {
        var state = BluetoothPresenceConnectionState()
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: true, sessionActive: false), .connect,
                       "An OS-level connection is not yet owned by this process")
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: true, sessionActive: false), .wait,
                       "Repeated synchronization must not duplicate the pending connection request")
        state.connected()
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: true, sessionActive: false), .discover)
    }

    func testRestoredConnectedPeripheralWaitsForRadioBeforeDiscovering() async {
        var state = BluetoothPresenceConnectionState(restoredConnected: true)
        XCTAssertEqual(state.action(poweredOn: false, peripheralConnected: true, sessionActive: false), .wait)
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: true, sessionActive: false), .discover,
                       "Restoration already establishes local ownership once Bluetooth is ready")
    }

    func testRestoredConnectingPeripheralDoesNotDuplicatePendingRequest() async {
        var state = BluetoothPresenceConnectionState(restoredConnecting: true)
        XCTAssertEqual(state.action(poweredOn: false, peripheralConnected: false, sessionActive: false), .wait)
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: false, sessionActive: false), .wait)
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: true, sessionActive: false), .wait,
                       "A system state change must still wait for the local didConnect callback")
        state.connected()
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: true, sessionActive: false), .discover)
    }

    func testRadioPowerCycleClearsOwnershipAndReconnectsOnceReady() async {
        var state = BluetoothPresenceConnectionState()
        XCTAssertEqual(state.action(poweredOn: false, peripheralConnected: false, sessionActive: false), .wait)
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: false, sessionActive: false), .connect,
                       "Waiting for radio power must not mark a connection request as pending")
        state.connected()
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: true, sessionActive: false), .discover)
        state.disconnected()
        XCTAssertEqual(state.action(poweredOn: false, peripheralConnected: false, sessionActive: false), .wait)
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: true, sessionActive: false), .connect,
                       "After a disconnect, even an OS-connected peripheral needs a fresh local request")
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: true, sessionActive: false), .wait)
        state.connected()
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: true, sessionActive: false), .discover)
    }

    func testActiveBluetoothDiscoveryHandshakeOrHealthySessionIsNotRediscovered() async {
        var state = BluetoothPresenceConnectionState(restoredConnected: true)
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: true, sessionActive: true), .wait)
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: true, sessionActive: true), .wait,
                       "Repeated synchronization must preserve an active discovery, handshake, or channel")
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: true, sessionActive: false), .discover,
                       "An idle owned connection can rediscover after its previous session ends")
    }

    func testRecoveryContinuesBeyondOldRetryLimitWithCappedBackoff() async {
        var policy = BluetoothPresenceRetryPolicy()
        XCTAssertEqual((0..<10).map { policy.nextDelay(now: Double($0)) },
                       [1, 2, 4, 8, 16, 30, 30, 30, 30, 30])
        for attempt in 10..<1_000 {
            XCTAssertEqual(policy.nextDelay(now: Double(attempt)), 30,
                           "Retries must stay available rather than wait forever for an unrelated event")
        }
    }

    func testImmediateFrameworkFailuresCannotSpinConnectionRequests() async {
        var state = BluetoothPresenceConnectionState()
        var policy = BluetoothPresenceRetryPolicy()
        var now: TimeInterval = 0
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: false, sessionActive: false), .connect)
        for expectedDelay: TimeInterval in [1, 2, 4, 8, 16, 30, 30, 30] {
            // Model CoreBluetooth rejecting each submitted request immediately.
            state.disconnected()
            policy.nextDelay(now: now)
            for _ in 0..<100 {
                XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: false, sessionActive: false,
                                            retryDelay: policy.remainingDelay(now: now)), .retryAfter(expectedDelay))
                XCTAssertFalse(state.connectionPending, "A local cooldown is not a pending CoreBluetooth request")
            }
            now += expectedDelay
            XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: false, sessionActive: false,
                                        retryDelay: policy.remainingDelay(now: now)), .connect)
            XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: false, sessionActive: false,
                                        retryDelay: policy.remainingDelay(now: now)), .wait,
                           "Each elapsed deadline may submit only one request")
        }
    }

    func testForegroundAndRadioRecoveryRespectRemainingCooldown() async {
        var state = BluetoothPresenceConnectionState()
        var policy = BluetoothPresenceRetryPolicy()
        policy.nextDelay(now: 10)
        state.reconcile(peripheralDisconnected: true)
        XCTAssertEqual(state.action(poweredOn: false, peripheralConnected: false, sessionActive: false,
                                    retryDelay: policy.remainingDelay(now: 10.5)), .wait)
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: false, sessionActive: false,
                                    retryDelay: policy.remainingDelay(now: 10.5)), .retryAfter(0.5))
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: false, sessionActive: false,
                                    retryDelay: policy.remainingDelay(now: 300)), .connect,
                       "A suspended cooldown must not restart after the app resumes")
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: false, sessionActive: false,
                                    retryDelay: policy.remainingDelay(now: 301)), .wait,
                       "An out-of-range request stays pending without polling")
    }

    func testForegroundRepairsStalePendingConnectionWithoutDuplicatingValidRequest() async {
        var state = BluetoothPresenceConnectionState(restoredConnecting: true)
        state.reconcile(peripheralDisconnected: false)
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: false, sessionActive: false), .wait,
                       "A valid CoreBluetooth pending connection must remain owned by the system")
        state.reconcile(peripheralDisconnected: true)
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: false, sessionActive: false), .connect,
                       "Foreground must repair a pending flag when the OS has no connection")
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: false, sessionActive: false), .wait,
                       "The repaired connection is submitted exactly once")
    }

    func testForegroundCanRefreshPresenceWithoutReconnectingAnOwnedRadioLink() async {
        var state = BluetoothPresenceConnectionState(restoredConnected: true)
        state.reconcile(peripheralDisconnected: false)
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: true, sessionActive: true), .wait)
        XCTAssertEqual(state.action(poweredOn: true, peripheralConnected: true, sessionActive: false), .discover,
                       "Closing the old presence stream must permit a fresh handshake on the owned link")
    }

    func testBriefSuccessCannotResetRepeatedFailureBackoff() async {
        var policy = BluetoothPresenceRetryPolicy()
        XCTAssertEqual(policy.nextDelay(now: 0), 1)
        policy.connected(now: 1)
        XCTAssertEqual(policy.nextDelay(now: 2), 2)
        policy.connected(now: 4)
        XCTAssertEqual(policy.nextDelay(now: 5), 4)
    }

    func testStableConnectionResetsRetryBackoff() async {
        var policy = BluetoothPresenceRetryPolicy()
        for attempt in 0..<8 { _ = policy.nextDelay(now: Double(attempt)) }
        policy.connected(now: 10)
        XCTAssertEqual(policy.nextDelay(now: 70), 1)
        XCTAssertEqual(policy.nextDelay(now: 71), 2)
    }

    func testHandshakeRequiresMatchingResponseAndSupportsFragmentedFrames() async throws {
        let fixture = Fixture()
        let offer = fixture.commands.offer(registrationID: UUID())
        let handshake = try BluetoothPresenceHandshake(identity: HBBluetoothControllerIdentity(
            controllerID: offer.controllerID, displayName: "HomeBase", psm: 128), offer: offer)
        let requestData = try handshake.framedRequest()
        var decoder = HBBluetoothFrameDecoder()
        XCTAssertTrue(try decoder.append(requestData.prefix(3)).isEmpty)
        let request = try JSONDecoder().decode(HBProtocolEnvelope.self,
            from: XCTUnwrap(try decoder.append(requestData.dropFirst(3)).first))
        XCTAssertEqual(request.operation, HBBluetoothProtocol.presenceOpenOperation)
        let payload = try request.decodedPayload(as: HBBluetoothPresenceOpenRequest.self)
        XCTAssertEqual(payload.token, offer.token)
        var reply = try HBProtocolEnvelope.response(to: request, body: .success(
            HBBluetoothPresenceOpenResult(controllerID: offer.controllerID,
                registrationID: offer.registrationID, departureGraceSeconds: 10)))
        XCTAssertNoThrow(try handshake.accept(JSONEncoder().encode(reply)))
        reply.requestID = UUID()
        XCTAssertThrowsError(try handshake.accept(JSONEncoder().encode(reply)))
    }

    func testHandshakeRejectsAckForAnotherPhone() async throws {
        let fixture = Fixture()
        let offer = fixture.commands.offer(registrationID: UUID())
        let handshake = try BluetoothPresenceHandshake(identity: HBBluetoothControllerIdentity(
            controllerID: offer.controllerID, displayName: "HomeBase", psm: 128), offer: offer)
        let reply = try HBProtocolEnvelope.response(to: handshake.request, body: .success(
            HBBluetoothPresenceOpenResult(controllerID: offer.controllerID,
                registrationID: UUID(), departureGraceSeconds: 10)))
        XCTAssertThrowsError(try handshake.accept(JSONEncoder().encode(reply)))
    }

    private final class Fixture {
        let store = Store()
        let transport = Transport()
        let commands = Commands()
        let serverID = UUID()
        lazy var service = BluetoothPresenceService(store: store, transport: transport)
        func pair() async { await service.pair(serverID: serverID, name: "", client: commands) }
    }

    private final class Store: BluetoothPresenceStoring {
        var items: [BluetoothPresenceRegistration] = []
        var saves: [[BluetoothPresenceRegistration]] = []
        var failSave = false
        func load() throws -> [BluetoothPresenceRegistration] { items }
        func save(_ items: [BluetoothPresenceRegistration]) throws {
            if failSave { throw BluetoothPresenceError.persistence }
            self.items = items
            saves.append(items)
        }
    }

    private final class Transport: BluetoothPresenceTransporting {
        var onEvent: ((BluetoothPresenceTransportEvent) -> Void)?
        var synchronized: [[BluetoothPresenceRegistration]] = []
        var pickers: [BluetoothPresenceRegistration] = []
        var removed: [UUID] = []
        var pickerError: Error?
        func synchronize(_ registrations: [BluetoothPresenceRegistration]) { synchronized.append(registrations) }
        func showPicker(for registration: BluetoothPresenceRegistration) throws {
            pickers.append(registration)
            if let pickerError { throw pickerError }
        }
        func removeAccessory(peripheralID: UUID) { removed.append(peripheralID) }
        func retryConnections() {}
    }

    @MainActor
    private final class Commands: BluetoothPresenceCommanding {
        let controllerID: UUID
        init(controllerID: UUID = UUID()) { self.controllerID = controllerID }
        var begins = 0
        var renames = 0
        var removals = 0
        var removalAttempts = 0
        var failRemoval = false
        var suspendRemoval = false
        var pendingRemoval: CheckedContinuation<Void, Error>?
        var onRemoval: (() -> Void)?
        var onStatus: (() -> Void)?
        var failCancellation = false
        var cancellations: [UUID] = []
        var registered: [HBBluetoothRegisteredController] = []
        func offer(registrationID: UUID) -> HBBluetoothPairingOffer {
            HBBluetoothPairingOffer(controllerID: controllerID, registrationID: registrationID,
                token: "fixture-token", controllerName: "HomeBase", expiresAt: Date().timeIntervalSince1970 + 600)
        }
        func bluetoothStatus() async throws -> HBBluetoothControlStatus {
            onStatus?()
            return HBBluetoothControlStatus(controllerID: controllerID, displayName: "HomeBase", availability: .ready, controllers: registered)
        }
        func beginBluetoothPairing(registrationID: UUID, name: String) async throws -> HBBluetoothPairingOffer {
            begins += 1
            return offer(registrationID: registrationID)
        }
        func cancelBluetoothPairing(registrationID: UUID) async throws {
            if failCancellation { throw BluetoothPresenceError.invalidReply }
            cancellations.append(registrationID)
        }
        func removeBluetoothController(registrationID: UUID) async throws {
            removalAttempts += 1
            if suspendRemoval {
                try await withCheckedThrowingContinuation { continuation in
                    pendingRemoval = continuation
                    onRemoval?()
                }
            } else { onRemoval?() }
            if failRemoval { throw BluetoothPresenceError.invalidReply }
            removals += 1
        }
        func renameBluetoothController(registrationID: UUID, name: String) async throws { renames += 1 }
    }
}
