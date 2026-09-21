import Combine
import Foundation
import HomeBaseProtocol

/// Selection order is also the control-display order. Never an empty group.
struct CameraMultipleSelection {
    private(set) var ids: [String]
    init(first: String) { ids = [first] }
    func canToggle(_ id: String) -> Bool { ids.contains(id) ? ids.count > 1 : ids.count < 4 }
    mutating func toggle(_ id: String) {
        guard canToggle(id) else { return }
        if ids.contains(id) { ids.removeAll { $0 == id } } else { ids.append(id) }
    }
}

@MainActor
final class CameraGroupSession: ObservableObject, Identifiable {
    let camera: CameraVideoDevice
    var id: String { camera.id }
    let playback = CameraLivePlaybackController()
    let controls: LiveDeviceControlsModel
    let gestures: CameraPaneGestures
    @Published var liveState: CameraLiveVideoModel.State = .idle
    private(set) var hostOrigin: Double?
    @Published var quality: HBCameraLiveQuality
#if os(iOS)
    let recordingController = CameraLocalRecordingController(destination: CameraPhotoLibraryRecordingDestination())
#endif
    var videoRecordingController: CameraLocalRecordingController? {
#if os(iOS)
        recordingController
#else
        nil
#endif
    }
    var historyAvailable: Bool { CameraPlaybackHistoryAvailability.isAvailable(in: controls.deviceMetadata) }

    init(camera: CameraVideoDevice, client: HomeBaseWebSocketClient, quality: HBCameraLiveQuality = .high) {
        self.camera = camera
        self.quality = quality
        let controls = LiveDeviceControlsModel(device: camera.device, client: client)
        self.controls = controls
        gestures = CameraPaneGestures(model: controls)
    }
    func captureHostOrigin() {
        guard hostOrigin == nil,
              let head = playback.timeline.head, let arrival = playback.timeline.lastFrameArrival else { return }
        hostOrigin = arrival - head
    }
    var hostHead: Double? { hostOrigin.flatMap { origin in playback.timeline.head.map { origin + $0 } } }
    var hostTail: Double? { hostOrigin.flatMap { origin in playback.timeline.tail.map { origin + $0 } } }
    func localTime(_ host: Double) -> Double? { hostOrigin.map { host - $0 } }
    func close() {
        gestures.update(enabled: false)
        playback.close()
        Task { await controls.stop() }
    }
}

/// Exactly one playback clock drives every pane. Individual readers can load at
/// different speeds, but they never independently advance their visible cursor.
@MainActor
final class CameraGroupPlayback: ObservableObject {
    enum Source: Equatable { case live, buffer, history }
    @Published private(set) var active = false
    // Picker selection style is independent of playback/layout. One selected
    // camera remains an ordinary single-camera player even with this enabled.
    @Published private(set) var multipleSelectionEnabled = true
    @Published private(set) var quality: HBCameraLiveQuality
    @Published private(set) var sessions: [CameraGroupSession] = []
    @Published private(set) var source: Source = .live
    @Published private(set) var isPaused = false
    @Published private(set) var playbackSpeed: CameraPlaybackSpeed = .normal
    @Published private(set) var allPanesShowVideo = false
    @Published private(set) var canControlPlayback = false
    @Published private(set) var canSeekBackward = false
    @Published private(set) var resolvingTime = false
    @Published var error: String?
    private(set) var cursor: Double?
    private(set) var selection: CameraMultipleSelection?
    let client: HomeBaseWebSocketClient
    let sharedControls: LiveDeviceControlsModel
    private let clock: () -> Double
    private var tickTask: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?
    private var generation = UUID()
    private var lastTick: Double?
    private var edgeAnchor: (canonical: Double, host: Double)?
    private var subscriptions: [String: Set<AnyCancellable>] = [:]
    private var updatingControls = false
    private var isSuspended = false

