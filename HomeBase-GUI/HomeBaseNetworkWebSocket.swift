import Foundation
import HomeBaseProtocol
@preconcurrency import Network

/// Network.framework owns TLS so application authentication can bind its proof
/// to the exporter of this exact connection. No URLSession trust exceptions or
/// plaintext fallback are used by production control or history connections.
nonisolated final class HomeBaseNetworkWebSocket: HomeBaseControlSocket, CameraHistorySocket, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "io.pjb.HomeBase-GUI.AuthenticatedWebSocket")
    private let lifecycle = HomeBaseTransportLifecycle()
    private let lock = NSLock()
    private var started = false
    private var failure: Error?
    private var onOpen: (@Sendable () -> Void)?
    private var onClose: (@Sendable (Error?) -> Void)?
    private var ready = false
    private var messageLimit = 16 * 1_024
    private let authenticatedMessageLimit: Int

    var maximumMessageSize: Int {
        get { lock.withLock { messageLimit } }
        set { lock.withLock { messageLimit = newValue } }
    }

    init(endpoint: HomeBaseEndpoint, maximumMessageSize: Int = 16 * 1_024 * 1_024) throws {
        guard let url = endpoint.webSocketURL, let fingerprint = endpoint.serverFingerprint,
              fingerprint.count == 32 else { throw HomeBaseAuthenticationError.invalidPairingURL }
        authenticatedMessageLimit = maximumMessageSize
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = maximumMessageSize
        webSocket.setSubprotocols(["homebase.v2"])
        let parameters = NWParameters(tls: try HBTLS.makeClientOptions(serverFingerprint: fingerprint, queue: queue), tcp: .init())
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
    }

    func observeLifecycle(onOpen: @escaping @Sendable () -> Void,
                          onClose: @escaping @Sendable (Error?) -> Void) {
        let state = lock.withLock { () -> (Bool, Error?) in
            self.onOpen = onOpen; self.onClose = onClose
            return (ready, failure)
        }
        if let error = state.1 { onClose(error) }
        else if state.0 { onOpen() }
    }

    func resume() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !started, failure == nil else { return false }
            started = true; return true
        }
        guard shouldStart else { return }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let metadata = self.connection.metadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                      metadata.selectedSubprotocol == "homebase.v2" else {
                    self.finish(HomeBaseControlTransportError.invalidMessage)
                    self.connection.cancel()
                    return
                }
                let callback = self.lock.withLock { () -> (@Sendable () -> Void)? in
                    guard self.failure == nil else { return nil }
                    self.ready = true; return self.onOpen
                }
                self.lifecycle.opened(); callback?()
            case .failed(let error): self.finish(error)
            case .waiting(let error):
                // The carrier coordinator owns bounded retries and path
                // recovery. Surface TLS/pin failures without an indefinite wait.
                self.finish(error); self.connection.cancel()
            case .cancelled: self.finish(URLError(.cancelled))
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func channelBinding() async throws -> HBChannelBinding {
        resume()
        try await lifecycle.waitUntilReady()
        return try HBTLS.channelBinding(for: connection)
    }

    func authenticated() { lock.withLock { messageLimit = authenticatedMessageLimit } }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let data: Data, opcode: NWProtocolWebSocket.Opcode
        switch message {
        case .string(let value): data = Data(value.utf8); opcode = .text
        case .data(let value): data = value; opcode = .binary
        @unknown default: throw HomeBaseControlTransportError.invalidMessage
        }
        guard data.count <= maximumMessageSize else { throw HomeBaseControlTransportError.invalidMessage }
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "HomeBase", metadata: [metadata])
        try await withTaskCancellationHandler {
            resume(); try await lifecycle.waitUntilReady()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, contentContext: context, isComplete: true,
                                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        } onCancel: { self.close() }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        return try await withTaskCancellationHandler {
            resume(); try await lifecycle.waitUntilReady()
            return try await withCheckedThrowingContinuation { continuation in
                receiveApplicationMessage(continuation)
            }
        } onCancel: { self.close() }
    }

    private func receiveApplicationMessage(_ continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { continuation.resume(throwing: URLError(.cancelled)); return }
            if let error { continuation.resume(throwing: error); return }
            guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else {
                continuation.resume(throwing: HomeBaseControlTransportError.closed); return
            }
            // Network replies to pings automatically. Control frames never
            // consume the application's next response or session delivery.
            if metadata.opcode == .ping || metadata.opcode == .pong {
                self.receiveApplicationMessage(continuation); return
            }
            guard let data, data.count <= self.maximumMessageSize else {
                continuation.resume(throwing: HomeBaseControlTransportError.invalidMessage); return
            }
            switch metadata.opcode {
            case .text:
                guard let value = String(data: data, encoding: .utf8) else {
                    continuation.resume(throwing: HomeBaseControlTransportError.invalidMessage); return
                }
                continuation.resume(returning: .string(value))
            case .binary: continuation.resume(returning: .data(data))
            default: continuation.resume(throwing: HomeBaseControlTransportError.closed)
            }
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { close() }
    func close() { finish(URLError(.cancelled)); connection.cancel() }
    private func finish(_ error: Error) {
        let callback = lock.withLock { () -> (@Sendable (Error?) -> Void)? in
            guard failure == nil else { return nil }
            failure = error; ready = false; return onClose
        }
        lifecycle.closed(error); callback?(error)
    }
    deinit { connection.cancel() }
}
