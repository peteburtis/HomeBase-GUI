//
//  HomeBaseWebSocketClient.swift
//  HomeBase-GUI
//

import Foundation
import HomeBaseProtocol
import OSLog

actor HomeBaseWebSocketClient {
    struct DeviceMetadataSubscription: Sendable {
        let details: HBDeviceDescriptor
        let metadata: [String: HBJSONValue]
        let events: AsyncThrowingStream<[String: HBJSONValue], Error>
    }
    private struct MetadataObserver {
        let identifiers: Set<String>
        let continuation: AsyncThrowingStream<[String: HBJSONValue], Error>.Continuation
        var state = DeviceMetadataObservation()
    }
    private var metadataObservers: [UUID: MetadataObserver] = [:]
    struct CameraLiveLease: Sendable {
        let mediaHost: String
        let opened: HBCameraLiveOpenResult
    }

    struct ControlSubscription: Sendable {
        let identifier: UUID
        let controls: [HBControlWatchStreamControl]
        let events: AsyncThrowingStream<HBControlWatchStreamEvent, Error>
    }

    struct SceneSubscription: Sendable {
        let identifier: UUID
        let scenes: [HBSceneStateResult]
        let events: AsyncThrowingStream<HBSceneWatchStreamEvent, Error>
    }

    struct TriggerSubscription: Sendable {
        let identifier: UUID
        let triggers: [HBTriggerStateResult]
        let events: AsyncThrowingStream<HBTriggerWatchStreamEvent, Error>
    }

    struct ControlStackSubscription: Sendable {
        let identifier: UUID
        let controls: [String]
        let events: AsyncThrowingStream<
            HBControlStackWatchStreamEvent,
            Error
        >
    }

    enum ClientError: Error, LocalizedError {
        case invalidEndpoint
        case notConnected
        case invalidMessage(String)
        case invalidDeliverySequence(expected: Int64, received: Int64)
        case subscriptionEnded(String)
        case resynchronizationRequired(String)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                "The saved HomeBase endpoint is invalid."
            case .notConnected:
                "The HomeBase server is not connected."
            case .invalidMessage(let reason):
                "The HomeBase server sent an invalid message: \(reason)"
            case .invalidDeliverySequence(let expected, let received):
                "The HomeBase message stream skipped from sequence \(expected) to \(received)."
            case .subscriptionEnded(let reason):
                "The HomeBase subscription ended: \(reason)"
            case .resynchronizationRequired(let reason):
                "The HomeBase session must be rebuilt: \(reason)"
            }
        }
    }

    private static let webSocketSubprotocol = "homebase.v2"
    private static let maximumBufferedSubscriptionEvents = 4_096
    private static let controlWriteLogger = Logger(
        subsystem: "io.pjb.HomeBase-GUI",
        category: "ControlWrite"
    )
    private static let connectionLogger = Logger(
        subsystem: "io.pjb.HomeBase-GUI",
        category: "Connection"
    )

    private let endpoint: HomeBaseEndpoint
    private let clientID: UUID
    private let urlSession: URLSession
    private let makeControlSocket: @Sendable (URL) -> any HomeBaseControlSocket
    private let requestTimeout: TimeInterval
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var task: (any HomeBaseControlSocket)?
    private var connectionAttempt: Task<Void, Error>?
    private var connectionAttemptID: UUID?
    private var reactivationAttempt: Task<Void, Error>?
    private var reactivationAttemptID: UUID?
    private var connectionGeneration: UInt64 = 0
    private var networkMonitor: CameraNetworkPathMonitor?
    private var pathRecoveryTask: Task<Void, Never>?
    private var sessionID: UUID?
    private var resumeToken: String?
    private var serverInstanceID: UUID?
    private var receiveTask: Task<Void, Never>?
    private var acknowledgementTask: Task<Void, Never>?
    private var pendingResponses: [
        UUID: CheckedContinuation<HBProtocolEnvelope, Error>
    ] = [:]
    private var activeSubscriptions: Set<UUID> = []
    private var abandonedSubscriptions: Set<UUID> = []
    private var controlSubscriptionContinuations: [
        UUID: AsyncThrowingStream<HBControlWatchStreamEvent, Error>.Continuation
    ] = [:]
    private var bufferedControlSubscriptionEvents: [
        UUID: [HBControlWatchStreamEvent]
    ] = [:]
    private var sceneSubscriptionContinuations: [
        UUID: AsyncThrowingStream<HBSceneWatchStreamEvent, Error>.Continuation
    ] = [:]
    private var bufferedSceneSubscriptionEvents: [
        UUID: [HBSceneWatchStreamEvent]
    ] = [:]
    private var triggerSubscriptionContinuations: [
        UUID: AsyncThrowingStream<
            HBTriggerWatchStreamEvent,
            Error
        >.Continuation
    ] = [:]
    private var bufferedTriggerSubscriptionEvents: [
        UUID: [HBTriggerWatchStreamEvent]
    ] = [:]
    private var controlStackSubscriptionContinuations: [
        UUID: AsyncThrowingStream<
            HBControlStackWatchStreamEvent,
            Error
        >.Continuation
    ] = [:]
    private var bufferedControlStackSubscriptionEvents: [
        UUID: [HBControlStackWatchStreamEvent]
    ] = [:]
    private var subscriptionSequences: [UUID: Int64] = [:]
    private var latestDeliverySequence: Int64 = 0
    private var acknowledgedDeliverySequence: Int64 = 0
    private var liveStreamArbiter: CameraStreamArbiter?

    init(
        endpoint: HomeBaseEndpoint,
        clientID: UUID = UUID(),
        urlSession: URLSession = .shared,
        requestTimeout: TimeInterval = 30,
        makeControlSocket: (@Sendable (URL) -> any HomeBaseControlSocket)? = nil
    ) {
        self.endpoint = endpoint
        self.clientID = clientID
        self.urlSession = urlSession
        self.requestTimeout = requestTimeout
        self.makeControlSocket = makeControlSocket ?? { url in
            urlSession.webSocketTask(with: url, protocols: [Self.webSocketSubprotocol])
        }
    }

    deinit {
        let arbiter = liveStreamArbiter
        Task { await arbiter?.shutdown() }
        connectionAttempt?.cancel()
        reactivationAttempt?.cancel()
        pathRecoveryTask?.cancel()
        networkMonitor?.cancel()
        receiveTask?.cancel()
        acknowledgementTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
    }

    func makeHistoryTransport() -> CameraHistoryTransport {
        CameraHistoryTransport(endpoint: endpoint, clientID: clientID, session: urlSession)
    }

    /// Consumers survive transient control-connection losses. Each upstream
    /// attempt reactivates the main session and requests a fresh one-use ticket.
    func cameraStreamArbiter() -> CameraStreamArbiter {
        if let liveStreamArbiter { return liveStreamArbiter }
        let arbiter = CameraStreamArbiter { [weak self] camera, quality in
            guard let self else { throw CameraStreamError.closed }
            return try await self.openSharedCameraStream(camera, quality: quality)
        }
        liveStreamArbiter = arbiter
        if networkMonitor == nil {
            networkMonitor = CameraNetworkPathMonitor { [weak self] in
                Task { await self?.networkPathChanged() }
            }
        }
        return arbiter
    }

    private func networkPathChanged() {
        pathRecoveryTask?.cancel()
        pathRecoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, let arbiter = await self.liveStreamArbiter,
                  await arbiter.networkPathChanged(), !Task.isCancelled else { return }
            Self.logConnection("network path changed; checking active camera connection")
            try? await self.reactivate()
        }
    }

    private func openSharedCameraStream(_ camera: String, quality: CameraLiveQualitySelection) async throws -> CameraStreamUpstream {
        try Task.checkCancellation()
        try await reactivate()
        try Task.checkCancellation()
        let generation = connectionGeneration
        let lease = try await openCameraLiveStream(deviceIdentifier: camera, quality: quality)
        var connection: HomeBaseMediaConnection?
        do {
            try Task.checkCancellation()
            let media = try HomeBaseMediaConnection(host: lease.mediaHost, port: lease.opened.mediaPort)
            connection = media
            let frames = try media.frames(ticket: lease.opened.ticket)
            return CameraStreamUpstream(frames: frames, close: { [weak self] in
                media.cancel()
                await self?.releaseSharedCameraStream(lease.opened.streamID)
            }, connectionGeneration: generation)
        } catch {
            connection?.cancel()
            await releaseSharedCameraStream(lease.opened.streamID)
            throw error
        }
    }

    private func releaseSharedCameraStream(_ streamID: UUID) async {
        // Retirement is normally cancelled. Cleanup needs an independent,
        // bounded request lifetime; an absent acknowledgement must not occupy
        // an arbiter slot forever. The media socket has already been closed.
        let close = Task { try? await self.closeCameraLiveStream(streamID) }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            close.cancel()
        }
        await close.value
        timeout.cancel()
    }

    func connect() async throws {
        try Task.checkCancellation()
        if let connectionAttempt {
            try await connectionAttempt.value
            return
        }
        if sessionID != nil, task != nil {
            return
        }

        let attemptID = UUID()
        let attempt = Task { [weak self] in
            guard let self else {
                throw ClientError.notConnected
            }
            try await self.establishConnection()
        }
        connectionAttempt = attempt
        connectionAttemptID = attemptID
        defer {
            if connectionAttemptID == attemptID {
                connectionAttempt = nil; connectionAttemptID = nil
            }
        }
        try await attempt.value
        try Task.checkCancellation()
    }

    func reactivate() async throws {
        try Task.checkCancellation()
        if let reactivationAttempt {
            try await reactivationAttempt.value
            try Task.checkCancellation()
            return
        }
        let id = UUID()
        let attempt = Task { try await checkOrReconnect() }
        reactivationAttemptID = id
        reactivationAttempt = attempt
        defer {
            if reactivationAttemptID == id {
                reactivationAttempt = nil; reactivationAttemptID = nil
            }
        }
        try await attempt.value
        try Task.checkCancellation()
    }

    private func checkOrReconnect() async throws {
        if connectionAttempt != nil {
            try await connect()
            return
        }

        if let checkedTask = task, sessionID != nil {
            do {
                let request = try sessionRequest(
                    operation: HBProtocolOperations.ping
                )
                let response = try await sendRequest(request, using: checkedTask, timeout: min(8, requestTimeout))
                let body = try response.decodedPayload(
                    as: HBProtocolResponse.self
                )
                try body.validate()
                if let error = body.error {
                    throw error
                }
                guard body.status == .success else {
                    throw ClientError.invalidMessage(
                        "a connection check failed without an error"
                    )
                }
                Self.logConnection("existing session is active")
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if task === checkedTask {
                    failConnection(with: error)
                }
            }
        }

        try await connect()
    }

    func currentSessionIdentifier() async -> UUID? {
        sessionID
    }

    private func establishConnection() async throws {
        try Task.checkCancellation()
        if sessionID != nil, task != nil {
            return
        }
        guard task == nil else {
            throw ClientError.invalidMessage(
                "a WebSocket session is already being opened"
            )
        }
        guard let url = endpoint.webSocketURL else {
            throw ClientError.invalidEndpoint
        }

        if let sessionID,
           let resumeToken,
           let serverInstanceID {
            let task = startWebSocketTask(with: url)
            let generation = connectionGeneration
            do {
                try await resumeSession(
                    sessionID: sessionID,
                    resumeToken: resumeToken,
                    serverInstanceID: serverInstanceID,
                    using: task
                )
                try Task.checkCancellation()
                guard self.task === task else { throw ClientError.notConnected }
                try await cancelAbandonedSubscriptions()
                Self.logConnection("session resumed")
                return
            } catch is CancellationError {
                if connectionGeneration == generation {
                    failConnection(with: CancellationError(), preservingSession: false)
                }
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                guard connectionGeneration == generation else { throw error }
                guard shouldRebuildSession(after: error) else {
                    if self.task != nil {
                        failConnection(
                            with: error,
                            preservingSession: true
                        )
                    }
                    throw error
                }
                Self.logConnection(
                    "session resume was rejected; opening a fresh session"
                )
                failConnection(with: error, preservingSession: false)
            }
        } else if sessionID != nil {
            // A partial resume state is not usable. Rebuild from a clean
            // session rather than attaching new work to uncertain state.
            failConnection(
                with: ClientError.notConnected,
                preservingSession: false
            )
        }

        try Task.checkCancellation()
        let task = startWebSocketTask(with: url)
        let generation = connectionGeneration
        do {
            let request = HBProtocolEnvelope(
                messageKind: .request,
                clientID: clientID,
                operation: HBProtocolOperations.openSession
            )
            let response = try await sendRequest(request, using: task, timeout: min(15, requestTimeout))
            try Task.checkCancellation()
            guard self.task === task else { throw ClientError.notConnected }
            let body = try response.decodedPayload(
                as: HBProtocolResponse.self
            )
            let opened = try body.decodedResult(
                as: HBWebSocketSessionOpened.self
            )
            guard response.sessionID == opened.sessionID else {
                throw ClientError.invalidMessage(
                    "the opened session identifiers do not match"
                )
            }
            sessionID = opened.sessionID
            resumeToken = opened.resumeToken
            serverInstanceID = opened.serverInstanceID
            Self.logConnection("fresh session opened")
        } catch {
            if connectionGeneration == generation {
                failConnection(with: error, preservingSession: false)
            }
            throw error
        }
    }

    private func startWebSocketTask(
        with url: URL
    ) -> any HomeBaseControlSocket {
        let task = makeControlSocket(url)
        task.maximumMessageSize = 4 * 1_024 * 1_024
        connectionGeneration &+= 1
        self.task = task
        task.resume()
        startReceiveLoop(using: task)
        return task
    }

    private func resumeSession(
        sessionID: UUID,
        resumeToken: String,
        serverInstanceID: UUID,
        using task: any HomeBaseControlSocket
    ) async throws {
        // Every delivery at or below latestDeliverySequence has already been
        // decoded and applied locally. Advertising that processing checkpoint
        // prevents the replacement socket from replaying duplicate events.
        let processingCheckpoint = latestDeliverySequence
        let request = try HBProtocolEnvelope.request(
            operation: HBProtocolOperations.resumeSession,
            clientID: clientID,
            payload: HBWebSocketSessionResumeRequest(
                sessionID: sessionID,
                resumeToken: resumeToken,
                serverInstanceID: serverInstanceID,
                acknowledgedDeliverySequence: processingCheckpoint
            )
        )
        let response = try await sendRequest(request, using: task, timeout: min(15, requestTimeout))
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        let resumed = try body.decodedResult(
            as: HBWebSocketSessionResumed.self
        )
        guard response.sessionID == sessionID,
              resumed.sessionID == sessionID,
              resumed.serverInstanceID == serverInstanceID,
              resumed.latestDeliverySequence >= processingCheckpoint else {
            throw ClientError.invalidMessage(
                "the resumed session metadata does not match"
            )
        }
        acknowledgedDeliverySequence = processingCheckpoint
    }

    private func cancelAbandonedSubscriptions() async throws {
        for identifier in abandonedSubscriptions.sorted(
            by: { $0.uuidString < $1.uuidString }
        ) {
            guard abandonedSubscriptions.contains(identifier) else {
                continue
            }
            activeSubscriptions.insert(identifier)
            do {
                try await cancelSubscription(identifier)
            } catch let error as HBProtocolError
                where error.code == HBProtocolErrorCodes.notFound {
                finishSubscription(identifier)
            }
            abandonedSubscriptions.remove(identifier)
        }
    }

    func listTopology() async throws -> HBTopologyListResult {
        let request = try sessionRequest(
            operation: HBProtocolOperations.listTopology
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        return try body.decodedResult(as: HBTopologyListResult.self)
    }

    func listScenes() async throws -> [HBSceneDescriptor] {
        let request = try sessionRequest(
            operation: HBProtocolOperations.listScenes
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        return try body.decodedResult(as: HBSceneListResult.self).scenes
    }

    func listTriggers() async throws -> [HBTriggerSummaryDescriptor] {
        let request = try sessionRequest(
            operation: HBProtocolOperations.listTriggers
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        return try body.decodedResult(as: HBTriggerListResult.self).triggers
    }

    func triggerState(named name: String) async throws -> HBTriggerStateResult {
        let request = try sessionRequest(
            operation: HBProtocolOperations.getTriggerState,
            payload: HBTriggerRequest(name: name)
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        let result = try body.decodedResult(as: HBTriggerStateResult.self)
        guard result.trigger.name.caseInsensitiveCompare(name) == .orderedSame
        else {
            throw ClientError.invalidMessage(
                "a trigger state read returned a different trigger"
            )
        }
        return result
    }

    func listConfigurationFiles(
        at path: String? = nil
    ) async throws -> HBConfigurationFileListResult {
        let request = try sessionRequest(
            operation: HBProtocolOperations.listFiles,
            payload: HBConfigurationFileListRequest(path: path)
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        let result = try body.decodedResult(
            as: HBConfigurationFileListResult.self
        )
        let expectedPath = path ?? ""
        guard result.path == expectedPath else {
            throw ClientError.invalidMessage(
                "configuration file listing returned a different path"
            )
        }
        return result
    }

    func configurationFile(
        at path: String
    ) async throws -> HBConfigurationFileGetResult {
        let request = try sessionRequest(
            operation: HBProtocolOperations.getFile,
            payload: HBConfigurationFileGetRequest(path: path)
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        let result = try body.decodedResult(
            as: HBConfigurationFileGetResult.self
        )
        guard result.path == path else {
            throw ClientError.invalidMessage(
                "configuration file read returned a different path"
            )
        }
        return result
    }

    func setConfigurationFile(
        at path: String,
        contents: String
    ) async throws -> HBConfigurationFileSetResult {
        let request = try sessionRequest(
            operation: HBProtocolOperations.setFile,
            payload: HBConfigurationFileSetRequest(
                path: path,
                contents: contents
            )
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        let result = try body.decodedResult(
            as: HBConfigurationFileSetResult.self
        )
        guard result.path == path,
              result.byteCount == contents.utf8.count else {
            throw ClientError.invalidMessage(
                "configuration file write acknowledgement did not match the request"
            )
        }
        return result
    }

    func renameConfigurationFile(
        from sourcePath: String,
        to destinationPath: String
    ) async throws -> HBConfigurationFileRenameResult {
        let request = try sessionRequest(
            operation: HBProtocolOperations.renameFile,
            payload: HBConfigurationFileRenameRequest(
                sourcePath: sourcePath,
                destinationPath: destinationPath
            )
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        let result = try body.decodedResult(
            as: HBConfigurationFileRenameResult.self
        )
        guard result.sourcePath == sourcePath,
              result.destinationPath == destinationPath else {
            throw ClientError.invalidMessage(
                "configuration file rename acknowledgement did not match the request"
            )
        }
        return result
    }

    func deleteConfigurationFile(
        at path: String
    ) async throws -> HBConfigurationFileDeleteResult {
        let request = try sessionRequest(
            operation: HBProtocolOperations.deleteFile,
            payload: HBConfigurationFileDeleteRequest(path: path)
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        let result = try body.decodedResult(
            as: HBConfigurationFileDeleteResult.self
        )
        guard result.path == path else {
            throw ClientError.invalidMessage(
                "configuration file delete acknowledgement did not match the request"
            )
        }
        return result
    }

    func subscribeToScenes() async throws -> SceneSubscription {
        let request = try sessionRequest(
            operation: HBProtocolOperations.streamScenes,
            payload: HBSceneWatchStreamRequest(heartbeatSeconds: 30)
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        let accepted = try body.decodedResult(
            as: HBSceneWatchStreamAccepted.self
        )
        if let envelopeSubscriptionID = response.subscriptionID,
           envelopeSubscriptionID != accepted.subscriptionID {
            throw ClientError.invalidMessage(
                "the accepted scene subscription identifiers do not match"
            )
        }

        let pair = AsyncThrowingStream<
            HBSceneWatchStreamEvent,
            Error
        >.makeStream()
        let subscriptionID = accepted.subscriptionID
        activeSubscriptions.insert(subscriptionID)
        sceneSubscriptionContinuations[subscriptionID] = pair.continuation
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.sceneSubscriptionConsumerTerminated(
                    subscriptionID
                )
            }
        }
        if let buffered = bufferedSceneSubscriptionEvents.removeValue(
            forKey: subscriptionID
        ) {
            for event in buffered {
                pair.continuation.yield(event)
            }
        }

        return SceneSubscription(
            identifier: subscriptionID,
            scenes: accepted.scenes,
            events: pair.stream
        )
    }

    func subscribeToTriggers(
        scope: HBTriggerWatchScope = .catalog,
        detail: HBTriggerWatchDetail = .summary,
        triggerNames: [String]? = nil
    ) async throws -> TriggerSubscription {
        let request = try sessionRequest(
            operation: HBProtocolOperations.streamTriggers,
            payload: HBTriggerWatchStreamRequest(
                scope: scope,
                detail: detail,
                triggers: triggerNames,
                heartbeatSeconds: 30
            )
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        let accepted = try body.decodedResult(
            as: HBTriggerWatchStreamAccepted.self
        )
        if let envelopeSubscriptionID = response.subscriptionID,
           envelopeSubscriptionID != accepted.subscriptionID {
            throw ClientError.invalidMessage(
                "the accepted trigger subscription identifiers do not match"
            )
        }
        guard accepted.scope == scope, accepted.detail == detail else {
            throw ClientError.invalidMessage(
                "the accepted trigger subscription changed its requested scope or detail"
            )
        }
        if scope == .triggers {
            let requestedNames = Set(
                (triggerNames ?? []).map { $0.lowercased() }
            )
            let acceptedNames = Set(
                accepted.triggers.map { $0.trigger.name.lowercased() }
            )
            guard !requestedNames.isEmpty,
                  acceptedNames == requestedNames else {
                throw ClientError.invalidMessage(
                    "the accepted trigger subscription changed its selected triggers"
                )
            }
        }

        let pair = AsyncThrowingStream<
            HBTriggerWatchStreamEvent,
            Error
        >.makeStream()
        let subscriptionID = accepted.subscriptionID
        activeSubscriptions.insert(subscriptionID)
        triggerSubscriptionContinuations[subscriptionID] = pair.continuation
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.triggerSubscriptionConsumerTerminated(
                    subscriptionID
                )
            }
        }
        if let buffered = bufferedTriggerSubscriptionEvents.removeValue(
            forKey: subscriptionID
        ) {
            for event in buffered {
                pair.continuation.yield(event)
            }
        }

        return TriggerSubscription(
            identifier: subscriptionID,
            triggers: accepted.triggers,
            events: pair.stream
        )
    }

    func setScene(
        named name: String,
        active: Bool,
        allowMatchedDismissal: Bool = false
    ) async throws -> HBSceneStateResult {
        let request = try sessionRequest(
            operation: active
                ? HBProtocolOperations.setScene
                : HBProtocolOperations.clearScene,
            payload: HBSceneRequest(
                name: name,
                allowMatchedDismissal:
                    !active && allowMatchedDismissal ? true : nil
            )
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        let result: HBSceneStateResult
        if active {
            result = try body.decodedResult(as: HBSceneStateResult.self)
        } else {
            result = try body.decodedResult(as: HBSceneClearResult.self).scene
        }
        guard result.name.caseInsensitiveCompare(name) == .orderedSame else {
            throw ClientError.invalidMessage(
                "a scene update returned a different scene"
            )
        }
        return result
    }

    func reloadScene(named name: String) async throws -> HBSceneReloadResult {
        let request = try sessionRequest(
            operation: HBProtocolOperations.reloadScene,
            payload: HBSceneReloadRequest(name: name)
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        let result = try body.decodedResult(as: HBSceneReloadResult.self)
        guard result.name.caseInsensitiveCompare(name) == .orderedSame else {
            throw ClientError.invalidMessage(
                "a scene reload returned a different scene"
            )
        }
        return result
    }

    func reloadTrigger(named name: String) async throws -> HBTriggerReloadResult {
        let request = try sessionRequest(
            operation: HBProtocolOperations.reloadTrigger,
            payload: HBTriggerReloadRequest(name: name)
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        let result = try body.decodedResult(as: HBTriggerReloadResult.self)
        guard result.name.caseInsensitiveCompare(name) == .orderedSame else {
            throw ClientError.invalidMessage(
                "a trigger reload returned a different trigger"
            )
        }
        return result
    }

    func controlValue(
        _ control: String,
        projection: HBControlStateProjection
    ) async throws -> HBControlGetResult {
        let request = try sessionRequest(
            operation: HBProtocolOperations.getControl,
            payload: HBControlGetRequest(
                control: control,
                projection: projection
            )
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        let result = try body.decodedResult(as: HBControlGetResult.self)
        guard result.projection == nil || result.projection == projection else {
            throw ClientError.invalidMessage(
                "a control read returned the wrong projection"
            )
        }
        return result
    }

    func setControl(
        _ control: String,
        to value: HBJSONValue,
        transitionSeconds: TimeInterval? = nil
    ) async throws {
        Self.logControlWrite(
            stage: "intent",
            control: control,
            value: value,
            transitionSeconds: transitionSeconds
        )

        do {
            let request = try sessionRequest(
                operation: HBProtocolOperations.setControl,
                payload: HBControlSetRequest(
                    control: control,
                    value: value,
                    transitionSeconds: transitionSeconds,
                    writeMode: .externalOverride
                )
            )
            let response = try await sendRequest(request)
            let body = try response.decodedPayload(
                as: HBProtocolResponse.self
            )
            try body.validate()
            if let error = body.error {
                throw error
            }
            guard body.status == .success else {
                throw ClientError.invalidMessage(
                    "a control update failed without an error"
                )
            }
            Self.logControlWriteSucceeded(control: control)
        } catch {
            Self.logControlWriteFailed(control: control, error: error)
            throw error
        }
    }

    func holdControl(
        _ control: String,
        at value: HBJSONValue,
        transitionSeconds: TimeInterval? = nil,
        priority: Int? = nil,
        lifetime: HBControlHoldLifetime? = nil
    ) async throws -> HBControlHoldResult {
        let request = try sessionRequest(
            operation: HBProtocolOperations.holdControl,
            payload: HBControlHoldRequest(
                control: control,
                value: value,
                transitionSeconds: transitionSeconds,
                priority: priority,
                lifetime: lifetime
            )
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        return try body.decodedResult(as: HBControlHoldResult.self)
    }

    func replaceControlHold(
        token: String,
        with value: HBJSONValue,
        transitionSeconds: TimeInterval? = nil
    ) async throws -> HBControlHoldReplaceResult {
        let request = try sessionRequest(
            operation: HBProtocolOperations.replaceControlHold,
            payload: HBControlHoldReplaceRequest(
                token: token,
                value: value,
                transitionSeconds: transitionSeconds
            )
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        let result = try body.decodedResult(
            as: HBControlHoldReplaceResult.self
        )
        guard result.token == token else {
            throw ClientError.invalidMessage(
                "a hold replacement returned a different token"
            )
        }
        return result
    }

    func releaseControlHold(token: String) async throws
        -> HBControlReleaseResult
    {
        let request = try sessionRequest(
            operation: HBProtocolOperations.releaseControl,
            payload: HBControlReleaseRequest(
                token: token,
                allClients: false
            )
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        return try body.decodedResult(as: HBControlReleaseResult.self)
    }

    func clearControlOverride(_ control: String) async throws {
        let request = try sessionRequest(
            operation: HBProtocolOperations.clearControlOverride,
            payload: HBControlOverrideClearRequest(control: control)
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        try body.validate()
        if let error = body.error {
            throw error
        }
        guard body.status == .success else {
            throw ClientError.invalidMessage(
                "an external-override clear failed without an error"
            )
        }
    }

    func deviceDetails(
        for device: HBTopologyDeviceDescriptor
    ) async throws -> HBDeviceDescriptor {
        try await deviceDetails(
            named: device.addressableName,
            projection: nil
        )
    }

    /// Snapshot plus sequenced metadata changes from this ordinary connection.
    /// Register before the snapshot request, then discard older buffered events
    /// so a racing advertisement cannot overwrite newer snapshot state.
    func deviceDetailsWithMetadata(for device: HBTopologyDeviceDescriptor) async throws -> DeviceMetadataSubscription {
        let id = UUID()
        let (events, continuation) = AsyncThrowingStream<[String: HBJSONValue], Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        metadataObservers[id] = MetadataObserver(identifiers: Set([device.identifier.lowercased(), device.addressableName.lowercased()]), continuation: continuation)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeMetadataObserver(id) } }
        do {
            let request = try sessionRequest(operation: HBProtocolOperations.listDevices,
                payload: HBDeviceListRequest(device: device.addressableName, includeValues: true))
            let response = try await sendRequest(request)
            let result = try response.decodedPayload(as: HBProtocolResponse.self).decodedResult(as: HBDeviceListResult.self)
            guard let details = result.devices.first, let sequence = response.deliverySequence,
                  var observer = metadataObservers[id],
                  observer.identifiers.contains(details.addressableName.lowercased()) || observer.identifiers.contains(details.identifier.lowercased()) else {
                throw ClientError.invalidMessage("device metadata snapshot returned a different device or session")
            }
            observer.state.install(details.metadata, at: sequence)
            metadataObservers[id] = observer
            try Task.checkCancellation()
            return DeviceMetadataSubscription(details: details, metadata: observer.state.metadata, events: events)
        } catch {
            metadataObservers.removeValue(forKey: id)?.continuation.finish(throwing: error)
            throw error
        }
    }

    private func removeMetadataObserver(_ id: UUID) { metadataObservers.removeValue(forKey: id) }

    func deviceDetails(
        named device: String,
        projection: HBControlStateProjection?
    ) async throws -> HBDeviceDescriptor {
        let result = try await listDevices(
            device: device,
            includeValues: true,
            projection: projection
        )
        guard let details = result.devices.first else {
            throw ClientError.invalidMessage(
                "device discovery returned no device"
            )
        }
        guard details.addressableName.caseInsensitiveCompare(device)
                == .orderedSame
                || details.identifier.caseInsensitiveCompare(device)
                    == .orderedSame else {
            throw ClientError.invalidMessage(
                "device discovery returned a different device"
            )
        }
        return details
    }

    func openCameraLiveStream(
        deviceIdentifier: String,
        quality: CameraLiveQualitySelection
    ) async throws -> CameraLiveLease {
        let request = try sessionRequest(
            operation: HBProtocolOperations.openCameraLiveStream,
            payload: HBCameraLiveOpenRequest(
                deviceIdentifier: deviceIdentifier,
                quality: quality.requestedQuality,
                isolatedQuality: true,
                cameraTime: true
            )
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        let opened = try body.decodedResult(
            as: HBCameraLiveOpenResult.self
        )
        guard quality.requestedQuality.map({ opened.requestedQuality == $0 }) ?? true,
              opened.mediaPort > 0,
              !opened.deviceIdentifier.isEmpty,
              !opened.ticket.isEmpty else {
            throw ClientError.invalidMessage(
                "the live-camera lease is incomplete"
            )
        }
        return CameraLiveLease(
            mediaHost: endpoint.host,
            opened: opened
        )
    }

    func closeCameraLiveStream(_ streamID: UUID) async throws {
        let request = try sessionRequest(
            operation: HBProtocolOperations.closeCameraLiveStream,
            payload: HBCameraLiveCloseRequest(streamID: streamID)
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        let result = try body.decodedResult(
            as: HBCameraLiveCloseResult.self
        )
        guard result.streamID == streamID else {
            throw ClientError.invalidMessage(
                "the closed live-camera stream identifier changed"
            )
        }
    }

    func listDevices(
        device: String? = nil,
        recursive: Bool = false,
        includeValues: Bool = false,
        projection: HBControlStateProjection? = nil
    ) async throws -> HBDeviceListResult {
        let request = try sessionRequest(
            operation: HBProtocolOperations.listDevices,
            payload: HBDeviceListRequest(
                device: device,
                recursive: recursive,
                includeValues: includeValues,
                projection: projection
            )
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        let result = try body.decodedResult(as: HBDeviceListResult.self)
        guard projection == nil
                || result.projection == nil
                || result.projection == projection else {
            throw ClientError.invalidMessage(
                "device discovery returned the wrong projection"
            )
        }
        return result
    }

    func controlHistory(
        for control: String,
        limit: Int = 50,
        cursor: String? = nil
    ) async throws -> HBControlHistoryResult {
        let request = try sessionRequest(
            operation: HBProtocolOperations.getControlHistory,
            payload: HBControlHistoryRequest(
                control: control,
                limit: limit,
                cursor: cursor
            )
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        let result = try body.decodedResult(as: HBControlHistoryResult.self)
        guard result.control.caseInsensitiveCompare(control) == .orderedSame
        else {
            throw ClientError.invalidMessage(
                "control history returned a different control"
            )
        }
        return result
    }

    func subscribeToControlStacks(
        for device: HBTopologyDeviceDescriptor,
        controlIdentifiers: [String]? = nil,
        includeCompatibility: Bool = false
    ) async throws -> ControlStackSubscription {
        let request = try sessionRequest(
            operation: HBProtocolOperations.streamControlStacks,
            payload: HBControlStackWatchStreamRequest(
                device: device.addressableName,
                controlIdentifiers: controlIdentifiers,
                includeCompatibility: includeCompatibility,
                heartbeatSeconds: 30
            )
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        let accepted = try body.decodedResult(
            as: HBControlStackWatchStreamAccepted.self
        )
        if let envelopeSubscriptionID = response.subscriptionID,
           envelopeSubscriptionID != accepted.subscriptionID {
            throw ClientError.invalidMessage(
                "the accepted control-stack subscription identifiers do not match"
            )
        }

        let pair = AsyncThrowingStream<
            HBControlStackWatchStreamEvent,
            Error
        >.makeStream()
        let subscriptionID = accepted.subscriptionID
        activeSubscriptions.insert(subscriptionID)
        controlStackSubscriptionContinuations[subscriptionID] =
            pair.continuation
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.controlStackSubscriptionConsumerTerminated(
                    subscriptionID
                )
            }
        }
        if let buffered = bufferedControlStackSubscriptionEvents.removeValue(
            forKey: subscriptionID
        ) {
            for event in buffered {
                pair.continuation.yield(event)
            }
        }

        return ControlStackSubscription(
            identifier: subscriptionID,
            controls: accepted.controls,
            events: pair.stream
        )
    }

    func subscribe(
        to device: HBTopologyDeviceDescriptor,
        includeCompatibility: Bool = false,
        projection: HBControlStateProjection = .observed
    ) async throws -> ControlSubscription {
        let request = try sessionRequest(
            operation: HBProtocolOperations.streamControls,
            payload: HBControlWatchStreamRequest(
                selectors: [
                    HBControlWatchSelector(
                        kind: .device,
                        target: device.identifier
                    )
                ],
                includeCompatibility: includeCompatibility,
                heartbeatSeconds: 30,
                projection: projection
            )
        )
        let response = try await sendRequest(request)
        let body = try response.decodedPayload(as: HBProtocolResponse.self)
        let accepted = try body.decodedResult(
            as: HBControlWatchStreamAccepted.self
        )
        if let envelopeSubscriptionID = response.subscriptionID,
           envelopeSubscriptionID != accepted.subscriptionID {
            throw ClientError.invalidMessage(
                "the accepted subscription identifiers do not match"
            )
        }

        let pair = AsyncThrowingStream<
            HBControlWatchStreamEvent,
            Error
        >.makeStream()
        let subscriptionID = accepted.subscriptionID
        activeSubscriptions.insert(subscriptionID)
        controlSubscriptionContinuations[subscriptionID] = pair.continuation
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.controlSubscriptionConsumerTerminated(
                    subscriptionID
                )
            }
        }
        if let buffered = bufferedControlSubscriptionEvents.removeValue(
            forKey: subscriptionID
        ) {
            for event in buffered {
                pair.continuation.yield(event)
            }
        }

        return ControlSubscription(
            identifier: subscriptionID,
            controls: accepted.controls,
            events: pair.stream
        )
    }

    func cancelSubscription(_ identifier: UUID) async throws {
        guard activeSubscriptions.remove(identifier) != nil else {
            finishSubscription(identifier)
            return
        }

        do {
            let request = try sessionRequest(
                operation: HBProtocolOperations.cancelSubscription,
                payload: HBSubscriptionCancelRequest(
                    subscriptionID: identifier
                )
            )
            let response = try await sendRequest(request)
            let body = try response.decodedPayload(
                as: HBProtocolResponse.self
            )
            let result = try body.decodedResult(
                as: HBSubscriptionCancelResult.self
            )
            guard result.subscriptionID == identifier else {
                throw ClientError.invalidMessage(
                    "the cancelled subscription identifier changed"
                )
            }
            finishSubscription(identifier)
        } catch {
            finishSubscription(identifier, throwing: error)
            throw error
        }
    }

    func disconnect() async {
        let arbiter = liveStreamArbiter
        liveStreamArbiter = nil
        networkMonitor?.cancel(); networkMonitor = nil
        pathRecoveryTask?.cancel(); pathRecoveryTask = nil
        reactivationAttempt?.cancel(); reactivationAttempt = nil; reactivationAttemptID = nil
        connectionAttempt?.cancel()
        connectionAttempt = nil; connectionAttemptID = nil
        failConnection(
            with: CancellationError(),
            preservingSession: false
        )
        await arbiter?.shutdown()
    }

    private func sessionRequest(
        operation: String
    ) throws -> HBProtocolEnvelope {
        guard let sessionID else {
            throw ClientError.notConnected
        }
        return HBProtocolEnvelope(
            messageKind: .request,
            clientID: clientID,
            operation: operation,
            sessionID: sessionID
        )
    }

    private func sessionRequest<Payload: Encodable>(
        operation: String,
        payload: Payload
    ) throws -> HBProtocolEnvelope {
        guard let sessionID else {
            throw ClientError.notConnected
        }
        var request = try HBProtocolEnvelope.request(
            operation: operation,
            clientID: clientID,
            payload: payload
        )
        request.sessionID = sessionID
        return request
    }

    private func sendRequest(
        _ request: HBProtocolEnvelope
    ) async throws -> HBProtocolEnvelope {
        guard let task else {
            throw ClientError.notConnected
        }
        return try await sendRequest(request, using: task)
    }

    private func sendRequest(
        _ request: HBProtocolEnvelope,
        using task: any HomeBaseControlSocket,
        timeout: TimeInterval? = nil
    ) async throws -> HBProtocolEnvelope {
        let encodedRequest = try encoder.encode(request)
        logEncodedControlWriteIfPresent(
            request,
            encodedRequest: encodedRequest
        )
        let message = URLSessionWebSocketTask.Message.string(
            String(decoding: encodedRequest, as: UTF8.self)
        )
        let requestID = request.requestID
        let deadline = timeout ?? requestTimeout
        let watchdog = Task { [weak self, weak task] in
            do { try await Task.sleep(for: .seconds(deadline)) } catch { return }
            guard let self, let task else { return }
            await self.requestTimedOut(requestID, using: task)
        }
        defer { watchdog.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard self.task === task else {
                    continuation.resume(throwing: ClientError.notConnected)
                    return
                }
                guard pendingResponses[requestID] == nil else {
                    continuation.resume(
                        throwing: ClientError.invalidMessage(
                            "a request identifier was reused"
                        )
                    )
                    return
                }
                pendingResponses[requestID] = continuation
                Task { [weak self, weak task] in
                    guard let self, let task else { return }
                    do {
                        try await task.send(message)
                    } catch {
                        await self.outboundSendFailed(
                            error,
                            requestID: requestID,
                            task: task
                        )
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelPendingResponse(requestID)
            }
        }
    }

    private func requestTimedOut(_ id: UUID, using checkedTask: any HomeBaseControlSocket) {
        guard task === checkedTask, pendingResponses[id] != nil else { return }
        Self.logConnection("control response deadline expired; replacing the connection")
        failConnection(with: URLError(.timedOut))
    }

    private func logEncodedControlWriteIfPresent(
        _ request: HBProtocolEnvelope,
        encodedRequest: Data
    ) {
        guard request.operation == HBProtocolOperations.setControl else {
            return
        }

        do {
            let roundTrippedEnvelope = try decoder.decode(
                HBProtocolEnvelope.self,
                from: encodedRequest
            )
            let payload = try roundTrippedEnvelope.decodedPayload(
                as: HBControlSetRequest.self
            )
            Self.logControlWrite(
                stage: "encoded-roundtrip",
                control: payload.control,
                value: payload.value,
                transitionSeconds: payload.transitionSeconds
            )
        } catch {
            Self.printControlWriteDiagnostic(
                "stage=encoded-roundtrip operation=control.set diagnosticDecode=failed"
            )
            Self.controlWriteLogger.error(
                "stage=encoded-roundtrip operation=control.set diagnosticDecode=failed"
            )
        }
    }

    private static func logControlWrite(
        stage: String,
        control: String,
        value: HBJSONValue,
        transitionSeconds: TimeInterval?
    ) {
        let valueDescription = diagnosticDescription(of: value)
        let transitionDescription = transitionSeconds.map {
            diagnosticDescription(of: $0)
        } ?? "nil"
        let message =
            "stage=\(stage) operation=control.set control=\(control) "
            + "value=\(valueDescription) "
            + "transitionSeconds=\(transitionDescription)"
        printControlWriteDiagnostic(message)
        controlWriteLogger.notice(
            "stage=\(stage, privacy: .public) operation=control.set control=\(control, privacy: .public) value=\(valueDescription, privacy: .public) transitionSeconds=\(transitionDescription, privacy: .public)"
        )
    }

    private static func logControlWriteSucceeded(control: String) {
        printControlWriteDiagnostic(
            "stage=response operation=control.set control=\(control) outcome=success"
        )
        controlWriteLogger.notice(
            "stage=response operation=control.set control=\(control, privacy: .public) outcome=success"
        )
    }

    private static func logControlWriteFailed(
        control: String,
        error: Error
    ) {
        if let protocolError = error as? HBProtocolError {
            printControlWriteDiagnostic(
                "stage=response operation=control.set control=\(control) "
                + "outcome=failure code=\(protocolError.code) "
                + "message=\(protocolError.message) "
                + "retryable=\(protocolError.retryable)"
            )
            controlWriteLogger.error(
                "stage=response operation=control.set control=\(control, privacy: .public) outcome=failure code=\(protocolError.code, privacy: .public) message=\(protocolError.message, privacy: .public) retryable=\(protocolError.retryable, privacy: .public)"
            )
            return
        }

        let errorType = String(reflecting: type(of: error))
        printControlWriteDiagnostic(
            "stage=response operation=control.set control=\(control) "
            + "outcome=failure errorType=\(errorType)"
        )
        controlWriteLogger.error(
            "stage=response operation=control.set control=\(control, privacy: .public) outcome=failure errorType=\(errorType, privacy: .public)"
        )
    }

    private static func printControlWriteDiagnostic(_ message: String) {
#if DEBUG
        print("[HomeBase ControlWrite] \(message)")
#endif
    }

    private static func diagnosticDescription(
        of value: HBJSONValue
    ) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let value):
            return "bool(\(value))"
        case .integer(let value):
            return "integer(\(value))"
        case .number(let value):
            return "number(\(diagnosticDescription(of: value)))"
        case .string:
            return "string"
        case .array(let values):
            return "array(count=\(values.count))"
        case .object(let values):
            return "object(count=\(values.count))"
        }
    }

    private static func diagnosticDescription(of value: Double) -> String {
        let fullPrecision = String(format: "%.17g", value)
        let bitPattern = String(value.bitPattern, radix: 16)
        return "\(fullPrecision),finite=\(value.isFinite),bits=0x\(bitPattern)"
    }

    private func outboundSendFailed(
        _ error: Error,
        requestID: UUID,
        task: any HomeBaseControlSocket
    ) {
        guard self.task === task else {
            pendingResponses.removeValue(forKey: requestID)?
                .resume(throwing: error)
            return
        }
        failConnection(with: error)
    }

    private func cancelPendingResponse(_ requestID: UUID) {
        pendingResponses.removeValue(forKey: requestID)?
            .resume(throwing: CancellationError())
    }

    private func startReceiveLoop(using task: any HomeBaseControlSocket) {
        receiveTask = Task { [weak self, weak task] in
            guard let self, let task else { return }
            await self.receiveMessages(using: task)
        }
    }

    private func receiveMessages(using task: any HomeBaseControlSocket) async {
        do {
            while self.task === task, !Task.isCancelled {
                let message = try await task.receive()
                try process(message, from: task)
            }
        } catch is CancellationError {
            return
        } catch {
            guard self.task === task else { return }
            failConnection(with: error)
        }
    }

    private func process(
        _ message: URLSessionWebSocketTask.Message,
        from task: any HomeBaseControlSocket
    ) throws {
        guard self.task === task else { return }

        let data: Data
        switch message {
        case .data(let value):
            data = value
        case .string(let value):
            data = Data(value.utf8)
        @unknown default:
            throw ClientError.invalidMessage(
                "unsupported WebSocket frame"
            )
        }

        let envelope = try decoder.decode(HBProtocolEnvelope.self, from: data)
        try envelope.validate()
        guard envelope.clientID == clientID else {
            throw ClientError.invalidMessage(
                "the client identifier changed"
            )
        }
        if let sessionID,
           envelope.operation != HBProtocolOperations.openSession,
           envelope.sessionID != sessionID {
            throw ClientError.invalidMessage(
                "the session identifier changed"
            )
        }
        if let sequence = envelope.deliverySequence {
            try receiveDelivery(sequence)
        }

        switch envelope.messageKind {
        case .response:
            if let continuation = pendingResponses.removeValue(
                forKey: envelope.requestID
            ) {
                continuation.resume(returning: envelope)
            } else {
                releaseAbandonedResource(from: envelope)
            }
        case .event:
            try processEvent(envelope)
        case .request:
            throw ClientError.invalidMessage(
                "the server sent a request envelope"
            )
        }
    }

    private func processEvent(_ envelope: HBProtocolEnvelope) throws {
        switch envelope.operation {
        case HBProtocolOperations.deviceMetadataChanged:
            let event = try envelope.decodedPayload(as: HBDeviceMetadataChanged.self)
            guard let sequence = envelope.deliverySequence else { throw ClientError.invalidMessage("unsequenced metadata event") }
            for id in Array(metadataObservers.keys) {
                guard var observer = metadataObservers[id], observer.identifiers.contains(event.deviceIdentifier.lowercased()) else { continue }
                if observer.state.apply(key: event.key, value: event.value, sequence: sequence) {
                    observer.continuation.yield(observer.state.metadata)
                }
                metadataObservers[id] = observer
            }
        case HBProtocolOperations.streamControls:
            let event = try envelope.decodedPayload(
                as: HBControlWatchStreamEvent.self
            )
            if let envelopeSubscriptionID = envelope.subscriptionID,
               envelopeSubscriptionID != event.subscriptionID {
                throw ClientError.invalidMessage(
                    "a streamed event changed subscription identifiers"
                )
            }
            guard try acceptSubscriptionEvent(
                identifier: event.subscriptionID,
                sequence: event.sequence
            ) else { return }

            if let continuation = controlSubscriptionContinuations[
                event.subscriptionID
            ] {
                continuation.yield(event)
            } else {
                var buffered = bufferedControlSubscriptionEvents[
                    event.subscriptionID,
                    default: []
                ]
                guard buffered.count
                        < Self.maximumBufferedSubscriptionEvents else {
                    throw ClientError.invalidMessage(
                        "too many subscription events arrived before acceptance"
                    )
                }
                buffered.append(event)
                bufferedControlSubscriptionEvents[event.subscriptionID] =
                    buffered
            }

        case HBProtocolOperations.streamScenes:
            let event = try envelope.decodedPayload(
                as: HBSceneWatchStreamEvent.self
            )
            if let envelopeSubscriptionID = envelope.subscriptionID,
               envelopeSubscriptionID != event.subscriptionID {
                throw ClientError.invalidMessage(
                    "a streamed scene event changed subscription identifiers"
                )
            }
            guard try acceptSubscriptionEvent(
                identifier: event.subscriptionID,
                sequence: event.sequence
            ) else { return }

            if let continuation = sceneSubscriptionContinuations[
                event.subscriptionID
            ] {
                continuation.yield(event)
            } else {
                var buffered = bufferedSceneSubscriptionEvents[
                    event.subscriptionID,
                    default: []
                ]
                guard buffered.count
                        < Self.maximumBufferedSubscriptionEvents else {
                    throw ClientError.invalidMessage(
                        "too many scene subscription events arrived before acceptance"
                    )
                }
                buffered.append(event)
                bufferedSceneSubscriptionEvents[event.subscriptionID] =
                    buffered
            }

        case HBProtocolOperations.streamTriggers:
            let event = try envelope.decodedPayload(
                as: HBTriggerWatchStreamEvent.self
            )
            if let envelopeSubscriptionID = envelope.subscriptionID,
               envelopeSubscriptionID != event.subscriptionID {
                throw ClientError.invalidMessage(
                    "a streamed trigger event changed subscription identifiers"
                )
            }
            guard try acceptSubscriptionEvent(
                identifier: event.subscriptionID,
                sequence: event.sequence
            ) else { return }

            if let continuation = triggerSubscriptionContinuations[
                event.subscriptionID
            ] {
                continuation.yield(event)
            } else {
                var buffered = bufferedTriggerSubscriptionEvents[
                    event.subscriptionID,
                    default: []
                ]
                guard buffered.count
                        < Self.maximumBufferedSubscriptionEvents else {
                    throw ClientError.invalidMessage(
                        "too many trigger subscription events arrived before acceptance"
                    )
                }
                buffered.append(event)
                bufferedTriggerSubscriptionEvents[event.subscriptionID] =
                    buffered
            }

        case HBProtocolOperations.streamControlStacks:
            let event = try envelope.decodedPayload(
                as: HBControlStackWatchStreamEvent.self
            )
            if let envelopeSubscriptionID = envelope.subscriptionID,
               envelopeSubscriptionID != event.subscriptionID {
                throw ClientError.invalidMessage(
                    "a streamed control-stack event changed subscription identifiers"
                )
            }
            guard try acceptSubscriptionEvent(
                identifier: event.subscriptionID,
                sequence: event.sequence
            ) else { return }

            if let continuation = controlStackSubscriptionContinuations[
                event.subscriptionID
            ] {
                continuation.yield(event)
            } else {
                var buffered = bufferedControlStackSubscriptionEvents[
                    event.subscriptionID,
                    default: []
                ]
                guard buffered.count
                        < Self.maximumBufferedSubscriptionEvents else {
                    throw ClientError.invalidMessage(
                        "too many control-stack events arrived before acceptance"
                    )
                }
                buffered.append(event)
                bufferedControlStackSubscriptionEvents[
                    event.subscriptionID
                ] = buffered
            }

        case HBProtocolOperations.subscriptionTerminated:
            let event = try envelope.decodedPayload(
                as: HBSubscriptionTerminatedEvent.self
            )
            activeSubscriptions.remove(event.subscriptionID)
            abandonedSubscriptions.remove(event.subscriptionID)
            finishSubscription(
                event.subscriptionID,
                throwing: ClientError.subscriptionEnded(event.reason)
            )

        case HBProtocolOperations.resyncSession:
            let event = try envelope.decodedPayload(
                as: HBWebSocketResyncRequiredEvent.self
            )
            throw ClientError.resynchronizationRequired(event.reason)

        default:
            break
        }
    }

    private func acceptSubscriptionEvent(
        identifier: UUID,
        sequence: Int64
    ) throws -> Bool {
        guard !abandonedSubscriptions.contains(identifier) else {
            return false
        }
        let expected = (subscriptionSequences[identifier] ?? 0) + 1
        guard sequence == expected else {
            throw ClientError.invalidMessage(
                "subscription \(identifier) expected event sequence \(expected), received \(sequence)"
            )
        }
        subscriptionSequences[identifier] = sequence
        return true
    }

    private func receiveDelivery(_ sequence: Int64) throws {
        let expected = latestDeliverySequence + 1
        guard sequence == expected else {
            throw ClientError.invalidDeliverySequence(
                expected: expected,
                received: sequence
            )
        }
        latestDeliverySequence = sequence
        scheduleAcknowledgement()
    }

    private func scheduleAcknowledgement() {
        guard acknowledgementTask == nil else { return }
        acknowledgementTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            await self?.flushAcknowledgements()
        }
    }

    private func flushAcknowledgements() async {
        defer {
            acknowledgementTask = nil
            if task != nil,
               acknowledgedDeliverySequence < latestDeliverySequence {
                scheduleAcknowledgement()
            }
        }

        while acknowledgedDeliverySequence < latestDeliverySequence {
            guard let sessionID else { return }
            let target = latestDeliverySequence
            do {
                var request = try HBProtocolEnvelope.request(
                    operation: HBProtocolOperations.acknowledgeSession,
                    clientID: clientID,
                    payload: HBWebSocketSessionAckRequest(
                        deliverySequence: target
                    )
                )
                request.sessionID = sessionID
                let response = try await sendRequest(request)
                let body = try response.decodedPayload(
                    as: HBProtocolResponse.self
                )
                let result = try body.decodedResult(
                    as: HBWebSocketSessionAckResult.self
                )
                guard result.acknowledgedDeliverySequence >= target,
                      result.acknowledgedDeliverySequence
                        <= latestDeliverySequence else {
                    throw ClientError.invalidMessage(
                        "the acknowledged delivery sequence is invalid"
                    )
                }
                acknowledgedDeliverySequence =
                    result.acknowledgedDeliverySequence
            } catch is CancellationError {
                return
            } catch {
                failConnection(with: error)
                return
            }
        }
    }

    private func controlSubscriptionConsumerTerminated(_ identifier: UUID) {
        controlSubscriptionContinuations.removeValue(forKey: identifier)
        guard activeSubscriptions.contains(identifier) else { return }
        Task { [weak self] in
            try? await self?.cancelSubscription(identifier)
        }
    }

    private func sceneSubscriptionConsumerTerminated(_ identifier: UUID) {
        sceneSubscriptionContinuations.removeValue(forKey: identifier)
        guard activeSubscriptions.contains(identifier) else { return }
        Task { [weak self] in
            try? await self?.cancelSubscription(identifier)
        }
    }

    private func triggerSubscriptionConsumerTerminated(_ identifier: UUID) {
        triggerSubscriptionContinuations.removeValue(forKey: identifier)
        guard activeSubscriptions.contains(identifier) else { return }
        Task { [weak self] in
            try? await self?.cancelSubscription(identifier)
        }
    }

    private func controlStackSubscriptionConsumerTerminated(
        _ identifier: UUID
    ) {
        controlStackSubscriptionContinuations.removeValue(forKey: identifier)
        guard activeSubscriptions.contains(identifier) else { return }
        Task { [weak self] in
            try? await self?.cancelSubscription(identifier)
        }
    }

    private func releaseAbandonedResource(
        from envelope: HBProtocolEnvelope
    ) {
        guard let body = try? envelope.decodedPayload(
            as: HBProtocolResponse.self
        ) else {
            return
        }

        let subscriptionID: UUID?
        switch envelope.operation {
        case HBProtocolOperations.openCameraLiveStream:
            // The player may disappear or be covered before its open request
            // completes. A late reply still owns a lease that needs closing.
            guard let opened = try? body.decodedResult(as: HBCameraLiveOpenResult.self) else { return }
            Task { [weak self] in
                try? await self?.closeCameraLiveStream(opened.streamID)
            }
            return
        case HBProtocolOperations.streamControls:
            subscriptionID = try? body.decodedResult(
                as: HBControlWatchStreamAccepted.self
            ).subscriptionID
        case HBProtocolOperations.streamScenes:
            subscriptionID = try? body.decodedResult(
                as: HBSceneWatchStreamAccepted.self
            ).subscriptionID
        case HBProtocolOperations.streamTriggers:
            subscriptionID = try? body.decodedResult(
                as: HBTriggerWatchStreamAccepted.self
            ).subscriptionID
        case HBProtocolOperations.streamControlStacks:
            subscriptionID = try? body.decodedResult(
                as: HBControlStackWatchStreamAccepted.self
            ).subscriptionID
        default:
            subscriptionID = nil
        }
        guard let subscriptionID else { return }

        activeSubscriptions.insert(subscriptionID)
        Task { [weak self] in
            try? await self?.cancelSubscription(subscriptionID)
        }
    }

    private func finishSubscription(
        _ identifier: UUID,
        throwing error: Error? = nil
    ) {
        let controlContinuation = controlSubscriptionContinuations.removeValue(
            forKey: identifier
        )
        let sceneContinuation = sceneSubscriptionContinuations.removeValue(
            forKey: identifier
        )
        let triggerContinuation =
            triggerSubscriptionContinuations.removeValue(
                forKey: identifier
            )
        let controlStackContinuation =
            controlStackSubscriptionContinuations.removeValue(
                forKey: identifier
            )
        if let error {
            controlContinuation?.finish(throwing: error)
            sceneContinuation?.finish(throwing: error)
            triggerContinuation?.finish(throwing: error)
            controlStackContinuation?.finish(throwing: error)
        } else {
            controlContinuation?.finish()
            sceneContinuation?.finish()
            triggerContinuation?.finish()
            controlStackContinuation?.finish()
        }
        bufferedControlSubscriptionEvents.removeValue(forKey: identifier)
        bufferedSceneSubscriptionEvents.removeValue(forKey: identifier)
        bufferedTriggerSubscriptionEvents.removeValue(forKey: identifier)
        bufferedControlStackSubscriptionEvents.removeValue(forKey: identifier)
        subscriptionSequences.removeValue(forKey: identifier)
    }

    private func failConnection(
        with error: Error,
        preservingSession requestedPreservation: Bool? = nil
    ) {
        let arbiter = liveStreamArbiter
        let generation = connectionGeneration
        Task { await arbiter?.connectionInterrupted(generation: generation) }
        let preserveSession = requestedPreservation
            ?? shouldPreserveSession(after: error)
        let hasResumeState = sessionID != nil
            && resumeToken != nil
            && serverInstanceID != nil
        let willPreserveSession = preserveSession && hasResumeState

        receiveTask?.cancel()
        receiveTask = nil
        acknowledgementTask?.cancel()
        acknowledgementTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil

        if willPreserveSession {
            abandonedSubscriptions.formUnion(activeSubscriptions)
        } else {
            sessionID = nil
            resumeToken = nil
            serverInstanceID = nil
            abandonedSubscriptions.removeAll()
            latestDeliverySequence = 0
            acknowledgedDeliverySequence = 0
        }

        let pending = pendingResponses.values
        let observers = metadataObservers.values
        metadataObservers.removeAll()
        for observer in observers { observer.continuation.finish(throwing: error) }
        pendingResponses.removeAll()
        for continuation in pending {
            continuation.resume(throwing: error)
        }

        let controlSubscriptions = controlSubscriptionContinuations.values
        let sceneSubscriptions = sceneSubscriptionContinuations.values
        let triggerSubscriptions = triggerSubscriptionContinuations.values
        let controlStackSubscriptions =
            controlStackSubscriptionContinuations.values
        controlSubscriptionContinuations.removeAll()
        sceneSubscriptionContinuations.removeAll()
        triggerSubscriptionContinuations.removeAll()
        controlStackSubscriptionContinuations.removeAll()
        activeSubscriptions.removeAll()
        bufferedControlSubscriptionEvents.removeAll()
        bufferedSceneSubscriptionEvents.removeAll()
        bufferedTriggerSubscriptionEvents.removeAll()
        bufferedControlStackSubscriptionEvents.removeAll()
        subscriptionSequences.removeAll()
        for continuation in controlSubscriptions {
            continuation.finish(throwing: error)
        }
        for continuation in sceneSubscriptions {
            continuation.finish(throwing: error)
        }
        for continuation in triggerSubscriptions {
            continuation.finish(throwing: error)
        }
        for continuation in controlStackSubscriptions {
            continuation.finish(throwing: error)
        }
    }

    private func shouldPreserveSession(after error: Error) -> Bool {
        if error is CancellationError {
            return false
        }
        if let error = error as? ClientError {
            switch error {
            case .invalidMessage,
                 .invalidDeliverySequence,
                 .resynchronizationRequired:
                return false
            case .invalidEndpoint,
                 .notConnected,
                 .subscriptionEnded:
                return true
            }
        }
        if let error = error as? HBProtocolError,
           error.code == HBProtocolErrorCodes.resyncRequired {
            return false
        }
        return true
    }

    private func shouldRebuildSession(after error: Error) -> Bool {
        if let error = error as? HBProtocolError {
            return error.code == HBProtocolErrorCodes.resyncRequired
                || !error.retryable
        }
        if let error = error as? ClientError {
            switch error {
            case .invalidMessage,
                 .invalidDeliverySequence,
                 .resynchronizationRequired:
                return true
            case .invalidEndpoint,
                 .notConnected,
                 .subscriptionEnded:
                return false
            }
        }
        return false
    }

    private static func logConnection(_ message: String) {
#if DEBUG
        print("[HomeBase Connection] \(message)")
#endif
        connectionLogger.notice("\(message, privacy: .public)")
    }
}