    init(client: HomeBaseWebSocketClient, initialSession: CameraGroupSession? = nil,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.client = client; self.clock = clock
        quality = initialSession?.quality ?? .high
        sharedControls = LiveDeviceControlsModel(device: nil, client: client)
        sharedControls.installWriteRouting(value: { [weak self] value, control, _ in
            guard let self else { throw CancellationError() }
            try await self.writeShared(value, control: control)
        }, canonical: { _, _ in
            throw CameraGroupControlSnapshot.Failure(message: "PTZ gestures target individual cameras, not the group.")
        })
        if let initialSession {
            selection = CameraMultipleSelection(first: initialSession.id)
            sessions = [initialSession]
            observe(initialSession)
        }
    }

    var isLive: Bool { source == .live }
    var hasMultipleCameras: Bool { sessions.count > 1 }
    var hasHistory: Bool { sessions.contains { $0.historyAvailable } }
    var playbackDate: Date? { source == .history ? cursor.map(Date.init(timeIntervalSince1970:)) : nil }
    var liveEdge: Double? { edgeAnchor.map { $0.canonical + max(0, clock() - $0.host) } }

    var availableQualities: Set<HBCameraLiveQuality> {
        sessions.reduce(Set(HBCameraLiveQuality.allCases)) { result, session in
            result.intersection(CameraLiveVideoCapability(metadata: session.controls.deviceMetadata)?.qualities ?? session.camera.capability.qualities)
        }
    }

    func setQuality(_ value: HBCameraLiveQuality) {
        guard value != quality else { return }
        guard availableQualities.contains(value) else {
            error = "This video quality is not supported by every selected camera."
            return
        }
        quality = value
        sessions.forEach { $0.quality = value }
    }

    func setPlaybackSpeed(_ speed: CameraPlaybackSpeed) {
        guard active, !isLive, !resolvingTime, speed != playbackSpeed else { return }
        tick() // Account for elapsed time at the old rate before changing it.
        applyPlaybackSpeed(speed)
    }

    private func applyPlaybackSpeed(_ speed: CameraPlaybackSpeed) {
        if playbackSpeed != speed { playbackSpeed = speed }
        sessions.forEach { $0.playback.followGroupSpeed(speed) }
    }

    func activate(camera: CameraVideoDevice, position: CameraSwitchPosition) {
        deactivate()
        selection = CameraMultipleSelection(first: camera.id)
        sessions = [makeSession(camera)]
        sessions[0].playback.useGroupClock()
        active = true
        if case .canonical(let time, let paused) = position {
            source = .history; cursor = time; isPaused = paused
        }
        drive(seeking: true); refreshControls(); resume()
    }

    func beginCameraSelection() {
        multipleSelectionEnabled = true
    }

    func setMultipleSelection(_ enabled: Bool) {
        guard !resolvingTime else { return }
        multipleSelectionEnabled = enabled
        if !enabled { setMultiple(false) }
    }

    /// Transfer clock ownership without replacing the surviving session,
    /// renderer, stream view, buffers, or history request. Merely enabling
    /// multiple selection does not require a shared playback clock.
    func setMultiple(_ enabled: Bool) {
        guard enabled != active, let first = sessions.first, !resolvingTime else { return }
        if enabled {
            first.captureHostOrigin()
            let playback = first.playback
            isPaused = playback.isPaused
            playbackSpeed = playback.playbackSpeed
            if playback.isUsingHistory {
                source = .history; cursor = playback.history.position
            } else if !playback.isLive {
                source = .buffer
                cursor = playback.timeline.position.flatMap { position in first.hostOrigin.map { $0 + position } }
            } else { source = .live; cursor = nil }
            playback.useGroupClock()
            active = true
            refreshControls(); refreshPresentation(); resume()
        } else {
            tickTask?.cancel(); tickTask = nil
            cancelResolution()
            for session in sessions.dropFirst() {
                subscriptions[session.id] = nil
                session.close()
            }
            sessions = [first]
            selection = CameraMultipleSelection(first: first.id)
            active = false
            first.playback.followGroupSpeed(playbackSpeed)
            if source == .history, !first.historyAvailable { first.playback.goLive() }
            first.playback.useLocalClock()
            source = .live; cursor = nil; edgeAnchor = nil; error = nil
            refreshControls()
        }
    }

