import Foundation
@preconcurrency import Network

/// A narrow boundary for deterministic dropped/silent-connection tests.
nonisolated protocol HomeBaseControlSocket: AnyObject, Sendable {
    var maximumMessageSize: Int { get set }
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
}

extension URLSessionWebSocketTask: HomeBaseControlSocket {}

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
