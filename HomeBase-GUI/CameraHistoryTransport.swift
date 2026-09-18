import Foundation
import HomeBaseProtocol

typealias CameraHistoryBeginHandler = @Sendable (CameraHistoryRange, Double?) async -> Void

nonisolated protocol CameraHistoryFetching: Sendable {
    func start() async
    func fetch(_ request: HBNVRMediaRequest, onBegin: CameraHistoryBeginHandler?) async throws -> CameraHistoryBatch
    func close() async
}

extension CameraHistoryFetching {
    nonisolated func fetch(_ request: HBNVRMediaRequest) async throws -> CameraHistoryBatch {
        try await fetch(request, onBegin: nil)
    }
}

nonisolated protocol CameraHistorySocket: Sendable {
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func close()
}

private nonisolated final class CameraHistoryURLSocket: CameraHistorySocket, @unchecked Sendable {
    let task: URLSessionWebSocketTask
    init(url: URL, session: URLSession) {
        task = session.webSocketTask(with: url, protocols: ["homebase.v2"])
        task.maximumMessageSize = 65_536
        task.resume()
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await task.send(message) }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
    func close() { task.cancel(with: .goingAway, reason: nil) }
    deinit { close() }
}

/// Owns a fresh logical session on a separate physical WebSocket. Control-session
/// resume tokens, acknowledgements and subscriptions never enter media mode.
actor CameraHistoryTransport: CameraHistoryFetching {
    private struct Connection: Sendable {
        let id = UUID()
        let socket: any CameraHistorySocket
        let keepalive: Bool
        let neighbors: Bool
        let thumbnails: Bool
        let opened: Double
    }
    private struct Opened: Decodable {
        let version: Int
        let framing: String
        let maxMessageBytes: Int
        let supportsKeepalive: Bool?
        let supportsNeighbors: Bool?
        let supportsThumbnails: Bool?
    }
    private struct Alive: Decodable { let type: String; let requestID: String }
    private let makeSocket: @Sendable () throws -> any CameraHistorySocket
    private let clientID: UUID
    private let requestTimeout: Double
    private var connection: Connection?
    private var opening: Task<Connection, Error>?
    private var maintenance: Task<Void, Never>?
    private var heartbeat: Task<Void, Error>?
    private var busy = false
    private var closed = false

    init(endpoint: HomeBaseEndpoint, clientID: UUID, session: URLSession) {
        self.clientID = clientID
        requestTimeout = 45
        makeSocket = {
            guard let url = endpoint.webSocketURL else { throw CameraHistoryError.unavailable }
            return CameraHistoryURLSocket(url: url, session: session)
        }
    }

    init(clientID: UUID = UUID(), requestTimeout: Double = 45,
         makeSocket: @escaping @Sendable () throws -> any CameraHistorySocket) {
        self.clientID = clientID; self.requestTimeout = requestTimeout; self.makeSocket = makeSocket
    }

    func start() {
        guard !closed, maintenance == nil else { return }
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.maintain()
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
            }
        }
    }

    // Internal for deterministic transport tests; the screen calls start once.
    func maintain() async {
        guard !closed, !busy else { return }
        do {
            let value = try await ready()
            guard !closed, !busy else { return }
            if value.keepalive {
                let task = Task { try await Self.keepAlive(value) }
                heartbeat = task
                defer { heartbeat = nil }
                try await task.value
            } else if ProcessInfo.processInfo.systemUptime - value.opened >= 40 {
                // Older servers expire idle media sessions after 60s. Keep a
                // connection prepared without polling availability or reading files.
                invalidate(value)
                _ = try await ready()
            }
        } catch {
            if let connection { invalidate(connection) }
            // Background preparation is best effort. Playback exposes actionable
            // retrieval errors; merely viewing Live must never raise an alert.
        }
    }

    func fetch(_ request: HBNVRMediaRequest, onBegin: CameraHistoryBeginHandler?) async throws -> CameraHistoryBatch {
        try request.validate()
        guard !closed, !busy else { throw CameraHistoryError.unavailable }
        busy = true
        defer { busy = false }
        if let heartbeat { try? await heartbeat.value }
        try Task.checkCancellation()
        let value = try await ready()
        guard request.operation != "neighbors" || value.neighbors else { throw CameraHistoryError.neighborsUnsupported }
        let deadline = ProcessInfo.processInfo.systemUptime + requestTimeout
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(requestTimeout)); value.socket.close() } catch {}
        }
        defer { watchdog.cancel() }
        var parser = CameraHistoryResponseParser(request: request)
        var reportedBegin = false
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let encoded = try JSONEncoder().encode(request)
                try await value.socket.send(.string(String(decoding: encoded, as: UTF8.self)))
                while parser.result == nil {
                    try Task.checkCancellation()
                    switch try await value.socket.receive() {
                    case .string(let text): try parser.text(Data(text.utf8))
                    case .data(let data): try parser.bytes(data)
                    @unknown default: throw CameraHistoryError.invalidResponse
                    }
                    if !reportedBegin, let range = parser.range {
                        reportedBegin = true
                        await onBegin?(range, parser.anchor)
                    }
                }
                return parser.result!
            } onCancel: { value.socket.close() }
        } catch {
            // A complete request-level error does not damage session framing.
            if case CameraHistoryError.remote = error {} else { invalidate(value) }
            if Task.isCancelled { throw CancellationError() }
            let error: Error = ProcessInfo.processInfo.systemUptime >= deadline ? URLError(.timedOut) : error
            if let range = parser.range { throw CameraHistoryFetchFailure(underlying: error, range: range, anchor: parser.anchor) }
            throw error
        }
    }

    func close() {
        closed = true
        maintenance?.cancel(); maintenance = nil
        heartbeat?.cancel(); heartbeat = nil
        opening?.cancel(); opening = nil
        connection?.socket.close(); connection = nil
    }

    /// Used by a separate timeline-preview transport, never the playback reader.
    func thumbnail(_ request: HBNVRThumbnailRequest) async throws -> CameraThumbnail? {
        try request.validate()
        guard !closed, !busy else { throw CameraHistoryError.unavailable }
        busy = true
        defer { busy = false }
        if let heartbeat { try? await heartbeat.value }
        try Task.checkCancellation()
        let value = try await ready()
        guard value.thumbnails else { throw CameraThumbnailError.unsupported }
        let deadline = ProcessInfo.processInfo.systemUptime + requestTimeout
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(requestTimeout)); value.socket.close() } catch {}
        }
        defer { watchdog.cancel() }
        var parser = CameraThumbnailParser(request: request)
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let data = try JSONEncoder().encode(request)
                try await value.socket.send(.string(String(decoding: data, as: UTF8.self)))
                while !parser.finished {
                    try Task.checkCancellation()
                    switch try await value.socket.receive() {
                    case .string(let text): try parser.text(Data(text.utf8))
                    case .data(let data): try parser.bytes(data)
                    @unknown default: throw CameraHistoryError.invalidResponse
                    }
                }
                return parser.result
            } onCancel: { value.socket.close() }
        } catch {
            if case CameraHistoryError.remote = error {} else { invalidate(value) }
            if Task.isCancelled { throw CancellationError() }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw URLError(.timedOut) }
            throw error
        }
    }

    private func invalidate(_ value: Connection) {
        value.socket.close()
        if connection?.id == value.id { connection = nil }
    }

    private func ready() async throws -> Connection {
        guard !closed else { throw CancellationError() }
        if let connection { return connection }
        if let opening { return try await opening.value }
        let task = Task { [makeSocket, clientID] in
            let socket = try makeSocket()
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(10)); socket.close() } catch {}
            }
            defer { watchdog.cancel() }
            do {
                return try await withTaskCancellationHandler {
                    let open = HBProtocolEnvelope(messageKind: .request, clientID: clientID,
                                                  operation: HBProtocolOperations.openSession)
                    let response = try await Self.exchange(open, on: socket)
                    let session = try response.decodedPayload(as: HBProtocolResponse.self)
                        .decodedResult(as: HBWebSocketSessionOpened.self)
                    guard response.sessionID == session.sessionID else { throw CameraHistoryError.invalidResponse }
                    var upgrade = try HBProtocolEnvelope.request(operation: HBProtocolOperations.openNVRMedia,
                        clientID: clientID, payload: HBNVRMediaOpenRequest())
                    upgrade.sessionID = session.sessionID
                    let upgraded = try await Self.exchange(upgrade, on: socket)
                    let info = try upgraded.decodedPayload(as: HBProtocolResponse.self).decodedResult(as: Opened.self)
                    guard info.version == 1, info.maxMessageBytes == 65_536,
                          info.framing == "websocket-text-json,binary-chunks" else { throw CameraHistoryError.invalidResponse }
                    try Task.checkCancellation()
                    return Connection(socket: socket, keepalive: info.supportsKeepalive == true, neighbors: info.supportsNeighbors == true,
                                      thumbnails: info.supportsThumbnails == true,
                                      opened: ProcessInfo.processInfo.systemUptime)
                } onCancel: { socket.close() }
            } catch { socket.close(); throw error }
        }
        opening = task
        defer { opening = nil }
        let value = try await task.value
        guard !closed else { value.socket.close(); throw CancellationError() }
        connection = value
        return value
    }

    private static func exchange(_ request: HBProtocolEnvelope, on socket: any CameraHistorySocket) async throws -> HBProtocolEnvelope {
        let data = try JSONEncoder().encode(request)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        // Ordinary session events can arrive just before the upgrade response.
        // They belong to this disposable session, not the control connection.
        for _ in 0..<256 {
            guard case .string(let text) = try await socket.receive(), text.utf8.count <= 65_536 else {
                throw CameraHistoryError.invalidResponse
            }
            let response = try JSONDecoder().decode(HBProtocolEnvelope.self, from: Data(text.utf8))
            try response.validate()
            guard response.clientID == request.clientID,
                  request.sessionID == nil || response.sessionID == request.sessionID else {
                throw CameraHistoryError.invalidResponse
            }
            if response.messageKind == .event { continue }
            guard response.messageKind == .response, response.requestID == request.requestID,
                  response.operation == request.operation else { throw CameraHistoryError.invalidResponse }
            return response
        }
        throw CameraHistoryError.invalidResponse
    }

    private static func keepAlive(_ value: Connection) async throws {
        let id = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: ["operation": "keepalive", "requestID": id])
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(5)); value.socket.close() } catch {}
        }
        defer { watchdog.cancel() }
        try await withTaskCancellationHandler {
            try await value.socket.send(.string(String(decoding: data, as: UTF8.self)))
            guard case .string(let text) = try await value.socket.receive(), text.utf8.count <= 65_536 else {
                throw CameraHistoryError.invalidResponse
            }
            let reply = try JSONDecoder().decode(Alive.self, from: Data(text.utf8))
            guard reply.type == "alive", reply.requestID == id else { throw CameraHistoryError.invalidResponse }
        } onCancel: { value.socket.close() }
    }
}