    func canToggle(_ camera: CameraVideoDevice) -> Bool { selection?.canToggle(camera.id) == true && !resolvingTime }
    func toggle(_ camera: CameraVideoDevice) {
        guard canToggle(camera) else { return }
        if !sessions.contains(where: { $0.id == camera.id }), !camera.capability.qualities.contains(quality) {
            error = "\(camera.device.displayName) does not support \(quality.rawValue) quality. Select a supported quality before adding it."
            return
        }
        if !active { setMultiple(true) }
        selection?.toggle(camera.id)
        if let old = sessions.first(where: { $0.id == camera.id }) {
            sessions.removeAll { $0.id == camera.id }
            subscriptions[camera.id] = nil
            old.close()
        } else {
            let session = makeSession(camera)
            session.playback.useGroupClock()
            sessions.append(session)
            drive(session, seeking: true)
        }
        if hasMultipleCameras {
            refreshControls(); refreshPresentation()
        } else {
            // Removing either camera from a pair restores full single-camera
            // behavior, regardless of the picker's Multiple toggle.
            setMultiple(false)
        }
    }

    private func makeSession(_ camera: CameraVideoDevice) -> CameraGroupSession {
        let session = CameraGroupSession(camera: camera, client: client, quality: quality)
        observe(session)
        return session
    }

    private func observe(_ session: CameraGroupSession) {
        session.playback.streamDidStop = { [weak self, weak session] in
            guard let self, let session, self.sessions.contains(where: { $0 === session }) else { return }
            self.pauseForInterruption()
        }
        var observers: Set<AnyCancellable> = []
        // The toolbar follows whichever camera survives a layout change.
        session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observers)
        session.playback.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observers)
#if os(iOS)
        session.recordingController.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observers)
