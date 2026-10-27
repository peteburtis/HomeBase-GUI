import Foundation
import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class BluetoothControlRoutingTests: XCTestCase {
    private func makeClient(_ fixture: RoutingFixture, timeout: Double = 2, bluetoothAvailable: Bool = true) -> HomeBaseWebSocketClient {
        HomeBaseWebSocketClient(endpoint: HomeBaseEndpoint(host: "routing.invalid", port: 10503)!,
            requestTimeout: timeout, makeControlSocket: { _ in fixture.webSocket() },
            makeBluetoothTransport: {
                guard bluetoothAvailable else { throw HomeBaseControlTransportError.unavailable }
                return try await fixture.bluetooth()
            })
    }
    private func eventually(attempts: Int = 500, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () async -> Bool) async {
        for _ in 0..<attempts {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Route did not reach the expected state", file: file, line: line)
    }

    func testWebSocketAdapterSendsJSONTextFrames() async throws {
        let socket = RoutingSocket(server: RoutingServer())
        let transport = HomeBaseWebSocketTransport(socket: socket)
        defer { transport.close() }
        let request = HBProtocolEnvelope(messageKind: .request, clientID: UUID(), operation: HBProtocolOperations.openSession)
        try await transport.send(JSONEncoder().encode(request))
        let response = try JSONDecoder().decode(HBProtocolEnvelope.self, from: await transport.receive())
        XCTAssertEqual(response.requestID, request.requestID)
        XCTAssertEqual(response.operation, HBProtocolOperations.openSession)
    }

    func testResponsiveWebSocketKeepsBluetoothCarrierWarmWithoutOpeningAnotherSession() async throws {
        let fixture = RoutingFixture()
        let client = makeClient(fixture)
        try await client.connect()
        let route = await client.currentControlRoute()
        XCTAssertEqual(route, .webSocket)
        await eventually { fixture.bluetoothCount == 1 }
        let summary = await fixture.server.summary()
        XCTAssertEqual(summary.openedRoutes, [.webSocket], "Warming Bluetooth must not create a second logical session")
        XCTAssertEqual(summary.resumes, 0)
        XCTAssertEqual(fixture.webSocketCount, 1, "Keep the first working network session instead of opening a second socket")
        await client.disconnect()
    }


    func testUnavailableBluetoothDoesNotMaskNetworkFailure() async throws {
        let fixture = RoutingFixture()
        await fixture.server.setNetworkAvailable(false)
        let client = makeClient(fixture, bluetoothAvailable: false)
        do { try await client.connect(); XCTFail("Both routes are unavailable") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        await client.disconnect()
    }

    func testUnavailableBluetoothDoesNotInterruptSlowWorkingWebSocket() async throws {
        let fixture = RoutingFixture()
        await fixture.server.setOpenDelay(.milliseconds(1_100))
        let client = makeClient(fixture, timeout: 3, bluetoothAvailable: false)
        try await client.connect()
        let route = await client.currentControlRoute()
        XCTAssertEqual(route, .webSocket)
        XCTAssertEqual(fixture.webSocketCount, 1)
        try await client.setControl("test.light", to: .bool(true))
        await client.disconnect()
    }

    func testUnavailableBluetoothDoesNotMaskNetworkRecoveryFailure() async throws {
        let fixture = RoutingFixture()
        let client = makeClient(fixture, bluetoothAvailable: false)
        try await client.connect()
        await fixture.server.loseNextMutationReply()
        do { try await client.setControl("test.light", to: .bool(true)); XCTFail("Neither route can recover") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        let summary = await fixture.server.summary()
        XCTAssertEqual(summary.mutationExecutions, 1)
        await client.disconnect()
    }

    func testSessionOpenDeadlineIncludesAStalledSend() async throws {
        let fixture = RoutingFixture(), client = makeClient(fixture, timeout: 0.15, bluetoothAvailable: false)
        await fixture.server.holdNextSessionOpenSend()
        var result: Result<Void, Error>?
        let connection = Task {
            do { try await client.connect(); result = .success(()) }
            catch { result = .failure(error) }
        }
        await eventually { await fixture.server.hasHeldSessionSend }
        await eventually(attempts: 100) { result != nil }
        XCTAssertNotNil(result, "The connection deadline must include a send that never returns")
        await fixture.server.releaseSessionSend()
        await connection.value
        switch result {
        case .failure(let error): XCTAssertEqual((error as? URLError)?.code, .timedOut)
        default: XCTFail("A stalled session open must time out")
        }
        let route = await client.currentControlRoute()
        XCTAssertNil(route)
        await client.disconnect()
    }

    func testStalledReplaySendCannotHoldNewCommandsBehindHandover() async throws {
        let fixture = RoutingFixture(), client = makeClient(fixture, timeout: 0.2)
        try await client.connect()
        await fixture.server.holdNextBluetoothReplaySend()
        await fixture.server.loseNextMutationReply()
        let original = Task { try await client.setControl("test.light", to: .bool(true)) }
        await eventually { await fixture.server.hasHeldReplaySend }
        var nextResult: Result<Void, Error>?
        let nextCommand = Task {
            do { try await client.setControl("test.light", to: .bool(false)); nextResult = .success(()) }
            catch { nextResult = .failure(error) }
        }
        await eventually(attempts: 100) { nextResult != nil }
        XCTAssertNotNil(nextResult, "New commands must not wait forever for a stalled replay send")
        if case .success = nextResult { XCTFail("The broken resumed carrier must not accept a new command") }
        await fixture.server.releaseReplaySend()
        await nextCommand.value
        _ = await original.result
        let summary = await fixture.server.summary()
        XCTAssertEqual(summary.mutationExecutions, 1, "A replay may not repeat the uncertain mutation or issue the blocked command")
        await client.disconnect()
    }

    func testFastWebSocketFailureUsesReadyBluetoothBeforePreferenceDelay() async throws {
        let fixture = RoutingFixture()
        await fixture.server.setNetworkAvailable(false)
        let client = makeClient(fixture)
        let start = ContinuousClock.now
        try await client.connect()
        let route = await client.currentControlRoute()
        XCTAssertEqual(route, .bluetooth)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(900))
        do { _ = try await client.openCameraLiveStream(deviceIdentifier: "camera", quality: .low); XCTFail("BLE must not issue media tickets") }
        catch { XCTAssertEqual(error.localizedDescription, HomeBaseControlTransportError.networkRequired.localizedDescription) }
        await client.disconnect()
    }

    func testBackgroundNeverCreatesBluetoothControlDemand() async throws {
        let fixture = RoutingFixture()
        await fixture.server.setNetworkAvailable(false)
        let client = makeClient(fixture)
        await client.setForeground(false)
        do { try await client.connect(); XCTFail("The network is unavailable") } catch { }
        XCTAssertEqual(fixture.bluetoothCount, 0)
        await client.disconnect()
    }

    func testForegroundRecoveryIncludesBluetoothWhenChildStartsBeforeActivation() async throws {
        let fixture = RoutingFixture()
        await fixture.server.setNetworkAvailable(false)
        let client = makeClient(fixture)
        try await client.connect()
        let originalSession = await client.currentSessionIdentifier()
        await client.setForeground(false)

        // Child screen lifecycle callbacks can run before the parent publishes
        // foreground demand. Hold the resulting network attempt across that
        // transition, with Bluetooth still ready and the network unavailable.
        await fixture.server.holdNextNetworkAttempt()
        let child = Task { try await client.reactivate() }
        await eventually { await fixture.server.hasHeldNetworkAttempt }
        await client.setForeground(true)
        let parent = Task { try await client.reactivate() }
        await fixture.server.releaseNetworkAttempt()

        let childResult = await child.result
        let parentResult = await parent.result
        if case .failure(let error) = childResult {
            XCTFail("Foreground activation must enable BLE for the waiting child: \(error)")
        }
        if case .failure(let error) = parentResult {
            XCTFail("The parent's foreground recovery must also succeed: \(error)")
        }
        let route = await client.currentControlRoute()
        let resumedSession = await client.currentSessionIdentifier()
        let summary = await fixture.server.summary()
        XCTAssertEqual(route, .bluetooth)
        XCTAssertEqual(resumedSession, originalSession)
        XCTAssertEqual(fixture.bluetoothCount, 2, "Reopen only the suspended logical Bluetooth route")
        XCTAssertEqual(summary.mutationExecutions, 0)
        await client.disconnect()
    }

    func testLostMutationReplyResumesSameSessionAndReplaysSameRequestOnlyOnce() async throws {
        let fixture = RoutingFixture()
        let client = makeClient(fixture)
        try await client.connect()
        let session = await client.currentSessionIdentifier()
        await fixture.server.loseNextMutationReply()
        try await client.setControl("test.light", to: .bool(true))
        let resumed = await client.currentSessionIdentifier()
        let route = await client.currentControlRoute()
        let summary = await fixture.server.summary()
        XCTAssertEqual(session, resumed)
        XCTAssertEqual(route, .bluetooth)
        XCTAssertEqual(summary.mutationExecutions, 1)
        XCTAssertEqual(summary.mutationIDs.count, 2)
        XCTAssertEqual(Set(summary.mutationIDs).count, 1)
        XCTAssertEqual(summary.resumes, 1)
        await client.disconnect()
    }

    func testPendingRequestDeadlineSurvivesSuccessfulHandover() async throws {
        let fixture = RoutingFixture()
        let client = makeClient(fixture, timeout: 0.4)
        try await client.connect()
        await fixture.server.loseNextMutationReply(ignoreReplay: true)
        let start = ContinuousClock.now
        do { try await client.setControl("test.light", to: .bool(true)); XCTFail("A silent replay must time out") }
        catch { XCTAssertEqual(error.localizedDescription, HomeBaseControlTransportError.requestTimedOut.localizedDescription) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        let route = await client.currentControlRoute()
        XCTAssertEqual(route, .bluetooth)
        let summary = await fixture.server.summary()
        XCTAssertEqual(summary.mutationExecutions, 1)
        await client.disconnect()
    }

    func testRejectedResumeNeverMovesUncertainMutationIntoFreshSession() async throws {
        let fixture = RoutingFixture()
        let client = makeClient(fixture)
        try await client.connect()
        await fixture.server.loseNextMutationReply(rejectResume: true)
        do { try await client.setControl("test.light", to: .bool(true)); XCTFail("Expired session must fail its pending work") }
        catch {
            XCTAssertTrue(error is HomeBaseSessionResetError)
            XCTAssertEqual(error.localizedDescription,
                "The connection was interrupted. Check the current state before trying again.")
        }
        await eventually { await client.currentControlRoute() == .bluetooth }
        let summary = await fixture.server.summary()
        XCTAssertEqual(summary.mutationExecutions, 1)
        XCTAssertEqual(summary.mutationIDs.count, 1)
        await client.disconnect()
    }

    func testForegroundWithExpiredSessionRecoversWithoutAnotherForegroundOrRetry() async throws {
        // Paired servers enable route recovery even when Bluetooth is not in
        // range. Exercise both that case and an available Bluetooth fallback.
        for bluetoothAvailable in [false, true] {
            let fixture = RoutingFixture()
            let client = makeClient(fixture, timeout: 0.15, bluetoothAvailable: bluetoothAvailable)
            let model = ServerConnectionModel(client: client)
            await model.load()
            XCTAssertEqual(model.state, .connected)
            let original = await client.currentSessionIdentifier()
            await client.setForeground(false)
            await fixture.server.expireCurrentSession()
            await client.setForeground(true)
            var states: [HomeBaseControlConnectionState] = []
            let observation = Task {
                for await state in await client.controlConnectionStates() { states.append(state) }
            }
            defer { observation.cancel() }

            async let parent: Void = model.reactivate()
            async let child: Void = client.reactivate()
            await parent
            try await child

            XCTAssertEqual(model.state, .connected)
            let replacement = await client.currentSessionIdentifier()
            XCTAssertNotNil(replacement)
            XCTAssertNotEqual(replacement, original)
            let route = await client.currentControlRoute()
            XCTAssertEqual(route, .webSocket)
            let summary = await fixture.server.summary()
            XCTAssertEqual(summary.resumes, 1)
            XCTAssertEqual(summary.mutationExecutions, 0)
            XCTAssertFalse(states.contains { $0.error != nil }, "Expected expiry must stay in recovery, without a failed badge")
            await client.disconnect()
        }
    }

    func testExpiredSessionRecoversOverBluetoothWhenNetworkIsUnavailable() async throws {
        let fixture = RoutingFixture(), client = makeClient(fixture, timeout: 0.15)
        try await client.connect()
        let original = await client.currentSessionIdentifier()
        await client.setForeground(false)
        await fixture.server.expireCurrentSession()
        await fixture.server.setNetworkAvailable(false)
        await client.setForeground(true)
        try await client.reactivate()
        let route = await client.currentControlRoute()
        let replacement = await client.currentSessionIdentifier()
        XCTAssertEqual(route, .bluetooth)
        XCTAssertNotNil(replacement)
        XCTAssertNotEqual(replacement, original)
        await client.disconnect()
    }

    func testExpiredDetachedBluetoothSessionStartsFreshOnForeground() async throws {
        let fixture = RoutingFixture(), client = makeClient(fixture)
        await fixture.server.setNetworkAvailable(false)
        try await client.connect()
        let original = await client.currentSessionIdentifier()
        await client.setForeground(false)
        await fixture.server.expireCurrentSession()
        await client.setForeground(true)
        try await client.reactivate()
        let route = await client.currentControlRoute()
        let replacement = await client.currentSessionIdentifier()
        XCTAssertEqual(route, .bluetooth)
        XCTAssertNotEqual(replacement, original)
        await client.disconnect()
    }

    func testExpiredSessionRecoversUsingWarmBluetoothAfterNetworkHealthCheckFails() async throws {
        let fixture = RoutingFixture(), client = makeClient(fixture, timeout: 0.15)
        try await client.connect()
        let original = await client.currentSessionIdentifier()
        await fixture.server.expireCurrentSession()
        try await client.reactivate()
        let replacement = await client.currentSessionIdentifier()
        XCTAssertNotNil(replacement)
        XCTAssertNotEqual(replacement, original)
        let summary = await fixture.server.summary()
        XCTAssertEqual(summary.resumes, 1, "A warm Bluetooth carrier can reject the expired session without another network resume")
        XCTAssertEqual(summary.openedRoutes.count, 2, "Recovery opens one replacement session after the expired session is rejected")
        await client.disconnect()
    }

    func testFailedFreshConnectionReportsActualFailureAndStopsRetrying() async throws {
        let fixture = RoutingFixture(), client = makeClient(fixture, timeout: 0.15, bluetoothAvailable: false)
        try await client.connect()
        await fixture.server.expireCurrentSession()
        await fixture.server.failFreshConnections()
        do { try await client.reactivate(); XCTFail("The fresh connection must fail") }
        catch { XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost) }
        let session = await client.currentSessionIdentifier()
        let route = await client.currentControlRoute()
        XCTAssertNil(session)
        XCTAssertNil(route)
        let summary = await fixture.server.summary()
        XCTAssertEqual(summary.resumes, 1)
        XCTAssertEqual(fixture.webSocketCount, 3, "Initial, rejected resume, one fresh attempt; readiness does not open a probe session")
        await client.disconnect()
    }

    func testDisconnectDuringFreshRecoveryDoesNotResurrectConnection() async throws {
        let fixture = RoutingFixture(), client = makeClient(fixture, timeout: 0.15)
        try await client.connect()
        await fixture.server.expireCurrentSession()
        await fixture.server.holdFreshConnection()
        let recovery = Task { try await client.reactivate() }
        await eventually { await fixture.server.hasHeldNetworkAttempt }
        await client.disconnect()
        await fixture.server.releaseNetworkAttempt()
        do { try await recovery.value; XCTFail("Disconnect must cancel the fresh attempt") }
        catch { XCTAssertTrue(error is CancellationError) }
        let session = await client.currentSessionIdentifier()
        let route = await client.currentControlRoute()
        XCTAssertNil(session)
        XCTAssertNil(route)
    }

    func testLateCarrierFailureAfterDisconnectDoesNotRestartSession() async throws {
        let fixture = RoutingFixture(), client = makeClient(fixture, bluetoothAvailable: false)
        await fixture.server.holdNextNetworkAttempt()
        let connection = Task { try await client.connect() }
        await eventually { await fixture.server.hasHeldNetworkAttempt }
        await client.disconnect()
        do { try await connection.value; XCTFail("Disconnect must cancel connection acquisition") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fixture.server.setNetworkAvailable(false)
        await fixture.server.releaseNetworkAttempt()
        await eventually { await fixture.server.completedNetworkReadiness == 1 }
        let route = await client.currentControlRoute()
        let session = await client.currentSessionIdentifier()
        let summary = await fixture.server.summary()
        XCTAssertNil(route)
        XCTAssertNil(session)
        XCTAssertTrue(summary.openedRoutes.isEmpty)
        XCTAssertEqual(fixture.webSocketCount, 1, "A stale carrier failure must not create another attempt after disconnect")
    }

    func testLiveControlsReloadAndReceiveEventsAfterSessionReplacement() async throws {
        let fixture = RoutingFixture(), client = makeClient(fixture)
        let model = LiveDeviceControlsModel(device: .init(identifier: "test", addressableName: "test", displayName: "Test"), client: client)
        let monitoring = Task { await model.run(reactivating: true) }
        defer { monitoring.cancel() }
        await eventually { model.state == .live }
        await fixture.server.expireCurrentSession()
        await fixture.server.setNetworkAvailable(false)
        fixture.closeLatestWebSocket()
        await eventually {
            let summary = await fixture.server.summary()
            return summary.subscriptions == 2 && model.state == .live
        }
        let subscriptionID = await fixture.server.latestSubscriptionID()
        let identifier = try XCTUnwrap(subscriptionID)
        try await fixture.sendControlEvent(subscriptionID: identifier)
        await eventually { model.controls.first?.value == .bool(true) }
        let route = await client.currentControlRoute()
        XCTAssertEqual(route, .bluetooth)
        monitoring.cancel()
        await monitoring.value
        await client.disconnect()
    }

    func testConcurrentCarrierRecoveryResumesOnlySelectedRoute() async throws {
        let fixture = RoutingFixture()
        await fixture.server.setReadinessDelay(.milliseconds(300), route: .bluetooth)
        let client = makeClient(fixture)
        try await client.connect()
        let originalSession = await client.currentSessionIdentifier()
        await fixture.server.setReadinessDelay(.milliseconds(20), route: .webSocket)
        fixture.closeLatestWebSocket()
        await eventually { await fixture.server.summary().resumes == 1 }
        await eventually { await client.currentControlRoute() != nil }
        await eventually { await fixture.server.readyCount(for: .bluetooth) == 1 }
        let summary = await fixture.server.summary()
        let session = await client.currentSessionIdentifier()
        XCTAssertEqual(summary.resumes, 1, "Only the selected carrier may resume the shared session")
        XCTAssertEqual(summary.openedRoutes.count, 1, "Carrier readiness must not allocate probe sessions")
        XCTAssertEqual(session, originalSession)
        try await client.setControl("test.light", to: .bool(false))
        await client.disconnect()
    }

    func testSubscriptionSurvivesRouteChangeWithoutNewSubscription() async throws {
        let fixture = RoutingFixture()
        let client = makeClient(fixture)
        try await client.connect()
        let subscription = try await client.subscribe(to: .init(identifier: "test", addressableName: "test", displayName: "Test"))
        let received = Task { () throws -> HBControlWatchStreamEvent? in
            for try await event in subscription.events { return event }
            return nil
        }
        await fixture.server.setNetworkAvailable(false)
        fixture.closeLatestWebSocket()
        await eventually { await client.currentControlRoute() == .bluetooth }
        try await fixture.sendControlEvent(subscriptionID: subscription.identifier)
        let event = try await received.value
        XCTAssertEqual(event?.subscriptionID, subscription.identifier)
        XCTAssertEqual(event?.value, .bool(true))
        let count = await fixture.server.summary().subscriptions
        XCTAssertEqual(count, 1)
        await client.disconnect()
    }

    func testForegroundExitDetachesControlWithoutRemovingPairing() async throws {
        let fixture = RoutingFixture()
        await fixture.server.setNetworkAvailable(false)
        let client = makeClient(fixture)
        try await client.connect()
        await client.setForeground(false)
        let route = await client.currentControlRoute()
        XCTAssertNil(route)
        XCTAssertEqual(fixture.bluetoothCount, 1)
        await client.disconnect()
    }

    func testWarmBluetoothCarrierIsReusedWhenWebSocketFails() async throws {
        let fixture = RoutingFixture(), client = makeClient(fixture)
        try await client.connect()
        await eventually { await fixture.server.readyCount(for: .bluetooth) == 1 }
        let initial = await client.currentSessionIdentifier()
        await fixture.server.setNetworkAvailable(false)
        fixture.closeLatestWebSocket()
        await eventually { await client.currentControlRoute() == .bluetooth }
        let resumed = await client.currentSessionIdentifier()
        let summary = await fixture.server.summary()
        XCTAssertEqual(resumed, initial)
        XCTAssertEqual(fixture.bluetoothCount, 1, "The standby carrier should be used without reconnecting Bluetooth")
        XCTAssertEqual(summary.openedRoutes, [.webSocket])
        XCTAssertEqual(summary.resumes, 1)
        try await client.setControl("test.light", to: .bool(true))
        await client.disconnect()
    }

    func testBluetoothForegroundRecoveryDoesNotWaitForSilentNetworkReadiness() async throws {
        let fixture = RoutingFixture(), client = makeClient(fixture)
        await fixture.server.setNetworkAvailable(false)
        try await client.connect()
        let initial = await client.currentSessionIdentifier()
        await client.setForeground(false)
        await fixture.server.holdNextNetworkAttempt()
        await fixture.server.setReadinessDelay(.milliseconds(100), route: .bluetooth)
        await client.setForeground(true)
        var recovered = false
        let recovery = Task {
            try await client.reactivate()
            recovered = true
        }
        await eventually { await fixture.server.hasHeldNetworkAttempt }
        await eventually(attempts: 100) { recovered }
        let route = await client.currentControlRoute()
        let resumed = await client.currentSessionIdentifier()
        XCTAssertTrue(recovered, "A usable Bluetooth carrier must not wait for the network attempt or its teardown")
        XCTAssertEqual(route, .bluetooth)
        XCTAssertEqual(resumed, initial)
        // Release the deliberately uncooperative network fake after proving
        // that its pending readiness did not block session restoration.
        await fixture.server.releaseNetworkAttempt()
        try await recovery.value
        try await client.setControl("test.light", to: .bool(true))
        await client.disconnect()
    }

    func testRepeatedBluetoothBackgroundForegroundRestoresSameSession() async throws {
        let fixture = RoutingFixture(), client = makeClient(fixture)
        await fixture.server.setNetworkAvailable(false)
        let model = ServerConnectionModel(client: client)
        await model.load()
        let initial = await client.currentSessionIdentifier()
        for _ in 0..<3 {
            await client.setForeground(false)
            await fixture.server.setReadinessDelay(.milliseconds(50), route: .bluetooth)
            await client.setForeground(true)
            await model.reactivate()
            await eventually { model.state == .connected && model.route == .bluetooth }
            let resumed = await client.currentSessionIdentifier()
            XCTAssertEqual(resumed, initial)
            try await client.setControl("test.light", to: .bool(true))
        }
        let summary = await fixture.server.summary()
        XCTAssertEqual(summary.resumes, 3)
        XCTAssertEqual(summary.openedRoutes, [.bluetooth])
        XCTAssertEqual(fixture.bluetoothCount, 4)
        await client.disconnect()
    }

    func testEmptyHomeReturnsToConnectedAfterHandover() async throws {
        let fixture = RoutingFixture()
        let client = makeClient(fixture)
        let model = ServerConnectionModel(client: client)
        await model.load()
        XCTAssertEqual(model.state, .connected)
        XCTAssertTrue(model.topology.devices.isEmpty)
        await fixture.server.setNetworkAvailable(false)
        fixture.closeLatestWebSocket()
        await eventually { model.route == .bluetooth && model.state == .connected }
        await client.disconnect()
    }

    func testChildReconnectRestoresFailedRootWithPreviouslyLoadedTopology() async throws {
        let fixture = RoutingFixture()
        let client = makeClient(fixture, bluetoothAvailable: false)
        let model = ServerConnectionModel(client: client)
        await model.load()
        XCTAssertEqual(model.state, .connected)

        await fixture.server.setNetworkAvailable(false)
        fixture.closeLatestWebSocket()
        await eventually { if case .failed = model.state { return true }; return false }
        XCTAssertNil(model.route)

        await fixture.server.holdNextNetworkAttempt()
        await fixture.server.setNetworkAvailable(true)
        // A child screen reactivates the shared client without calling model.load.
        // Hold carrier readiness so the test observes Connecting rather than
        // relying on polling catching a completed session resume in flight.
        let childRetry = Task { try await client.reactivate() }
        await eventually { await fixture.server.hasHeldNetworkAttempt }
        await eventually { model.state == .connecting }
        await fixture.server.releaseNetworkAttempt()
        try await childRetry.value
        await eventually { model.state == .connected && model.route == .webSocket }
        XCTAssertTrue(model.topology.devices.isEmpty, "A valid empty cached topology also recovers")
        await client.disconnect()
    }

    func testChildReconnectDoesNotClaimTopologyLoadedAfterInitialFailure() async throws {
        let fixture = RoutingFixture()
        await fixture.server.setNetworkAvailable(false)
        let client = makeClient(fixture, bluetoothAvailable: false)
        let model = ServerConnectionModel(client: client)
        await model.load()
        guard case .failed = model.state else { return XCTFail("Initial loading must fail while offline") }

        await fixture.server.setNetworkAvailable(true)
        try await client.reactivate()
        await eventually { model.route == .webSocket }
        guard case .failed = model.state else { return XCTFail("A route alone does not load the home's topology") }
        await model.load()
        XCTAssertEqual(model.state, .connected)
        await client.disconnect()
    }

    func testStableNetworkReturnResumesSameSessionAndRetainsSubscription() async throws {
        let fixture = RoutingFixture()
        await fixture.server.setNetworkAvailable(false)
        let client = makeClient(fixture)
        try await client.connect()
        let session = await client.currentSessionIdentifier()
        let subscription = try await client.subscribe(to: .init(identifier: "test", addressableName: "test", displayName: "Test"))
        await fixture.server.setNetworkAvailable(true)
        await client.checkPreferredControlRoute()
        let route = await client.currentControlRoute()
        let resumed = await client.currentSessionIdentifier()
        XCTAssertEqual(route, .webSocket)
        XCTAssertEqual(session, resumed)
        let summary = await fixture.server.summary()
        XCTAssertEqual(summary.resumes, 1)
        XCTAssertEqual(summary.openedRoutes, [.bluetooth], "Returning to WebSocket reuses the session without opening a probe")
        XCTAssertEqual(summary.subscriptions, 1)
        try await client.setControl("test.light", to: .bool(true))
        await client.disconnect()
        _ = subscription
    }

    func testWebSocketReturnAutomaticallyResumesTheBluetoothSession() async throws {
        let fixture = RoutingFixture(), client = makeClient(fixture)
        await fixture.server.setNetworkAvailable(false)
        try await client.connect()
        let original = await client.currentSessionIdentifier()
        await fixture.server.setNetworkAvailable(true)
        // No foreground event, control command, or explicit route check is
        // needed: coordinator readiness must drive the handover itself.
        await eventually { await client.currentControlRoute() == .webSocket }
        let resumed = await client.currentSessionIdentifier()
        let summary = await fixture.server.summary()
        XCTAssertEqual(resumed, original)
        XCTAssertEqual(summary.resumes, 1)
        XCTAssertEqual(summary.openedRoutes, [.bluetooth])
        await client.disconnect()
    }

    func testNetworkReturnWithExpiredBluetoothSessionOpensFreshSession() async throws {
        let fixture = RoutingFixture(), client = makeClient(fixture)
        await fixture.server.setNetworkAvailable(false)
        try await client.connect()
        let original = await client.currentSessionIdentifier()
        await fixture.server.expireCurrentSession()
        await fixture.server.setNetworkAvailable(true)
        await client.checkPreferredControlRoute()
        let replacement = await client.currentSessionIdentifier()
        XCTAssertNotNil(replacement)
        XCTAssertNotEqual(replacement, original)
        // Session replacement may first use the ready Bluetooth carrier while
        // the rejected WebSocket attachment is rewarming. Preference applies
        // again when the network carrier becomes ready.
        await eventually { await client.currentControlRoute() == .webSocket }
        let preferredSession = await client.currentSessionIdentifier()
        XCTAssertEqual(preferredSession, replacement)
        let summary = await fixture.server.summary()
        XCTAssertGreaterThanOrEqual(summary.resumes, 1)
        XCTAssertEqual(summary.openedRoutes.count, 2, "Returning to the preferred carrier must retain the replacement session")
        await client.disconnect()
    }

    func testCarrierRetriesContinueAfterFreshRecoveryFallsBackToBluetooth() async throws {
        let fixture = RoutingFixture(), client = makeClient(fixture)
        await fixture.server.setNetworkAvailable(false)
        try await client.connect()
        let original = await client.currentSessionIdentifier()
        await fixture.server.expireCurrentSession()
        await fixture.server.dropNetworkOnNextFreshConnection()
        await fixture.server.setNetworkAvailable(true)

        // Let the coordinator retry the network carrier. The carrier is ready,
        // but the network drops as the expired session is replaced over Bluetooth.
        await eventually(attempts: 2_500) {
            let session = await client.currentSessionIdentifier()
            let route = await client.currentControlRoute()
            return session != nil && session != original && route == .bluetooth
        }
        await fixture.server.setNetworkAvailable(true)
        await eventually(attempts: 2_500) { await client.currentControlRoute() == .webSocket }
        await client.disconnect()
    }

    func testFailedNetworkCarrierLeavesBluetoothSessionUsable() async throws {
        let fixture = RoutingFixture()
        await fixture.server.setNetworkAvailable(false)
        let client = makeClient(fixture)
        try await client.connect()
        let session = await client.currentSessionIdentifier()
        await client.checkPreferredControlRoute()
        let route = await client.currentControlRoute()
        let retained = await client.currentSessionIdentifier()
        XCTAssertEqual(route, .bluetooth)
        XCTAssertEqual(retained, session)
        try await client.setControl("test.light", to: .bool(true))
        let summary = await fixture.server.summary()
        XCTAssertEqual(summary.resumes, 0)
        await client.disconnect()
    }

    func testPendingMutationsReplayInOriginalOrder() async throws {
        let fixture = RoutingFixture()
        let client = makeClient(fixture)
        try await client.connect()
        await fixture.server.holdNetworkMutations()
        let first = Task { try await client.setControl("test.light", to: .bool(true)) }
        await eventually { await fixture.server.summary().mutationIDs.count == 1 }
        let second = Task { try await client.setControl("test.light", to: .bool(false)) }
        await eventually { await fixture.server.summary().mutationIDs.count == 2 }
        await fixture.server.setNetworkAvailable(false)
        fixture.closeLatestWebSocket()
        try await first.value
        try await second.value
        let values = await fixture.server.completedMutationValues()
        XCTAssertEqual(values, [.bool(true), .bool(false)])
        await client.disconnect()
    }

    func testCurrentPairingRefreshesCredentialAndAcknowledgesSecretOverWebSocket() async throws {
        let serverID = UUID(), registrationID = UUID(), controllerID = UUID()
        let credential = HBBluetoothCnCCredential(controllerID: controllerID, registrationID: registrationID,
            keyID: UUID(), secret: Data(repeating: 7, count: 32))
        let store = CredentialStore(items: [.init(serverID: serverID, registrationID: registrationID, name: "Phone",
            phase: .paired, offer: .init(controllerID: controllerID, registrationID: registrationID, userID: UUID(), clientID: serverID, credential: credential,
                controllerName: "HomeBase", expiresAt: 0), peripheralID: UUID(), controllerID: controllerID)])
        let service = BluetoothPresenceService(store: store, transport: CredentialPresenceTransport())
        let fixture = RoutingFixture()
        await fixture.server.setCredential(credential)
        let client = HomeBaseWebSocketClient(endpoint: HomeBaseEndpoint(host: "routing.invalid", port: 10503)!,
            clientID: serverID, requestTimeout: 2, makeControlSocket: { _ in fixture.webSocket() },
            bluetoothServerID: serverID, bluetoothService: service, makeBluetoothTransport: { try await fixture.bluetooth() })
        try await client.connect()
        XCTAssertEqual(store.items.first?.cncCredential, credential)
        XCTAssertEqual(store.items.first?.cncClientID, serverID)
        XCTAssertEqual(store.items.first?.offer?.credential, credential)
        let summary = await fixture.server.upgradeSummary()
        XCTAssertEqual(summary.0, 1)
        XCTAssertEqual(summary.1, 1, "The credential delivery must be acknowledged before fallback can resume its session")
        let restored = BluetoothPresenceService(store: store, transport: CredentialPresenceTransport())
        restored.start()
        XCTAssertEqual(restored.registration(for: serverID)?.cncClientID, serverID)
        await client.disconnect()
    }

    func testFailbackUpgradeCannotDeadlockAcknowledgementQueuedDuringResumeReplay() async throws {
        let serverID = UUID(), registrationID = UUID(), controllerID = UUID()
        let credential = HBBluetoothCnCCredential(controllerID: controllerID, registrationID: registrationID,
            keyID: UUID(), secret: Data(repeating: 9, count: 32))
        let store = CredentialStore(items: [.init(serverID: serverID, registrationID: registrationID, name: "Phone",
            phase: .paired, offer: .init(controllerID: controllerID, registrationID: registrationID, userID: UUID(), clientID: serverID, credential: credential,
                controllerName: "HomeBase", expiresAt: 0), peripheralID: UUID(), controllerID: controllerID)])
        let service = BluetoothPresenceService(store: store, transport: CredentialPresenceTransport())
        let fixture = RoutingFixture()
        await fixture.server.setCredential(credential)
        let client = HomeBaseWebSocketClient(endpoint: HomeBaseEndpoint(host: "routing.invalid", port: 10503)!,
            clientID: serverID, requestTimeout: 2, makeControlSocket: { _ in fixture.webSocket() },
            bluetoothServerID: serverID, bluetoothService: service, makeBluetoothTransport: { try await fixture.bluetooth() })
        try await client.connect()
        let subscription = try await client.subscribe(to: .init(identifier: "test", addressableName: "test", displayName: "Test"))
        await fixture.server.setNetworkAvailable(false)
        fixture.closeLatestWebSocket()
        await eventually { await client.currentControlRoute() == .bluetooth }
        await fixture.server.replayEventOnNextResume(subscription.identifier)
        await fixture.server.setNetworkAvailable(true)
        await client.checkPreferredControlRoute()
        await eventually {
            let summary = await fixture.server.upgradeSummary()
            return summary.0 == 2 && summary.1 >= 3
        }
        let route = await client.currentControlRoute()
        XCTAssertEqual(route, .webSocket)
        await client.disconnect()
        _ = subscription
    }

    func testCredentialCannotBeSavedForAnotherControllerOrRegistration() async throws {
        let serverID = UUID(), registrationID = UUID(), controllerID = UUID()
        let credential = HBBluetoothCnCCredential(controllerID: controllerID, registrationID: registrationID,
            keyID: UUID(), secret: Data(repeating: 7, count: 32))
        let store = CredentialStore(items: [.init(serverID: serverID, registrationID: registrationID, name: "Phone", phase: .paired,
            offer: .init(controllerID: controllerID, registrationID: registrationID, userID: UUID(), clientID: serverID, credential: credential, controllerName: "HomeBase", expiresAt: 0),
            peripheralID: UUID(), controllerID: controllerID)])
        let service = BluetoothPresenceService(store: store, transport: CredentialPresenceTransport())
        service.start()
        let wrong = HBBluetoothCnCCredential(controllerID: UUID(), registrationID: registrationID, keyID: UUID(), secret: Data(repeating: 1, count: 32))
        XCTAssertThrowsError(try service.saveControlCredential(wrong, serverID: serverID, clientID: serverID))
        XCTAssertNil(store.items.first?.cncCredential)
        do { _ = try await service.controlTransport(serverID: serverID, clientID: serverID); XCTFail("A missing cached transport credential must not authorize CnC") } catch { }
    }

    func testAttachmentDiscardsOldQueuedMessagesUntilMatchingResumeResponse() async throws {
        let clientID = UUID()
        let request = HBProtocolEnvelope(messageKind: .request, clientID: clientID, operation: HBProtocolOperations.resumeSession)
        var state = BluetoothCnCAttachmentState()
        state.begin(request)
        let oldReply = HBProtocolEnvelope(messageKind: .response, clientID: clientID, operation: HBProtocolOperations.setControl)
        XCTAssertEqual(state.receive(oldReply), .discard)
        let staleDetach = HBProtocolEnvelope(messageKind: .event, clientID: clientID, operation: "bluetooth.cnc.detached")
        XCTAssertEqual(state.receive(staleDetach), .discard)
        let response = try HBProtocolEnvelope.response(to: request, body: .successWithoutResult)
        XCTAssertEqual(state.receive(response), .message)
        XCTAssertEqual(state.receive(oldReply), .message, "After matching handshake the server FIFO contains this attachment's deliveries")
        let currentDetach = HBProtocolEnvelope(messageKind: .event, requestID: request.requestID, clientID: clientID, operation: "bluetooth.cnc.detached")
        XCTAssertEqual(state.receive(currentDetach), .detached)
        XCTAssertEqual(state.receive(oldReply), .discard)
    }

}

private nonisolated final class RoutingFixture: @unchecked Sendable {
    let server = RoutingServer()
    private let lock = NSLock()
    private var sockets: [RoutingSocket] = []
    private var bluetoothTransports: [RoutingTransport] = []
    var bluetoothCount: Int { lock.withLock { bluetoothTransports.count } }
    var webSocketCount: Int { lock.withLock { sockets.count } }
    func webSocket() -> any HomeBaseControlSocket {
        let socket = RoutingSocket(server: server)
        lock.withLock { sockets.append(socket) }
        return socket
    }
    func bluetooth() async throws -> any HomeBaseControlTransport {
        try Task.checkCancellation()
        let transport = RoutingTransport(route: .bluetooth, server: server)
        lock.withLock { bluetoothTransports.append(transport) }
        return transport
    }
    func closeLatestWebSocket() { lock.withLock { sockets.last }?.cancel(with: .goingAway, reason: nil) }
    func sendControlEvent(subscriptionID: UUID) async throws {
        guard let transport = lock.withLock({ bluetoothTransports.last }) else { throw URLError(.notConnectedToInternet) }
        let event = try await server.event(subscriptionID: subscriptionID)
        await transport.inbox.push(try JSONEncoder().encode(event))
    }
}

private nonisolated final class RoutingSocket: HomeBaseControlSocket, @unchecked Sendable {
    let transport: RoutingTransport
    var maximumMessageSize: Int { get { 16 * 1_024 * 1_024 } set {} }
    init(server: RoutingServer) { transport = RoutingTransport(route: .webSocket, server: server) }
    func observeLifecycle(onOpen: @escaping @Sendable () -> Void, onClose: @escaping @Sendable (Error?) -> Void) {
        Task { [transport] in
            do {
                try await transport.waitUntilReady()
                onOpen()
                await transport.waitUntilClosed()
                onClose(nil)
            }
            catch { onClose(error) }
        }
    }
    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { transport.close() }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        switch message {
        case .data: throw URLError(.badServerResponse) // The real control server rejects binary frames.
        case .string(let value): try await transport.send(Data(value.utf8))
        @unknown default: throw URLError(.badServerResponse)
        }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message { .data(try await transport.receive()) }
}

private nonisolated final class RoutingTransport: HomeBaseControlTransport, @unchecked Sendable {
    let route: HomeBaseControlRoute
    let server: RoutingServer
    let inbox = RoutingInbox()
    private let lifecycle = HomeBaseTransportLifecycle()
    private let readiness: Task<Void, Never>
    init(route: HomeBaseControlRoute, server: RoutingServer) {
        self.route = route; self.server = server
        readiness = Task { [lifecycle] in
            do {
                try await server.waitUntilReady(route: route)
                try Task.checkCancellation()
                lifecycle.opened()
            } catch { lifecycle.closed(error) }
        }
    }
    func waitUntilReady() async throws { try await lifecycle.waitUntilReady() }
    func waitUntilClosed() async { await lifecycle.waitUntilClosed() }
    func send(_ data: Data) async throws {
        try await waitUntilReady()
        let request = try JSONDecoder().decode(HBProtocolEnvelope.self, from: data)
        if let reply = try await server.reply(to: request, route: route) {
            await inbox.push(try JSONEncoder().encode(reply))
            for extra in try await server.extraMessages(after: request) { await inbox.push(try JSONEncoder().encode(extra)) }
        }
    }
    func receive() async throws -> Data { try await inbox.receive() }
    func close() {
        readiness.cancel()
        lifecycle.closed()
        Task { await inbox.close() }
    }
}

private actor RoutingInbox {
    private var queue: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var closed = false
    func push(_ data: Data) { if let waiter { self.waiter = nil; waiter.resume(returning: data) } else if !closed { queue.append(data) } }
    func receive() async throws -> Data {
        if closed { throw URLError(.networkConnectionLost) }
        if !queue.isEmpty { return queue.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() { closed = true; waiter?.resume(throwing: URLError(.networkConnectionLost)); waiter = nil; queue.removeAll() }
}

private actor RoutingServer {
    struct Summary: Sendable {
        let mutationIDs: [UUID]
        let mutationExecutions: Int
        let resumes: Int
        let subscriptions: Int
        let openedRoutes: [HomeBaseControlRoute]
    }
    private let instance = UUID()
    private var networkAvailable = true
    private var openDelay: Duration = .zero
    private var networkReadinessDelay: Duration = .zero
    private var bluetoothReadinessDelay: Duration = .milliseconds(10)
    private var readyNetworkCount = 0
    private var readyBluetoothCount = 0
    private(set) var completedNetworkReadiness = 0
    private var openedRoutes: [HomeBaseControlRoute] = []
    private var holdNetworkAttempt = false
    private var heldNetworkAttempt: CheckedContinuation<Void, Never>?
    private var holdSessionOpenSend = false
    private var heldSessionSend: CheckedContinuation<Void, Never>?
    private var holdBluetoothReplaySend = false
    private var heldReplaySend: CheckedContinuation<Void, Never>?
    var hasHeldSessionSend: Bool { heldSessionSend != nil }
    var hasHeldReplaySend: Bool { heldReplaySend != nil }
    func holdNextSessionOpenSend() { holdSessionOpenSend = true }
    func holdNextBluetoothReplaySend() { holdBluetoothReplaySend = true }
    func releaseSessionSend() {
        heldSessionSend?.resume()
        heldSessionSend = nil
    }
    func releaseReplaySend() {
        heldReplaySend?.resume()
        heldReplaySend = nil
    }
    var hasHeldNetworkAttempt: Bool { heldNetworkAttempt != nil }
    func holdNextNetworkAttempt() { holdNetworkAttempt = true }
    func releaseNetworkAttempt() {
        heldNetworkAttempt?.resume()
        heldNetworkAttempt = nil
    }
    func setReadinessDelay(_ delay: Duration, route: HomeBaseControlRoute) {
        if route == .webSocket { networkReadinessDelay = delay }
        else { bluetoothReadinessDelay = delay }
    }
    func readyCount(for route: HomeBaseControlRoute) -> Int {
        route == .webSocket ? readyNetworkCount : readyBluetoothCount
    }
    func waitUntilReady(route: HomeBaseControlRoute) async throws {
        defer { if route == .webSocket { completedNetworkReadiness += 1 } }
        if route == .webSocket, holdNetworkAttempt {
            holdNetworkAttempt = false
            // Intentionally ignores cancellation to exercise independent
            // carrier lifetimes when a stale system callback arrives late.
            await withCheckedContinuation { heldNetworkAttempt = $0 }
        }
        let delay = route == .webSocket ? networkReadinessDelay : bluetoothReadinessDelay
        if delay != .zero { try await Task.sleep(for: delay) }
        if route == .webSocket, !networkAvailable { throw URLError(.notConnectedToInternet) }
        if route == .webSocket { readyNetworkCount += 1 }
        else { readyBluetoothCount += 1 }
    }
    private var loseMutation = false
    private var ignoreMutationReplay = false
    private var rejectResumes = false
    private var mutationIDs: [UUID] = []
    private var holdingNetworkMutations = false
    private var completedValues: [HBJSONValue] = []
    func holdNetworkMutations() { holdingNetworkMutations = true }
    func completedMutationValues() -> [HBJSONValue] { completedValues }
    private var receipts: [UUID: HBProtocolEnvelope] = [:]
    private var resumes = 0
    private var subscriptions = 0
    private var lastClientID = UUID()
    private var credential: HBBluetoothCnCCredential?
    private var upgrades = 0
    private var acknowledged: Int64 = 0
    private var deliverySequences: [UUID: Int64] = [:]
    private var freshConnectionsFail = false
    private var dropsFreshNetwork = false
    private var holdsFreshConnection = false
    private var rejectedResume = false
    func failFreshConnections() { freshConnectionsFail = true }
    func dropNetworkOnNextFreshConnection() { dropsFreshNetwork = true }
    func holdFreshConnection() { holdsFreshConnection = true }
    private var lastSubscriptionID: UUID?
    func latestSubscriptionID() -> UUID? { lastSubscriptionID }
    private let control = HBControlWatchStreamControl(control: "test:Power", deviceIdentifier: "test",
        controlIdentifier: "Power", displayName: "Power", kind: "BinarySwitch")
    private var replaySubscription: UUID?
    func replayEventOnNextResume(_ id: UUID) { replaySubscription = id }
    func extraMessages(after request: HBProtocolEnvelope) throws -> [HBProtocolEnvelope] {
        guard request.operation == HBProtocolOperations.resumeSession, let replaySubscription else { return [] }
        self.replaySubscription = nil
        return [try event(subscriptionID: replaySubscription)]
    }
    func setCredential(_ value: HBBluetoothCnCCredential) { credential = value }
    func upgradeSummary() -> (Int, Int64) { (upgrades, acknowledged) }
    private var lastSessionID = UUID()
    private var expiredSessions: Set<UUID> = []
    func expireCurrentSession() { expiredSessions.insert(lastSessionID) }
    func setNetworkAvailable(_ value: Bool) { networkAvailable = value }
    func setOpenDelay(_ value: Duration) { openDelay = value }
    func loseNextMutationReply(ignoreReplay: Bool = false, rejectResume: Bool = false) {
        loseMutation = true; ignoreMutationReplay = ignoreReplay; rejectResumes = rejectResume
    }
    func summary() -> Summary {
        .init(mutationIDs: mutationIDs, mutationExecutions: receipts.count,
              resumes: resumes, subscriptions: subscriptions, openedRoutes: openedRoutes)
    }
    func reply(to request: HBProtocolEnvelope, route: HomeBaseControlRoute) async throws -> HBProtocolEnvelope? {
        if route == .webSocket, !networkAvailable { throw URLError(.notConnectedToInternet) }
        lastClientID = request.clientID
        var responseSession = request.sessionID
        let body: HBProtocolResponse
        switch request.operation {
        case HBProtocolOperations.ping where request.sessionID.map(expiredSessions.contains) == true:
            // An app can retain a socket while suspended long after the server
            // has dropped it and expired its logical session.
            return nil
        case HBProtocolOperations.openSession:
            if holdSessionOpenSend {
                holdSessionOpenSend = false
                await withCheckedContinuation { heldSessionSend = $0 }
            }
            if rejectedResume, dropsFreshNetwork, route == .webSocket {
                dropsFreshNetwork = false; networkAvailable = false
                throw URLError(.networkConnectionLost)
            }
            if rejectedResume, freshConnectionsFail { throw URLError(.cannotConnectToHost) }
            if rejectedResume, holdsFreshConnection {
                holdsFreshConnection = false
                await withCheckedContinuation { heldNetworkAttempt = $0 }
            }
            if route == .webSocket, openDelay != .zero { try await Task.sleep(for: openDelay) }
            openedRoutes.append(route)
            let id = UUID(); responseSession = id; lastSessionID = id
            body = try .success(HBWebSocketSessionOpened(sessionID: id, resumeToken: "resume", serverInstanceID: instance,
                authorization: .administrator, limits: .init(resumeWindowSeconds: 60, maximumReplayMessages: 100,
                    maximumReplayBytes: 100_000, maximumRequestRecords: 100)))
        case HBProtocolOperations.resumeSession:
            resumes += 1
            let resume = try request.decodedPayload(as: HBWebSocketSessionResumeRequest.self)
            responseSession = resume.sessionID; lastSessionID = resume.sessionID
            rejectedResume = rejectResumes || expiredSessions.contains(resume.sessionID)
            body = rejectedResume ? .failure(.init(
                code: HBProtocolErrorCodes.resyncRequired,
                message: "The WebSocket session cannot be resumed; rebuild client state from fresh subscriptions.",
                details: .object(["reason": .string("session_expired")]))) :
                try .success(HBWebSocketSessionResumed(sessionID: resume.sessionID, serverInstanceID: instance,
                    replayedMessageCount: 0, latestDeliverySequence: resume.acknowledgedDeliverySequence))
        case HBProtocolOperations.setControl:
            mutationIDs.append(request.requestID)
            if holdingNetworkMutations, route == .webSocket { return nil }
            if route == .bluetooth, holdBluetoothReplaySend, receipts[request.requestID] != nil {
                holdBluetoothReplaySend = false
                await withCheckedContinuation { heldReplaySend = $0 }
            }
            if let cached = receipts[request.requestID] { return ignoreMutationReplay ? nil : cached }
            completedValues.append(try request.decodedPayload(as: HBControlSetRequest.self).value)
            var response = try HBProtocolEnvelope.response(to: request, body: .successWithoutResult)
            response.sessionID = request.sessionID
            receipts[request.requestID] = response
            if loseMutation { loseMutation = false; networkAvailable = false; throw URLError(.networkConnectionLost) }
            return response
        case HBProtocolOperations.listTopology:
            body = try .success(HBTopologyListResult(devices: [], rooms: [], groups: []))
        case HBProtocolOperations.listDevices:
            body = try .success(HBDeviceListResult(devices: [HBDeviceDescriptor(identifier: "test",
                addressableName: "test", displayName: "Test", moduleName: "test",
                controls: [.init(identifier: "Power", name: "Power", kind: "BinarySwitch", metadata: ["readable": true])])]))
        case HBProtocolOperations.streamControls:
            subscriptions += 1
            let identifier = UUID(); lastSubscriptionID = identifier
            body = try .success(HBControlWatchStreamAccepted(subscriptionID: identifier, controls: [control]))
        case HBProtocolOperations.cancelSubscription:
            let cancel = try request.decodedPayload(as: HBSubscriptionCancelRequest.self)
            body = try .success(HBSubscriptionCancelResult(subscriptionID: cancel.subscriptionID))
        case HBProtocolOperations.executeModuleCommand:
            let command = try request.decodedPayload(as: HBModuleCommandRequest.self)
            guard command.moduleName == HBBluetoothProtocol.moduleName, command.path == ["cnc", "enroll"], let credential else {
                throw URLError(.badServerResponse)
            }
            upgrades += 1
            body = try .success(HBModuleCommandResult(value: HBJSONValue(encoding: credential)))
        case HBProtocolOperations.acknowledgeSession:
            let ack = try request.decodedPayload(as: HBWebSocketSessionAckRequest.self)
            acknowledged = ack.deliverySequence
            body = try .success(HBWebSocketSessionAckResult(acknowledgedDeliverySequence: ack.deliverySequence))
        default: body = .successWithoutResult
        }
        var result = try HBProtocolEnvelope.response(to: request, body: body)
        result.sessionID = responseSession
        if request.operation == HBProtocolOperations.executeModuleCommand || request.operation == HBProtocolOperations.listDevices,
           let responseSession {
            deliverySequences[responseSession, default: 0] += 1
            result.deliverySequence = deliverySequences[responseSession]
        }
        return result
    }
    func event(subscriptionID: UUID) throws -> HBProtocolEnvelope {
        var envelope = HBProtocolEnvelope(messageKind: .event, clientID: lastClientID, operation: HBProtocolOperations.streamControls,
            payload: try HBJSONValue(encoding: HBControlWatchStreamEvent(subscriptionID: subscriptionID, sequence: 1, kind: .change, control: control, value: .bool(true))),
            sessionID: lastSessionID, subscriptionID: subscriptionID)
        deliverySequences[lastSessionID, default: 0] += 1
        envelope.deliverySequence = deliverySequences[lastSessionID]
        return envelope
    }
}

@MainActor private final class CredentialStore: BluetoothPresenceStoring {
    // Avoid iOS 26.1 nested isolated-deinit runtime teardown (confirmed by ASan).
    nonisolated deinit {}
    var items: [BluetoothPresenceRegistration]
    init(items: [BluetoothPresenceRegistration]) { self.items = items }
    func load() throws -> [BluetoothPresenceRegistration] { items }
    func save(_ registrations: [BluetoothPresenceRegistration]) throws { items = registrations }
}
@MainActor private final class CredentialPresenceTransport: BluetoothPresenceTransporting {
    nonisolated deinit {}
    var onEvent: ((BluetoothPresenceTransportEvent) -> Void)?
    func synchronize(_ registrations: [BluetoothPresenceRegistration]) {}
    func showPicker(for registration: BluetoothPresenceRegistration) throws {}
    func removeAccessory(peripheralID: UUID) {}
    func retryConnections() {}
}
