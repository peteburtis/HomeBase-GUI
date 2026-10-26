import Foundation
import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class HomeBaseConnectionRecoveryTests: XCTestCase {
    private func client(_ factory: RecoverySocketFactory) -> HomeBaseWebSocketClient {
        HomeBaseWebSocketClient(endpoint: HomeBaseEndpoint(host: "test.invalid", port: 10503)!,
                                requestTimeout: 0.15, makeControlSocket: { _ in factory.makeSocket() })
    }

    private func eventually(_ predicate: () async -> Bool) async {
        for _ in 0..<1000 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Condition was not reached")
    }

    func testSnapshotBeforeAnyEventStillInvalidatesRetainedObserversOnReconnect() async throws {
        let factory = RecoverySocketFactory(), camera = UUID().uuidString, nvr = UUID().uuidString
        let client = client(factory)
        var events = await client.footageTagChanges(cameraID: camera).makeAsyncIterator()
        let query = HBNVRTagQuery(cameraID: camera, ranges: [.init(start: 100, end: 101)], keys: [CameraVideoTags.hiddenKey])
        let snapshot = try await client.footageTagSnapshot(instanceID: nvr, query: query)
        XCTAssertEqual(snapshot?.instanceID, nvr)
        await factory.server.ignore(HBProtocolOperations.ping, on: 0)
        try await client.reactivate()
        let reset = await events.next()
        XCTAssertTrue(reset?.reset == true)
        XCTAssertEqual(reset?.instanceID, nvr)
        let refreshed = try await client.footageTagSnapshot(instanceID: nvr, query: query)
        XCTAssertNotNil(refreshed)
        XCTAssertEqual(factory.count, 2)
        await client.disconnect()
    }

    func testTagRevisionMaximumAndGapProduceBoundedResets() async throws {
        let factory = RecoverySocketFactory(), camera = UUID().uuidString, nvr = UUID().uuidString
        let client = client(factory)
        try await client.connect()
        var events = await client.footageTagChanges(cameraID: camera).makeAsyncIterator()
        try await client.receiveFootageTagChange(.init(instanceID: nvr, revision: UInt64.max, reset: true, ranges: []))
        let first = await events.next()
        XCTAssertTrue(first?.reset == true)
        try await client.receiveFootageTagChange(.init(instanceID: nvr, revision: UInt64.max, reset: true, ranges: []))
        let second = await events.next()
        XCTAssertEqual(second?.revision, UInt64.max)
        let replacement = UUID().uuidString
        try await factory.server.emit(.init(instanceID: replacement, revision: 1, reset: false,
            ranges: [.init(cameraID: camera, epochID: "e", start: 1, end: 2)]), on: 0)
        let restarted = await events.next()
        XCTAssertTrue(restarted?.reset == true)
        try await factory.server.emit(.init(instanceID: replacement, revision: 3, reset: false,
            ranges: [.init(cameraID: camera, epochID: "e", start: 1, end: 2)]), on: 0)
        let gap = await events.next()
        XCTAssertTrue(gap?.reset == true)
        await client.disconnect()
    }

    func testValidTagEventRestoresCapabilityAfterOldNVRUpgrade() async throws {
        let factory = RecoverySocketFactory(), camera = UUID().uuidString, nvr = UUID().uuidString
        let client = client(factory)
        await factory.server.tagError("unsupported_operation")
        let query = HBNVRTagQuery(cameraID: camera, ranges: [.init(start: 100, end: 101)], keys: [CameraVideoTags.hiddenKey])
        let old = try await client.footageTagSnapshot(instanceID: nvr, query: query)
        XCTAssertNil(old)
        var events = await client.footageTagChanges().makeAsyncIterator()
        await factory.server.tagError(nil)
        try await factory.server.emit(.init(instanceID: nvr, revision: 0, reset: true, ranges: []), on: 0)
        _ = await events.next()
        let updated = try await client.footageTagSnapshot(instanceID: nvr, query: query)
        XCTAssertNotNil(updated)
        await client.disconnect()
    }

    func testPermissionDeniedFallsBackOnlyWhenDiscoveryProvesOldDaemon() async throws {
        for advertised in [false, true] {
            let factory = RecoverySocketFactory(), client = client(factory)
            await factory.server.tagError(HBProtocolErrorCodes.permissionDenied)
            await factory.server.advertiseTags(advertised)
            let query = HBNVRTagQuery(cameraID: UUID().uuidString, ranges: [.init(start: 100, end: 101)], keys: [CameraVideoTags.hiddenKey])
            do {
                let snapshot = try await client.footageTagSnapshot(instanceID: UUID().uuidString, query: query)
                XCTAssertFalse(advertised, "Real authorization failures cannot bypass snapshots")
                XCTAssertNil(snapshot)
            } catch {
                XCTAssertTrue(advertised)
                XCTAssertEqual((error as? HBProtocolError)?.code, HBProtocolErrorCodes.permissionDenied)
            }
            await client.disconnect()
        }
    }

    func testSilentPingIsBoundedAndConcurrentRecoveryUsesOneReplacementSocket() async throws {
        let factory = RecoverySocketFactory()
        let client = client(factory)
        try await client.connect()
        let session = await client.currentSessionIdentifier()
        let arbiter = await client.cameraStreamArbiter()
        await factory.server.ignore(HBProtocolOperations.ping, on: 0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { try await client.reactivate() } }
            try await group.waitForAll()
        }
        XCTAssertEqual(factory.count, 2)
        let resumedSession = await client.currentSessionIdentifier()
        XCTAssertEqual(session, resumedSession)
        let retainedArbiter = await client.cameraStreamArbiter()
        XCTAssertTrue(arbiter === retainedArbiter)
        let pings = await factory.server.count(HBProtocolOperations.ping, on: 0)
        XCTAssertEqual(pings, 1)
        await client.disconnect()
    }

    func testRejectedResumeOpensFreshSessionAndCameraTicket() async throws {
        let factory = RecoverySocketFactory()
        let client = client(factory)
        try await client.connect()
        let oldSession = await client.currentSessionIdentifier()
        let first = try await client.openCameraLiveStream(deviceIdentifier: "a", quality: .low)
        await factory.server.ignore(HBProtocolOperations.ping, on: 0)
        await factory.server.rejectResume(on: 1)
        try await client.reactivate()
        let second = try await client.openCameraLiveStream(deviceIdentifier: "a", quality: .low)
        let newSession = await client.currentSessionIdentifier()
        XCTAssertNotEqual(oldSession, newSession)
        XCTAssertNotEqual(first.opened.ticket, second.opened.ticket)
        XCTAssertNotEqual(first.opened.streamID, second.opened.streamID)
        XCTAssertEqual(factory.count, 3)
        await client.disconnect()
    }

    func testSilentSessionOpenTimesOutAndCanBeRetried() async throws {
        let factory = RecoverySocketFactory()
        await factory.server.ignore(HBProtocolOperations.openSession, on: 0)
        let client = client(factory)
        do { try await client.connect(); XCTFail("A silent peer must time out") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        try await client.connect()
        let session = await client.currentSessionIdentifier()
        XCTAssertNotNil(session)
        XCTAssertEqual(factory.count, 2)
        await client.disconnect()
    }

    func testDisconnectDuringRecoveryDoesNotReopenConnection() async throws {
        let factory = RecoverySocketFactory()
        let client = client(factory)
        try await client.connect()
        let arbiter = await client.cameraStreamArbiter()
        await factory.server.ignore(HBProtocolOperations.ping, on: 0)
        let recovery = Task { try await client.reactivate() }
        await eventually { await factory.server.count(HBProtocolOperations.ping, on: 0) == 1 }
        await client.disconnect()
        do { try await recovery.value; XCTFail("Disconnect must cancel recovery") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(factory.count, 1)
        let session = await client.currentSessionIdentifier()
        XCTAssertNil(session)
        do {
            _ = try await arbiter.subscribe(camera: "a", quality: .low)
            XCTFail("A disconnected arbiter cannot resurrect playback")
        } catch { XCTAssertEqual(error as? CameraStreamError, .closed) }
    }

    func testOldCancelledAttemptCannotTearDownExplicitNewConnection() async throws {
        let factory = RecoverySocketFactory()
        await factory.server.ignore(HBProtocolOperations.openSession, on: 0)
        let client = client(factory)
        let opening = Task { try await client.connect() }
        await eventually { await factory.server.count(HBProtocolOperations.openSession, on: 0) == 1 }
        await client.disconnect()
        try await client.connect()
        _ = await opening.result
        try await client.reactivate()
        XCTAssertEqual(factory.count, 2)
        let session = await client.currentSessionIdentifier()
        XCTAssertNotNil(session)
        await client.disconnect()
    }

    func testTimedOutControlWriteIsNotReplayedDuringRecovery() async throws {
        let factory = RecoverySocketFactory()
        let client = client(factory)
        try await client.connect()
        await factory.server.ignore(HBProtocolOperations.setControl, on: 0)
        do {
            try await client.setControl("test-only-control", to: .bool(true))
            XCTFail("The missing acknowledgement must time out")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        try await client.reactivate()
        let originalWrites = await factory.server.count(HBProtocolOperations.setControl, on: 0)
        let replayedWrites = await factory.server.count(HBProtocolOperations.setControl, on: 1)
        XCTAssertEqual(originalWrites, 1)
        XCTAssertEqual(replayedWrites, 0)
        XCTAssertEqual(factory.count, 2)
        await client.disconnect()
    }
}

/// Exercises the real envelope/session/timeout code without a reachable server
/// or VPN. Each socket has an independent receive queue, including cancellation.
private nonisolated final class RecoverySocketFactory: @unchecked Sendable {
    let server = RecoveryServer()
    private let lock = NSLock()
    private var sockets = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return sockets }
    func makeSocket() -> any HomeBaseControlSocket {
        lock.lock(); defer { lock.unlock() }
        let socket = RecoverySocket(index: sockets, server: server)
        sockets += 1
        return socket
    }
}

private nonisolated final class RecoverySocket: HomeBaseControlSocket, @unchecked Sendable {
    let index: Int
    let server: RecoveryServer
    let inbox = RecoveryInbox()
    var maximumMessageSize: Int { get { 4 * 1024 * 1024 } set {} }
    init(index: Int, server: RecoveryServer) { self.index = index; self.server = server }
    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { await inbox.cancel() }
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw URLError(.badServerResponse)
        }
        let request = try JSONDecoder().decode(HBProtocolEnvelope.self, from: data)
        await server.attach(inbox, on: index)
        if let response = try await server.response(to: request, socket: index) {
            await inbox.push(.data(try JSONEncoder().encode(response)))
        }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await inbox.receive() }
}

