import Foundation
@preconcurrency import Network

/// A narrow boundary for deterministic dropped/silent-connection tests.
nonisolated protocol HomeBaseControlSocket: AnyObject, Sendable {
    var maximumMessageSize: Int { get set }
    func observeLifecycle(onOpen: @escaping @Sendable () -> Void,
                          onClose: @escaping @Sendable (Error?) -> Void)
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
}

extension HomeBaseControlSocket {
    // In-memory sockets have no upgrade exchange. The production Network
    // adapter reports readiness after TLS and the WebSocket upgrade complete.
    nonisolated func observeLifecycle(onOpen: @escaping @Sendable () -> Void,
                          onClose: @escaping @Sendable (Error?) -> Void) { onOpen() }
}

/// Old commands must fail when the server can no longer account for them.
/// Read-only monitoring can catch this signal and obtain a fresh snapshot.
nonisolated struct HomeBaseSessionResetError: LocalizedError {
    var errorDescription: String? {
        "The connection was interrupted. Check the current state before trying again."
    }
}

@MainActor
enum HomeBaseObservationRecovery {
    /// Scope this to observations, never actions or configuration writes. A
    /// failed fresh connection throws its actual error and ends the retry.
    static func run(
        onSessionReset: () async -> Void,
        operation: () async throws -> Void
    ) async throws {
        while true {
            try Task.checkCancellation()
            do {
                try await operation()
                return
            } catch is HomeBaseSessionResetError {
                try Task.checkCancellation()
                await onSessionReset()
            }
        }
    }
}

/// Advisory notifications only: an available interface does not prove that a
/// VPN route or HomeBase is reachable. Actual attempts and deadlines decide.
nonisolated final class CameraNetworkPathMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    // Accessed only on the monitor's serial queue.
    private var receivedInitialPath = false

    init(changed: @escaping @Sendable () -> Void) {
        // All calls are serialized by the monitor's queue.
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            guard self.receivedInitialPath else { self.receivedInitialPath = true; return }
            changed()
        }
        monitor.start(queue: DispatchQueue(label: "io.pjb.HomeBase-GUI.CameraNetworkPath"))
    }

    func cancel() { monitor.cancel() }
    deinit { monitor.cancel() }
}
