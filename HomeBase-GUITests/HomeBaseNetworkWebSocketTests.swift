import Foundation
import HomeBaseProtocol
import Network
import XCTest
@testable import HomeBase_GUI

final class HomeBaseNetworkWebSocketTests: XCTestCase {
    func testPinnedWebSocketExporterAndMessageLifecycle() async throws {
        let identity = try HBServerIdentity.generate()
        let bindings = try await WebSocketLoopback(identity: identity).run { socket in
            XCTAssertEqual(socket.maximumMessageSize, 16 * 1_024)
            try await socket.send(.string("authenticated websocket"))
            guard case .string(let reply) = try await socket.receive() else { return XCTFail("Expected a text reply") }
            XCTAssertEqual(reply, "authenticated websocket")
            do {
                try await socket.send(.data(Data(repeating: 1, count: 16 * 1_024 + 1)))
                XCTFail("Pre-authentication messages must be bounded")
            } catch { }
            socket.authenticated()
            let bytes = Data(repeating: 2, count: 20 * 1_024)
            try await socket.send(.data(bytes))
            guard case .data(let binary) = try await socket.receive() else { return XCTFail("Expected a binary reply") }
            XCTAssertEqual(binary, bytes)
            let transport = HomeBaseWebSocketTransport(socket: socket)
            try await transport.waitUntilReady()
            let pendingRead = Task { try await transport.receive() }
            pendingRead.cancel()
            do { _ = try await pendingRead.value; XCTFail("Cancelled receive must close its socket") } catch { }
            await transport.waitUntilClosed()
        }
        XCTAssertEqual(bindings.client, bindings.server)
        XCTAssertEqual(bindings.client.type, "tls-exporter")
    }

    func testWebSocketRejectsWrongInstallationPinAndWrongSubprotocol() async throws {
        let identity = try HBServerIdentity.generate()
        do {
            _ = try await WebSocketLoopback(identity: identity, fingerprint: Data(repeating: 0, count: 32)).run { _ in
                XCTFail("The wrong pin must fail before any application bytes")
            }
            XCTFail("Expected TLS pin rejection")
        } catch { }
        do {
            _ = try await WebSocketLoopback(identity: identity, subprotocol: nil).run { _ in
                XCTFail("An unrelated WebSocket must fail before application bytes")
            }
            XCTFail("Expected subprotocol rejection")
        } catch { }
    }
}

/// Real TLS/WebSocket listener, confined to loopback and alive only for the test.
nonisolated private final class WebSocketLoopback: @unchecked Sendable {
    struct Bindings: Sendable { let client: HBChannelBinding; let server: HBChannelBinding }
    private let identity: HBServerIdentity
    private let fingerprint: Data
    private let subprotocol: String?
    private let queue = DispatchQueue(label: "HomeBaseGUITests.WebSocketLoopback")
    private var listener: NWListener?
    private var socket: HomeBaseNetworkWebSocket?
    private var server: NWConnection?
    private var clientBinding: HBChannelBinding?
    private var serverBinding: HBChannelBinding?
    private var continuation: CheckedContinuation<Bindings, Error>?
    private var exercise: (@Sendable (HomeBaseNetworkWebSocket) async throws -> Void)?
    private var clientTask: Task<Void, Never>?
    private var exerciseTask: Task<Void, Never>?
    private var finished = false

    init(identity: HBServerIdentity, fingerprint: Data? = nil, subprotocol: String? = "homebase.v2") {
        self.identity = identity; self.fingerprint = fingerprint ?? identity.fingerprint; self.subprotocol = subprotocol
    }

    func run(exercise: @escaping @Sendable (HomeBaseNetworkWebSocket) async throws -> Void) async throws -> Bindings {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation; self.exercise = exercise
                do { try start() } catch { finish(.failure(error)) }
            }
        }
    }

    private func start() throws {
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 65_536
        websocket.setClientRequestHandler(queue) { [subprotocol] protocols, _ in
            .init(status: protocols.contains("homebase.v2") ? .accept : .reject, subprotocol: subprotocol)
        }
        let parameters = NWParameters(tls: try identity.tlsOptions(), tcp: .init())
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [self] connection in
            server = connection
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    do {
                        serverBinding = try HBTLS.channelBinding(for: connection)
                        let ping = NWConnection.ContentContext(identifier: "ping", metadata: [NWProtocolWebSocket.Metadata(opcode: .ping)])
                        connection.send(content: Data(), contentContext: ping, isComplete: true, completion: .contentProcessed { _ in })
                        startExerciseIfReady(); echo(connection)
                    }
                    catch { finish(.failure(error)) }
                case .failed(let error): finish(.failure(error))
                default: break
                }
            }
            connection.start(queue: queue)
        }
        listener.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                guard !finished, socket == nil, let port = listener.port else { return }
                do {
                    guard let endpoint = HomeBaseEndpoint(host: "127.0.0.1", port: Int(port.rawValue), serverFingerprint: fingerprint) else {
                        throw HomeBaseAuthenticationError.invalidPairingURL
                    }
                    let socket = try HomeBaseNetworkWebSocket(endpoint: endpoint, maximumMessageSize: 65_536)
                    self.socket = socket
                    clientTask = Task { [self] in
                        do {
                            let binding = try await socket.channelBinding()
                            self.queue.async { [self] in clientBinding = binding; startExerciseIfReady() }
                        } catch { self.queue.async { [self] in finish(.failure(error)) } }
                    }
                } catch { finish(.failure(error)) }
            case .failed(let error): finish(.failure(error))
            default: break
            }
        }
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [self] in finish(.failure(URLError(.timedOut))) }
    }

    private func echo(_ connection: NWConnection) {
        connection.receiveMessage { [self] data, context, _, error in
            guard !finished else { return }
            if let error { finish(.failure(error)); return }
            guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else { return }
            if metadata.opcode == .ping || metadata.opcode == .pong { echo(connection); return }
            guard let data,
                  metadata.opcode == .text || metadata.opcode == .binary else { return }
            let reply = NWConnection.ContentContext(identifier: "echo", metadata: [NWProtocolWebSocket.Metadata(opcode: metadata.opcode)])
            connection.send(content: data, contentContext: reply, isComplete: true, completion: .contentProcessed { _ in })
            echo(connection)
        }
    }

    private func startExerciseIfReady() {
        guard !finished, exerciseTask == nil, let clientBinding, let serverBinding, let socket, let exercise else { return }
        exerciseTask = Task { [self] in
            do {
                try await exercise(socket)
                queue.async { [self] in finish(.success(.init(client: clientBinding, server: serverBinding))) }
            } catch { queue.async { [self] in finish(.failure(error)) } }
        }
    }

    private func finish(_ result: Result<Bindings, Error>) {
        guard !finished else { return }
        finished = true
        clientTask?.cancel(); exerciseTask?.cancel()
        socket?.close(); server?.cancel(); listener?.cancel()
        let pending = continuation; continuation = nil
        pending?.resume(with: result)
    }
}