#endif
        session.controls.$controls.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshControls() }
        }.store(in: &observers)
        session.controls.$state.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshControls() }
        }.store(in: &observers)
        subscriptions[session.id] = observers
    }

    func togglePause() {
        guard canControlPlayback, !resolvingTime else { return }
        if isLive { source = .buffer; cursor = bufferHead ?? clock(); isPaused = true }
        else { isPaused.toggle() }
        lastTick = clock(); drive(seeking: true)
    }

    func seek(by seconds: Double) {
        guard canControlPlayback, !resolvingTime, seconds.isFinite else { return }
        if isLive {
            guard seconds < 0, let head = bufferHead else { return }
            source = .buffer; cursor = head
        }
        guard let cursor else { return }
        let edge = source == .history ? liveEdge : bufferHead
        let target = cursor + seconds
        if seconds > 0, let edge, target >= edge, !isPaused { goLive(); return }
        self.cursor = min(target, edge.map { $0 - 0.000_001 } ?? target)
        if source == .buffer {
            if needsArchive(at: self.cursor!), hasHistory { resolveHistory(at: self.cursor!); return }
            if !hasHistory, let tail = bufferTail { self.cursor = max(self.cursor!, tail) }
        }
        lastTick = clock(); drive(seeking: true)
    }

    func seek(to date: Date) {
        guard hasHistory else { return }
        cancelResolution()
        source = .history; cursor = date.timeIntervalSince1970
        lastTick = clock(); drive(seeking: true)
    }

    func jump(from session: CameraGroupSession, previous: Bool) {
        guard sessions.contains(where: { $0 === session }),
              let target = session.playback.history.adjacentRecording(previous: previous) else { return }
        seek(to: target)
    }

    func retry(_ session: CameraGroupSession) {
        guard sessions.contains(where: { $0 === session }) else { return }
        drive(session, seeking: true)
        if source == .history { session.playback.retryHistory() }
    }

    func goLive() {
        cancelResolution()
        source = .live; cursor = nil; isPaused = false
        sessions.forEach { $0.playback.goLive() }
        applyPlaybackSpeed(.normal)
        lastTick = clock(); refreshPresentation()
    }

    func positionForSwitch() -> CameraSwitchPosition {
        if isLive { return .live }
        guard let cursor else { return .live }
        if source == .history { return .canonical(cursor, paused: isPaused) }
        guard let session = sessions.first(where: { $0.historyAvailable }),
              let metadata = CameraPlaybackHistoryAvailability.metadata(in: session.controls.deviceMetadata) else { return .live }
        let now = clock()
        return .relative(cameraID: metadata.cameraID, offset: min(0, cursor - now), capturedAt: now, paused: isPaused)
    }

    private func resolveHistory(at hostTime: Double) {
        guard !resolvingTime, let session = sessions.first(where: { $0.historyAvailable }),
              let metadata = CameraPlaybackHistoryAvailability.metadata(in: session.controls.deviceMetadata) else { return }
        let id = UUID(); generation = id
        let now = clock(), paused = isPaused
        resolvingTime = true
        resolveTask = Task { [weak self] in
            guard let self else { return }
            let transport = await self.client.makeHistoryTransport()
            do {
                let position = CameraSwitchPosition.relative(cameraID: metadata.cameraID,
                    offset: min(0, hostTime - now), capturedAt: now, paused: paused)
                let resolved = try await position.resolve(using: transport)
                await transport.close()
                guard self.generation == id, !Task.isCancelled, self.active,
                      case .canonical(let time, _) = resolved else { return }
                self.edgeAnchor = (time + self.clock() - hostTime, self.clock())
                self.source = .history; self.cursor = time; self.resolvingTime = false
                self.lastTick = self.clock(); self.drive(seeking: true)
            } catch {
                await transport.close()
                guard self.generation == id, !Task.isCancelled else { return }
                self.resolvingTime = false; self.isPaused = true; self.error = error.localizedDescription
            }
        }
    }

    private var bufferHead: Double? {
        let playing = sessions.filter { $0.liveState.displaysVideo }.compactMap(\.hostHead)
        return playing.min() ?? sessions.compactMap(\.hostHead).max()
    }
    private var bufferTail: Double? { sessions.compactMap(\.hostTail).max() }
    private func needsArchive(at time: Double) -> Bool {
        sessions.contains { $0.historyAvailable && ($0.hostTail.map { time < $0 } ?? true) }
    }

    func tick() {
        guard active, !isSuspended else { return }
        let now = clock(), elapsed = max(0, now - (lastTick ?? now)); lastTick = now
        sessions.forEach { $0.captureHostOrigin() }
        // An initial relative history fetch may still be resolving when the
        // picker is toggled. Adopt its answer, rather than restarting it.
        if source == .history, cursor == nil { cursor = sessions.first?.playback.history.position }
        // A late-connecting, fresher camera can extend the shared edge. Never
        // feed the shared edge back into itself or let one old camera pin it.
        if source == .history,
           let edge = sessions.compactMap({ $0.playback.history.sourceLiveEdge }).max(),
           edge > (liveEdge ?? -.infinity) {
            edgeAnchor = (edge, now)
        }
        if !isLive, !isPaused, !resolvingTime, let cursor {
            var next = cursor + elapsed * playbackSpeed.multiplier
            let edge = source == .history ? liveEdge.map { $0 - 0.000_001 } : bufferHead
            if source == .history {
                if let edge = liveEdge { next = min(next, max(cursor, edge - 0.000_001)) }
                for session in sessions where session.historyAvailable {
                    let history = session.playback.history
                    if case .failed = history.state { continue }
                    let known = history.buffer.knownEnd(from: cursor, now: now, liveEdge: liveEdge ?? cursor + 60)
                    next = min(next, max(cursor, known))
                }
            } else if let head = bufferHead { next = min(next, max(cursor, head)) }
            self.cursor = next
            // A fetch/cache boundary is not the live edge. Only reaching the
            // shared edge resets speed; slower readers continue gating all panes.
            let tolerance = source == .history ? CameraPlaybackSpeed.historyEdgeTolerance : 0
            if elapsed > 0, next > cursor, let edge, next >= edge - tolerance { applyPlaybackSpeed(.normal) }
        }
        if source == .buffer, let cursor, needsArchive(at: cursor), !resolvingTime {
            resolveHistory(at: cursor)
        }
        drive(seeking: false)
    }

    private func drive(seeking: Bool) {
        sessions.forEach { drive($0, seeking: seeking) }
        refreshPresentation()
    }
    private func drive(_ session: CameraGroupSession, seeking: Bool) {
        session.playback.followGroupSpeed(playbackSpeed)
        switch source {
        case .live: break
        case .buffer:
            session.playback.followGroupBuffer(position: cursor.flatMap(session.localTime), paused: isPaused, seeking: seeking)
        case .history:
            guard let cursor else { return }
            if session.historyAvailable {
                session.playback.followGroupHistory(time: cursor, liveEdge: liveEdge, paused: isPaused, seeking: seeking)
            } else {
                session.playback.followGroupBuffer(position: nil, paused: isPaused, seeking: seeking)
            }
        }
    }

    func showsVideo(_ session: CameraGroupSession) -> Bool {
        if !active {
            return CameraPlaybackInteraction(liveState: session.liveState, usesHistory: session.playback.isUsingHistory,
                historyState: session.playback.historyState, playbackFailed: session.playback.errorMessage != nil).showsVideo
        }
        guard session.playback.errorMessage == nil, !resolvingTime else { return false }
        switch source {
        case .live: return session.liveState.displaysVideo
        case .history: return session.historyAvailable && session.playback.historyState == .ready
        case .buffer:
            guard let cursor, let tail = session.hostTail, let head = session.hostHead else { return false }
            return cursor >= tail && cursor <= head
        }
    }
    private func refreshPresentation() {
        let video = !sessions.isEmpty && sessions.allSatisfy(showsVideo)
        if allPanesShowVideo != video { allPanesShowVideo = video }
        let controllable = cursor != nil || sessions.contains { $0.playback.canControlPlayback }
        if canControlPlayback != controllable { canControlPlayback = controllable }
        let backward = controllable && (hasHistory || !isPaused || (cursor ?? 0) > (bufferTail ?? 0) + 0.000_001)
        if canSeekBackward != backward { canSeekBackward = backward }
    }

    func resume() {
        isSuspended = false
        sessions.forEach { $0.playback.resume() }
        guard active, tickTask == nil else { return }
        lastTick = clock()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                self?.tick()
            }
        }
    }
    func pauseForInterruption() {
        guard active, !isLive else { return }
        isPaused = true
        lastTick = clock()
        sessions.forEach { $0.playback.pauseForInterruption() }
        refreshPresentation()
    }

    func suspend() {
        isSuspended = true
        pauseForInterruption()
        tickTask?.cancel(); tickTask = nil
        cancelResolution()
        sessions.forEach { $0.gestures.update(enabled: false); $0.playback.suspend() }
    }
    private func cancelResolution() {
        generation = UUID(); resolveTask?.cancel(); resolveTask = nil; resolvingTime = false
    }
    func deactivate() {
        suspend(); sessions.forEach { $0.close() }; sessions = []; subscriptions = [:]
        selection = nil; active = false; source = .live; cursor = nil; isPaused = false
        playbackSpeed = .normal
        edgeAnchor = nil; error = nil
        sharedControls.installAggregatePresentation([])
    }

    func refreshControls() {
        guard !updatingControls else { return }
        updatingControls = true; defer { updatingControls = false }
        let snapshot = CameraGroupControlSnapshot(models: sessions.map(\.controls))
        objectWillChange.send()
        sharedControls.installAggregatePresentation(snapshot.controls)
    }

    private func writeShared(_ value: HBJSONValue, control: LiveDeviceControl) async throws {
        do {
            let snapshot = CameraGroupControlSnapshot(models: sessions.map(\.controls))
            try await CameraGroupControlSnapshot.perform(snapshot.writes(value: value, control: control))
        }
        catch { self.error = error.localizedDescription; throw error }
    }
}