private actor RecoveryInbox {
    private var messages: [URLSessionWebSocketTask.Message] = []
    private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var cancelled = false
    func push(_ message: URLSessionWebSocketTask.Message) {
        guard !cancelled else { return }
        if let waiter { self.waiter = nil; waiter.resume(returning: message) }
        else { messages.append(message) }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        if cancelled { throw URLError(.cancelled) }
        if !messages.isEmpty { return messages.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func cancel() {
        cancelled = true
        waiter?.resume(throwing: URLError(.cancelled)); waiter = nil
        messages.removeAll()
    }
}

private actor RecoveryServer {
    private var ignored: [Int: Set<String>] = [:]
    private var rejectedResumes: Set<Int> = []
    private var requests: [(Int, String)] = []
    private let instance = UUID()
    private var session = UUID()
    private var inboxes: [Int: RecoveryInbox] = [:]
    private var clients: [Int: UUID] = [:]
    private var sequences: [Int: Int64] = [:]
    private var tagsError: String?
    private var tagsAdvertised = true
    func advertiseTags(_ value: Bool) { tagsAdvertised = value }
    func attach(_ inbox: RecoveryInbox, on socket: Int) { inboxes[socket] = inbox }
    func tagError(_ code: String?) { tagsError = code }
    func emit(_ change: HBNVRTagChange, on socket: Int) async throws {
        guard let inbox = inboxes[socket], let client = clients[socket] else { return }
        sequences[socket, default: 0] += 1
        let event = HBProtocolEnvelope(messageKind: .event, clientID: client, operation: HBProtocolOperations.nvrTagsChanged,
            payload: try HBJSONValue(encoding: change), sessionID: session, deliverySequence: sequences[socket])
        await inbox.push(.data(try JSONEncoder().encode(event)))
    }
    func ignore(_ operation: String, on socket: Int) { ignored[socket, default: []].insert(operation) }
    func rejectResume(on socket: Int) { rejectedResumes.insert(socket) }
    func count(_ operation: String, on socket: Int) -> Int {
        requests.filter { $0.0 == socket && $0.1 == operation }.count
    }
    func response(to request: HBProtocolEnvelope, socket: Int) throws -> HBProtocolEnvelope? {
        requests.append((socket, request.operation))
        clients[socket] = request.clientID
        if ignored[socket]?.contains(request.operation) == true { return nil }
        let body: HBProtocolResponse
        switch request.operation {
        case HBProtocolOperations.openSession:
            session = UUID()
            body = try .success(HBWebSocketSessionOpened(sessionID: session, resumeToken: "test-resume",
                serverInstanceID: instance, authorization: .administrator,
                limits: .init(resumeWindowSeconds: 60, maximumReplayMessages: 100,
                              maximumReplayBytes: 100000, maximumRequestRecords: 100)))
        case HBProtocolOperations.resumeSession:
            if rejectedResumes.contains(socket) {
                body = .failure(.init(code: HBProtocolErrorCodes.resyncRequired, message: "test expired session"))
            } else {
                let resume = try request.decodedPayload(as: HBWebSocketSessionResumeRequest.self)
                body = try .success(HBWebSocketSessionResumed(sessionID: resume.sessionID,
                    serverInstanceID: instance, replayedMessageCount: 0,
                    latestDeliverySequence: resume.acknowledgedDeliverySequence))
            }
        case HBProtocolOperations.describeProtocol:
            body = try .success(HBJSONValue.object(["authorization": .object([
                "userOperations": .array(tagsAdvertised ? [.string(HBProtocolOperations.snapshotNVRTags)] : [])])]))
        case HBProtocolOperations.snapshotNVRTags:
            if let tagsError { body = .failure(.init(code: tagsError, message: "fixture capability")) }
            else {
                let value = try request.decodedPayload(as: HBNVRTagSnapshotRequest.self)
                body = try .success(HBNVRTagSnapshot(instanceID: value.nvrInstanceID, revision: 0,
                    cameraID: value.query.cameraID, spans: []))
            }
        case HBProtocolOperations.ping: body = .successWithoutResult
        case HBProtocolOperations.openCameraLiveStream:
            let open = try request.decodedPayload(as: HBCameraLiveOpenRequest.self)
            body = try .success(HBCameraLiveOpenResult(deviceIdentifier: open.deviceIdentifier,
                streamID: UUID(), requestedQuality: open.quality ?? .medium, mediaPort: 10504,
                ticket: UUID().uuidString, ticketExpiresAt: Date().addingTimeInterval(60)))
        default: return nil
        }
        var response = try HBProtocolEnvelope.response(to: request, body: body)
        response.sessionID = session
        return response
    }
}
