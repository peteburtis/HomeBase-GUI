import Foundation

/// Owns monitoring for a screen's identity, not its transient appearance during
/// split-view reparenting. Keep this alongside the screen's model in SwiftUI state.
@MainActor
final class LiveMonitoringSession {
    private var task: Task<Void, Never>?
    private var isActive = false
    private var operation: (@MainActor () async -> Void)?

    deinit { task?.cancel() }

    func setActive(
        _ active: Bool,
        operation: @escaping @MainActor () async -> Void
    ) {
        self.operation = operation
        guard active != isActive else { return }
        isActive = active
        replaceTask()
    }

    /// An explicit user retry, not an appearance callback.
    func restart() {
        guard isActive else { return }
        replaceTask()
    }

    private func replaceTask() {
        let previous = task
        previous?.cancel()
        let active = isActive
        let operation = operation
        task = Task {
            // Background/foreground changes and explicit retries must finish
            // the previous subscription's cleanup before starting another.
            await previous?.value
            guard active, !Task.isCancelled else { return }
            await operation?()
        }
    }
}
