import Foundation

/// Owns physical carrier lifetimes independently of the application session.
/// A ready route never waits for another route's attempt or cancellation.
actor HomeBaseCarrierCoordinator {
    typealias Factory = @Sendable () async throws -> any HomeBaseControlTransport

    nonisolated struct Carrier: Sendable {
        let id: UUID
        let route: HomeBaseControlRoute
        let transport: any HomeBaseControlTransport
    }

    nonisolated enum Event: Sendable {
        case ready(Carrier)
        case lost(Carrier)
        case failed(HomeBaseControlRoute, Error)
        case suspended(HomeBaseControlRoute)
    }

    nonisolated enum CoordinatorError: LocalizedError {
        case unavailable, timedOut, stopped

        var errorDescription: String? {
            switch self {
            case .unavailable: "No control connection is available."
            case .timedOut: "The control connection did not become ready before its deadline."
            case .stopped: "The control connection was stopped."
            }
        }
    }

    private struct RouteState {
        var attemptID: UUID?
        var attempt: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var preparing: (any HomeBaseControlTransport)?
        var ready: Carrier?
        var closureMonitor: Task<Void, Never>?
        var retryID: UUID?
        var retry: Task<Void, Never>?
        var failure: Error?
        var retiredCarrierID: UUID?
    }

    private struct Acquisition {
        let excluding: HomeBaseControlRoute?
        let continuation: CheckedContinuation<Carrier, Error>
        let deadline: Task<Void, Never>
    }

    private let webSocket: Factory
    private let bluetooth: Factory?
    private let webSocketAttemptTimeout: Duration
    private let bluetoothAttemptTimeout: Duration
    private let retryDelay: Duration
    private var foreground: Bool
    private var started = false
    private var stopped = false
    private var routes: [HomeBaseControlRoute: RouteState] = [
        .webSocket: RouteState(), .bluetooth: RouteState()
    ]
    private var acquisitions: [UUID: Acquisition] = [:]
    private var observers: [UUID: AsyncStream<Event>.Continuation] = [:]

    init(
        webSocket: @escaping Factory,
        bluetooth: Factory? = nil,
        webSocketAttemptTimeout: Duration = .seconds(15),
        bluetoothAttemptTimeout: Duration = .seconds(60),
        retryDelay: Duration = .seconds(2),
        foreground: Bool = true
    ) {
        self.webSocket = webSocket
        self.bluetooth = bluetooth
        self.webSocketAttemptTimeout = webSocketAttemptTimeout
        self.bluetoothAttemptTimeout = bluetoothAttemptTimeout
        self.retryDelay = retryDelay
        self.foreground = foreground
    }

    deinit {
        for state in routes.values {
            state.attempt?.cancel()
            state.deadline?.cancel()
            state.retry?.cancel()
            state.closureMonitor?.cancel()
            state.preparing?.close()
            state.ready?.transport.close()
        }
        for acquisition in acquisitions.values {
            acquisition.deadline.cancel()
            acquisition.continuation.resume(throwing: CoordinatorError.stopped)
        }
        for observer in observers.values { observer.finish() }
    }

    func start() {
        guard !started, !stopped else { return }
        started = true
        startAttempt(.webSocket)
        startAttempt(.bluetooth)
    }

    func setForeground(_ active: Bool) {
        guard foreground != active else { return }
        foreground = active
        if active {
            startAttempt(.webSocket)
            startAttempt(.bluetooth)
        } else {
            // Keep an already usable network carrier, but do not poll for a
            // replacement while the application has no foreground demand.
            routes[.webSocket]?.retry?.cancel()
            routes[.webSocket]?.retry = nil
            routes[.webSocket]?.retryID = nil
            retire(.bluetooth, invalidate: false)
            emit(.suspended(.bluetooth))
            resolveAcquisitions()
        }
    }

    func updates() -> AsyncStream<Event> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            for route in [HomeBaseControlRoute.webSocket, .bluetooth] {
                if let carrier = routes[route]?.ready { continuation.yield(.ready(carrier)) }
            }
            if stopped { continuation.finish() }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    /// The session owner serializes calls to this method. The same carrier can
    /// be inspected repeatedly until it is explicitly discarded or closes.
    func acquirePreferred(
        excluding: HomeBaseControlRoute? = nil,
        timeout: Duration = .seconds(65)
    ) async throws -> Carrier {
        try Task.checkCancellation()
        guard !stopped else { throw CoordinatorError.stopped }
        start()
        if let ready = preferred(excluding: excluding) { return ready }
        if let error = terminalFailure(excluding: excluding) { throw error }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.finishAcquisition(id, result: .failure(CoordinatorError.timedOut))
                }
                acquisitions[id] = Acquisition(excluding: excluding, continuation: continuation, deadline: deadline)
            }
        } onCancel: {
            Task { [weak self] in
                await self?.finishAcquisition(id, result: .failure(CancellationError()))
            }
        }
    }

    func isCurrent(_ carrier: Carrier) -> Bool {
        routes[carrier.route]?.ready?.id == carrier.id && eligible(carrier.route)
    }

    func readyCarrier(for route: HomeBaseControlRoute) -> Carrier? {
        eligible(route) ? routes[route]?.ready : nil
    }

    /// A concrete network/lifecycle signal can advance a scheduled retry. It
    /// never duplicates an attempt already preparing or replaces a ready route.
    func retryUnavailable(_ route: HomeBaseControlRoute) {
        guard started, eligible(route), routes[route]?.ready == nil,
              routes[route]?.attemptID == nil else { return }
        routes[route]?.retry?.cancel()
        routes[route]?.retry = nil
        routes[route]?.retryID = nil
        startAttempt(route)
    }

    /// Ordinary release retires the logical attachment. A failed carrier can
    /// additionally invalidate its underlying physical connection before retry.
    func discard(_ carrier: Carrier, invalidate: Bool = false) {
        guard let state = routes[carrier.route] else { return }
        if state.ready == nil, state.retiredCarrierID == carrier.id {
            // A session handshake can close its carrier before its caller
            // reports the failure. Acknowledge that same retirement so a
            // fresh-session attempt waits for the replacement instead of
            // inheriting the close error from the old attachment.
            if invalidate { carrier.transport.invalidate() }
            routes[carrier.route]?.failure = nil
            scheduleRetry(carrier.route)
            return
        }
        guard state.ready?.id == carrier.id else { return }
        retire(carrier.route, invalidate: invalidate)
        emit(.lost(carrier))
        scheduleRetry(carrier.route)
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        started = false
        retire(.webSocket, invalidate: false)
        retire(.bluetooth, invalidate: false)
        for id in Array(acquisitions.keys) {
            finishAcquisition(id, result: .failure(CoordinatorError.stopped))
        }
        for observer in observers.values { observer.finish() }
        observers.removeAll()
    }

    private func eligible(_ route: HomeBaseControlRoute) -> Bool {
        !stopped && (route == .webSocket || (foreground && bluetooth != nil))
    }

    private func startAttempt(_ route: HomeBaseControlRoute) {
        guard started, eligible(route), let state = routes[route],
              state.ready == nil, state.attemptID == nil, state.retryID == nil else { return }
        let factory: Factory
        if route == .webSocket { factory = webSocket }
        else if let bluetooth { factory = bluetooth }
        else { return }
        let id = UUID()
        let timeout = route == .webSocket ? webSocketAttemptTimeout : bluetoothAttemptTimeout
        routes[route]?.attemptID = id
        routes[route]?.failure = nil
        routes[route]?.retiredCarrierID = nil
        routes[route]?.deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.attemptFailed(route, id: id, error: URLError(.timedOut))
        }
        routes[route]?.attempt = Task { [weak self] in
            do {
                let transport = try await factory()
                guard await self?.register(transport, route: route, id: id) == true else {
                    transport.close()
                    return
                }
                try await transport.waitUntilReady()
                if let self { await self.attemptReady(transport, route: route, id: id) }
                else { transport.close() }
            } catch {
                await self?.attemptFailed(route, id: id, error: error)
            }
        }
    }

    private func register(_ transport: any HomeBaseControlTransport, route: HomeBaseControlRoute, id: UUID) -> Bool {
        guard eligible(route), routes[route]?.attemptID == id else { return false }
        guard transport.route == route else {
            transport.close()
            attemptFailed(route, id: id, error: HomeBaseControlTransportError.invalidMessage)
            return false
        }
        routes[route]?.preparing = transport
        return true
    }

    private func attemptReady(_ transport: any HomeBaseControlTransport, route: HomeBaseControlRoute, id: UUID) {
        guard eligible(route), routes[route]?.attemptID == id else {
            transport.close()
            return
        }
        let carrier = Carrier(id: id, route: route, transport: transport)
        routes[route]?.deadline?.cancel()
        routes[route]?.deadline = nil
        routes[route]?.attempt = nil
        routes[route]?.attemptID = nil
        routes[route]?.preparing = nil
        routes[route]?.failure = nil
        routes[route]?.retiredCarrierID = nil
        routes[route]?.ready = carrier
        routes[route]?.closureMonitor = Task { [weak self] in
            await transport.waitUntilClosed()
            guard !Task.isCancelled else { return }
            await self?.carrierClosed(carrier)
        }
        emit(.ready(carrier))
        resolveAcquisitions()
    }

    private func attemptFailed(_ route: HomeBaseControlRoute, id: UUID, error: Error) {
        guard routes[route]?.attemptID == id else { return }
        retire(route, invalidate: true)
        routes[route]?.failure = error
        emit(.failed(route, error))
        resolveAcquisitions()
        scheduleRetry(route)
    }

    private func carrierClosed(_ carrier: Carrier) {
        guard routes[carrier.route]?.ready?.id == carrier.id else { return }
        retire(carrier.route, invalidate: false)
        routes[carrier.route]?.failure = HomeBaseControlTransportError.closed
        emit(.lost(carrier))
        resolveAcquisitions()
        scheduleRetry(carrier.route)
    }

    private func retire(_ route: HomeBaseControlRoute, invalidate: Bool) {
        guard let state = routes[route] else { return }
        // Clear ownership before cancellation or closure can report completion.
        routes[route] = RouteState(retiredCarrierID: state.ready?.id ?? state.retiredCarrierID)
        state.attempt?.cancel()
        state.deadline?.cancel()
        state.retry?.cancel()
        state.closureMonitor?.cancel()
        if invalidate {
            state.preparing?.invalidate()
            state.ready?.transport.invalidate()
        } else {
            state.preparing?.close()
            state.ready?.transport.close()
        }
    }

    private func scheduleRetry(_ route: HomeBaseControlRoute) {
        guard started, foreground, eligible(route), routes[route]?.retryID == nil,
              routes[route]?.ready == nil, routes[route]?.attemptID == nil else { return }
        let id = UUID()
        let delay = retryDelay
        routes[route]?.retryID = id
        routes[route]?.retry = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.retry(route, id: id)
        }
    }

    private func retry(_ route: HomeBaseControlRoute, id: UUID) {
        guard routes[route]?.retryID == id else { return }
        routes[route]?.retryID = nil
        routes[route]?.retry = nil
        guard foreground else { return }
        startAttempt(route)
    }

    private func preferred(excluding: HomeBaseControlRoute?) -> Carrier? {
        for route in [HomeBaseControlRoute.webSocket, .bluetooth] where route != excluding && eligible(route) {
            if let ready = routes[route]?.ready { return ready }
        }
        return nil
    }

    private func terminalFailure(excluding: HomeBaseControlRoute?) -> Error? {
        let eligibleRoutes = [HomeBaseControlRoute.webSocket, .bluetooth].filter { $0 != excluding && eligible($0) }
        guard !eligibleRoutes.isEmpty else { return CoordinatorError.unavailable }
        guard eligibleRoutes.allSatisfy({ routes[$0]?.failure != nil }) else { return nil }
        return eligibleRoutes.compactMap { routes[$0]?.failure }.first
    }

    private func resolveAcquisitions() {
        for (id, acquisition) in acquisitions {
            if let ready = preferred(excluding: acquisition.excluding) {
                finishAcquisition(id, result: .success(ready))
            } else if let error = terminalFailure(excluding: acquisition.excluding) {
                finishAcquisition(id, result: .failure(error))
            }
        }
    }

    private func finishAcquisition(_ id: UUID, result: Result<Carrier, Error>) {
        guard let acquisition = acquisitions.removeValue(forKey: id) else { return }
        acquisition.deadline.cancel()
        acquisition.continuation.resume(with: result)
    }

    private func emit(_ event: Event) {
        for observer in observers.values { observer.yield(event) }
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
}
