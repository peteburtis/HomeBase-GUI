import Combine
import Foundation

/// One status for a server window. The actual transport is authoritative;
/// visible screens contribute loading/failure feedback for their subscriptions.
@MainActor
final class ConnectionStatusController: ObservableObject {
    @Published private(set) var presentation: ConnectionStatusPresentation?
    @Published private(set) var route: HomeBaseControlRoute?
    @Published private(set) var canRetry = false

    private struct Report {
        var presentation: ConnectionStatusPresentation
        var retry: (() -> Void)?
        let order: Int
    }
    private var connection: ConnectionStatusPresentation?
    private var connectionRetry: (() -> Void)?
    private var reports: [UUID: Report] = [:]
    private var nextOrder = 0
    private var retryActions: [() -> Void] = []
    var visibleReportCount: Int { reports.count }

    private var isActive = true
    private var foregroundRecoveryID: UUID?
    private var foregroundRecoveryTask: Task<Void, Never>?
    private let foregroundRecoveryDelay: @Sendable () async throws -> Void

    init(foregroundRecoveryDelay: @escaping @Sendable () async throws -> Void = {
        try await Task.sleep(for: .seconds(2))
    }) {
        self.foregroundRecoveryDelay = foregroundRecoveryDelay
    }

    nonisolated deinit { foregroundRecoveryTask?.cancel() }

    /// Background teardown can fail both the transport and its subscriptions.
    /// Give foreground recovery one bounded window before exposing those errors.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        foregroundRecoveryTask?.cancel()
        foregroundRecoveryTask = nil
        foregroundRecoveryID = nil
        if active {
            let id = UUID()
            foregroundRecoveryID = id
            let delay = foregroundRecoveryDelay
            foregroundRecoveryTask = Task { [weak self] in
                do { try await delay() } catch { return }
                guard !Task.isCancelled, let self, self.foregroundRecoveryID == id else { return }
                self.foregroundRecoveryID = nil
                self.foregroundRecoveryTask = nil
                self.coalesce()
            }
        }
        coalesce()
    }

    func updateConnection(presentation: ConnectionStatusPresentation,
                          route: HomeBaseControlRoute?, retry: (() -> Void)? = nil) {
        connection = presentation
        connectionRetry = retry
        if self.route != route { self.route = route }
        coalesce()
    }

    func update(_ id: UUID, presentation: ConnectionStatusPresentation?, retry: (() -> Void)? = nil) {
        guard let presentation else { remove(id); return }
        let order = reports[id]?.order ?? nextOrder
        if reports[id] == nil { nextOrder += 1 }
        reports[id] = Report(presentation: presentation, retry: retry, order: order)
        coalesce()
    }

    func remove(_ id: UUID) {
        guard reports.removeValue(forKey: id) != nil else { return }
        coalesce()
    }

    func retry() { retryActions.forEach { $0() } }

    private func coalesce() {
        let ordered = reports.values.sorted { $0.order < $1.order }
        let failures = ordered.filter { if case .failed = $0.presentation { true } else { false } }
        let loading = ordered.first { if case .pending = $0.presentation { true } else { false } }
        var result: ConnectionStatusPresentation?
        retryActions = []
        switch connection {
        case .failed:
            result = connection
            if let connectionRetry { retryActions.append(connectionRetry) }
            retryActions.append(contentsOf: failures.compactMap(\.retry))
        case .pending, .disconnected:
            // A stale live subscription must never mask a lost transport.
            result = connection
        case .connected, nil:
            if let failure = failures.first {
                result = failure.presentation
                retryActions = failures.compactMap(\.retry)
            } else if let loading {
                result = loading.presentation
            } else {
                // A paused screen isn't a disconnected server. Idle reports do
                // not override a healthy route, including during navigation.
                result = connection ?? ordered.first?.presentation
            }
        }
        // Keep updates underneath the temporary presentation. A real recovery
        // may show connected immediately; a persistent failure reappears when
        // the fixed window ends, even if no further transport events arrive.
        if !isActive {
            result = .pending("Connecting…")
            retryActions = []
        } else if foregroundRecoveryID != nil {
            switch result {
            case .failed, .disconnected:
                result = .pending("Connecting…")
                retryActions = []
            default: break
            }
        }
        if presentation != result { presentation = result }
        let available = !retryActions.isEmpty
        if canRetry != available { canRetry = available }
    }
}
