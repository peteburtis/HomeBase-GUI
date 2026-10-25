import Foundation
import HomeBaseProtocol

nonisolated struct HomeBaseControlConnectionState: Sendable, Equatable {
    var route: HomeBaseControlRoute? = nil
    var recovering = false
    var error: String? = nil
}

/// A persistent Noise stream can carry successive logical attachments. Old
/// queued deliveries must drain before the new handshake becomes visible.
nonisolated struct BluetoothCnCAttachmentState {
    enum Delivery: Equatable { case discard, message, detached }
    private(set) var requestID: UUID?
    private var operation: String?
    private var ready = false
    mutating func begin(_ request: HBProtocolEnvelope) {
        requestID = request.requestID; operation = request.operation; ready = false
    }
    mutating func reset() { requestID = nil; operation = nil; ready = false }
    mutating func receive(_ envelope: HBProtocolEnvelope) -> Delivery {
        guard let requestID else { return .discard }
        if envelope.operation == "bluetooth.cnc.detached" {
            guard envelope.messageKind == .event, envelope.requestID == requestID else { return .discard }
            reset(); return .detached
        }
        if !ready {
            guard envelope.messageKind == .response, envelope.requestID == requestID,
                  envelope.operation == operation else { return .discard }
            ready = true
        }
        return .message
    }
}

nonisolated enum HomeBaseControlRoute: String, Sendable, Equatable {
    case webSocket, bluetooth
    var displayName: String { self == .webSocket ? "Wi-Fi / Network" : "Bluetooth" }
}

/// Carries complete protocol messages. Session ownership and replay remain in
/// HomeBaseWebSocketClient, independent of the physical connection.
nonisolated protocol HomeBaseControlTransport: AnyObject, Sendable {
    var route: HomeBaseControlRoute { get }
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

nonisolated final class HomeBaseWebSocketTransport: HomeBaseControlTransport, @unchecked Sendable {
    let route = HomeBaseControlRoute.webSocket
    private let socket: any HomeBaseControlSocket
    init(socket: any HomeBaseControlSocket) {
        self.socket = socket
        socket.maximumMessageSize = 16 * 1_024 * 1_024
        socket.resume()
    }
    func send(_ data: Data) async throws {
        // The HomeBase WebSocket protocol uses JSON text frames. Binary frames
        // are reserved for media and are rejected by the control endpoint.
        guard let text = String(data: data, encoding: .utf8) else {
            throw HomeBaseControlTransportError.invalidMessage
        }
        try await socket.send(.string(text))
    }
    func receive() async throws -> Data {
        switch try await socket.receive() {
        case .data(let data): return data
        case .string(let value): return Data(value.utf8)
        @unknown default: throw HomeBaseControlTransportError.invalidMessage
        }
    }
    func close() { socket.cancel(with: .goingAway, reason: nil) }
}

nonisolated enum HomeBaseControlTransportError: LocalizedError {
    case unavailable, closed, invalidMessage, networkRequired, background, requestTimedOut
    var errorDescription: String? {
        switch self {
        case .unavailable: "Bluetooth control is not ready. Connect over the network once to upgrade this pairing."
        case .closed: "The control connection closed."
        case .invalidMessage: "The control connection returned an invalid message."
        case .networkRequired: "Camera video and recordings need a network connection. Home controls remain available over Bluetooth."
        case .background: "Bluetooth controls resume when HomeBase is in the foreground."
        case .requestTimedOut: "The controller did not confirm this request before its deadline. It may have completed; check the current state before trying again."
        }
    }
}

/// The central owns the streams on MainActor. This bounded mailbox crosses to
/// the client actor without installing another stream reader or radio timer.
nonisolated final class HomeBaseBluetoothTransport: HomeBaseControlTransport, @unchecked Sendable {
    let route = HomeBaseControlRoute.bluetooth
    let identifier = UUID()
    private let lock = NSLock()
    private var queue: [Data] = []
    private var queuedBytes = 0
    private var receiver: CheckedContinuation<Data, Error>?
    private var failure: Error?
    private var didClose = false
    private let sender: @MainActor @Sendable (Data) throws -> Void
    private let closer: @MainActor @Sendable () -> Void

    init(sender: @escaping @MainActor @Sendable (Data) throws -> Void,
         closer: @escaping @MainActor @Sendable () -> Void) {
        self.sender = sender; self.closer = closer
    }
    func send(_ data: Data) async throws {
        if let error = lock.withLock({ failure }) { throw error }
        try await sender(data)
    }
    func receive() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let failure { lock.unlock(); continuation.resume(throwing: failure) }
                else if !queue.isEmpty {
                    let first = queue.removeFirst(); queuedBytes -= first.count
                    lock.unlock(); continuation.resume(returning: first)
                } else if receiver != nil {
                    lock.unlock(); continuation.resume(throwing: HomeBaseControlTransportError.invalidMessage)
                } else { receiver = continuation; lock.unlock() }
            }
        } onCancel: { self.close() }
    }
    func deliver(_ data: Data) {
        lock.lock()
        guard failure == nil else { lock.unlock(); return }
        if let receiver { self.receiver = nil; lock.unlock(); receiver.resume(returning: data) }
        else if queue.count < 4_096 && queuedBytes + data.count <= 32 * 1_024 * 1_024 {
            queue.append(data); queuedBytes += data.count; lock.unlock()
        } else { lock.unlock(); finish(HomeBaseControlTransportError.invalidMessage); close() }
    }
    func finish(_ error: Error = HomeBaseControlTransportError.closed) {
        lock.lock()
        guard failure == nil else { lock.unlock(); return }
        failure = error
        let waiting = receiver; receiver = nil; queue.removeAll(); queuedBytes = 0
        lock.unlock(); waiting?.resume(throwing: error)
    }
    func close() {
        let shouldClose = lock.withLock { if didClose { return false }; didClose = true; return true }
        guard shouldClose else { return }
        finish(); Task { @MainActor in closer() }
    }
}

/// One ordered control lane. A large command, its detach, and the next attach
/// complete in wire order; fragmentation never changes application ordering.
@MainActor
final class BluetoothCnCOutboundQueue {
    private struct Item {
        let message: HBBluetoothCnCOutboundMessage
        let barrier: Bool
        let byteCount: Int
    }
    private let channel: HBBluetoothCnCChannel
    private var items: [Item] = []
    private var remainingBytes = 0
    var isEmpty: Bool { items.isEmpty }
    init(channel: HBBluetoothCnCChannel) { self.channel = channel }
    func enqueue(_ data: Data, barrier: Bool = false) throws {
        guard items.count < 4_096, remainingBytes + data.count <= 32 * 1_024 * 1_024 else {
            throw HomeBaseControlTransportError.invalidMessage
        }
        let message = try channel.makeOutboundMessage(data)
        remainingBytes += data.count
        items.append(Item(message: message, barrier: barrier, byteCount: data.count))
    }
    func nextRecord() throws -> Data? {
        guard !items.isEmpty else { return nil }
        let item = items[0]
        let record = try channel.sealNextChunk(of: item.message)
        if item.message.isComplete {
            remainingBytes -= item.byteCount
            items.removeFirst()
        }
        return record
    }
}
