import Foundation

/// Bounds the whole exchange, including a send still waiting for its carrier.
/// Completion never waits for a cancelled implementation to finish unwinding.
nonisolated func withHomeBaseConnectionDeadline<Value: Sendable>(
    seconds: TimeInterval,
    cancel: @escaping @Sendable () -> Void,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let exchange = HomeBaseConnectionDeadline<Value>(cancel: cancel)
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            exchange.start(continuation, seconds: seconds, operation: operation)
        }
    } onCancel: {
        exchange.finish(.failure(CancellationError()), interrupt: true)
    }
}

nonisolated private final class HomeBaseConnectionDeadline<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let cancel: @Sendable () -> Void
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    init(cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }

    func start(_ continuation: CheckedContinuation<Value, Error>, seconds: TimeInterval,
               operation: @escaping @Sendable () async throws -> Value) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        worker = Task {
            do { self.finish(.success(try await operation()), interrupt: false) }
            catch { self.finish(.failure(error), interrupt: false) }
        }
        timer = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self.finish(.failure(URLError(.timedOut)), interrupt: true)
        }
        lock.unlock()
    }

    func finish(_ result: Result<Value, Error>, interrupt: Bool) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation, worker = worker, timer = timer
        self.continuation = nil; self.worker = nil; self.timer = nil
        lock.unlock()
        timer?.cancel()
        if interrupt { cancel(); worker?.cancel() }
        continuation?.resume(with: result)
    }
}
