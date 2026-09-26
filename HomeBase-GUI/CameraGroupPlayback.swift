import Combine
import Foundation
import HomeBaseProtocol

/// Serializes the camera resources that belong to one selected camera.
///
/// SwiftUI views only render these resources.  Their appearance, disappearance,
/// geometry, and size-class changes must never start or stop network work.
/// The screen/group owner drives this coordinator for the actual lifecycle
/// events: authorization, backgrounding, camera removal, and dismissal.
@MainActor
final class CameraSessionResourceCoordinator {
    typealias StartLiveVideo = @MainActor (CameraAccessSession?) async -> Void
    typealias StopLiveVideo = @MainActor (Bool) async -> Void
    typealias StartControls = @MainActor () async -> Void
    typealias StopControls = @MainActor () async -> Void

    private let startLiveVideo: StartLiveVideo
    private let stopLiveVideo: StopLiveVideo
    private let startControls: StartControls
    private let stopControls: StopControls

    private(set) var isActive = false
    private var isClosed = false
    private var access: CameraAccessSession?
    private var liveRevision = 0
    private var controlsRevision = 0
    private var liveTask: Task<Void, Never>?
    private var controlsTask: Task<Void, Never>?

    init(
        startLiveVideo: @escaping StartLiveVideo,
        stopLiveVideo: @escaping StopLiveVideo,
        startControls: @escaping StartControls,
        stopControls: @escaping StopControls
    ) {
        self.startLiveVideo = startLiveVideo
        self.stopLiveVideo = stopLiveVideo
        self.startControls = startControls
        self.stopControls = stopControls
    }

    func setActive(
        _ active: Bool,
        access: CameraAccessSession?,
        stopImmediately: Bool = false
    ) {
        guard !isClosed else { return }
        let accessChanged = accessIdentity(self.access) != accessIdentity(access)
        guard active != isActive || (active && accessChanged) else { return }

        isActive = active
        self.access = active ? access : nil
        transitionLiveVideo(
            shouldRun: active,
            access: active ? access : nil,
            stopImmediately: stopImmediately
        )
        transitionControls(shouldRun: active)
    }

    func restartLiveVideo() {
        guard isActive, !isClosed else { return }
        transitionLiveVideo(
            shouldRun: true,
            access: access,
            stopImmediately: false
        )
    }

    func restartControls() {
        guard isActive, !isClosed else { return }
        transitionControls(shouldRun: true)
    }

    func close(stopImmediately: Bool = false) {
        guard !isClosed else { return }
        isClosed = true
        isActive = false
        access = nil
        transitionLiveVideo(
            shouldRun: false,
            access: nil,
            stopImmediately: stopImmediately
        )
        transitionControls(shouldRun: false)
    }

    /// Test/support hook that waits for finite transition closures. Production
    /// start closures remain alive while their subscriptions are active.
    func waitForTransitions() async {
        let liveTask = liveTask
        let controlsTask = controlsTask
        await liveTask?.value
        await controlsTask?.value
    }

    private func transitionLiveVideo(
        shouldRun: Bool,
        access: CameraAccessSession?,
        stopImmediately: Bool
    ) {
        liveRevision &+= 1
        let revision = liveRevision
        let previous = liveTask
        liveTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Tell the model how to release the current subscription before
            // cancellation lets run() enter its own cleanup path. In
            // particular, backgrounding and access revocation must bypass the
            // arbiter's ordinary handoff grace period.
            await self.stopLiveVideo(stopImmediately)
            previous?.cancel()
            await previous?.value
            guard !Task.isCancelled,
                  self.liveRevision == revision,
                  shouldRun,
                  self.isActive,
                  !self.isClosed,
                  self.accessIdentity(self.access) == self.accessIdentity(access)
            else { return }
            await self.startLiveVideo(access)
        }
    }

    private func transitionControls(shouldRun: Bool) {
        controlsRevision &+= 1
        let revision = controlsRevision
        let previous = controlsTask
        controlsTask = Task { @MainActor [weak self] in
            previous?.cancel()
            await previous?.value
            guard let self, self.controlsRevision == revision else { return }

            await self.stopControls()
            guard !Task.isCancelled,
                  self.controlsRevision == revision,
                  shouldRun,
                  self.isActive,
                  !self.isClosed
            else { return }
            await self.startControls()
        }
    }

    private func accessIdentity(_ access: CameraAccessSession?) -> ObjectIdentifier? {
        access.map(ObjectIdentifier.init)
    }
}

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
    let playback: CameraLivePlaybackController
    let controls: LiveDeviceControlsModel
    let liveVideo: CameraLiveVideoModel
    let gestures: CameraPaneGestures
    @Published var liveState: CameraLiveVideoModel.State = .idle
    private(set) var hostOrigin: Double?
    @Published private(set) var quality: CameraLiveQualitySelection
#if os(iOS)
    let recordingController: CameraLocalRecordingController
#endif
    let client: HomeBaseWebSocketClient
    private let resources: CameraSessionResourceCoordinator
    private var observations: Set<AnyCancellable> = []
    private var resourceAccess: CameraAccessSession?
    private var controlsRetryTask: Task<Void, Never>?
    private var qualityTask: Task<Void, Never>?
    private var qualityRevision = 0
    private var isClosed = false

    var historyAvailable: Bool { CameraPlaybackHistoryAvailability.isAvailable(in: controls.deviceMetadata) }

    init(camera: CameraVideoDevice, client: HomeBaseWebSocketClient, quality: CameraLiveQualitySelection? = nil) {
        self.camera = camera
        let initialQuality = quality ?? camera.capability.fullScreenQuality
        self.quality = initialQuality
        self.client = client
        let playback = CameraLivePlaybackController()
        self.playback = playback
        let controls = LiveDeviceControlsModel(device: camera.device, client: client)
        self.controls = controls
#if os(iOS)
        let recordingController = CameraLocalRecordingController(
            destination: CameraPhotoLibraryRecordingDestination()
        )
        self.recordingController = recordingController
        let liveVideo = CameraLiveVideoModel(
            deviceIdentifier: camera.device.addressableName,
            quality: initialQuality,
            client: client,
            recordingController: recordingController,
            playbackController: playback,
            artificialFeed: camera.artificialFeed
        )
#else
        let liveVideo = CameraLiveVideoModel(
            deviceIdentifier: camera.device.addressableName,
            quality: initialQuality,
            client: client,
            playbackController: playback,
            artificialFeed: camera.artificialFeed
        )
#endif
        self.liveVideo = liveVideo
        gestures = CameraPaneGestures(model: controls)
        resources = CameraSessionResourceCoordinator(
            startLiveVideo: { access in
                await liveVideo.run(access: access)
            },
            stopLiveVideo: { immediately in
                await liveVideo.stop(immediately: immediately)
            },
            startControls: {
                if camera.artificialFeed == nil {
                    await controls.run(reactivating: true)
                }
            },
            stopControls: {
                await controls.stop()
            }
        )

        liveVideo.$state
            .sink { [weak self] state in self?.liveState = state }
            .store(in: &observations)
        liveVideo.$aspectRatio
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observations)
        controls.$deviceMetadata
            .dropFirst()
            .sink { [weak self] metadata in
                self?.prepareHistory(metadata: metadata)
            }
            .store(in: &observations)
        controls.$state
            .dropFirst()
            .sink { [weak self] state in
                self?.scheduleControlsRetry(for: state)
            }
            .store(in: &observations)
    }

    var resourcesActive: Bool { resources.isActive }

    func setResourcesActive(
        _ active: Bool,
        access: CameraAccessSession?,
        stopImmediately: Bool = false
    ) {
        guard !isClosed else { return }
        resourceAccess = active ? access : nil
        resources.setActive(
            active,
            access: access,
            stopImmediately: stopImmediately
        )
        if active {
            prepareHistory(metadata: controls.deviceMetadata)
            scheduleControlsRetry(for: controls.state)
        } else {
            controlsRetryTask?.cancel()
            controlsRetryTask = nil
            gestures.update(enabled: false)
        }
    }

    /// Update history credentials without changing live/control resource
    /// lifetime. A credential result may arrive after the app backgrounds.
    func refreshHistoryAccess(_ access: CameraAccessSession?) {
        guard !isClosed, resourcesActive else { return }
        resourceAccess = access
        prepareHistory(metadata: controls.deviceMetadata)
    }

    func setQuality(_ quality: CameraLiveQualitySelection) {
        guard !isClosed, quality != self.quality else { return }
        self.quality = quality
        qualityRevision &+= 1
        let revision = qualityRevision
        let previous = qualityTask
        qualityTask = Task { @MainActor [weak self] in
            previous?.cancel()
            await previous?.value
            guard let self,
                  !Task.isCancelled,
                  !self.isClosed,
                  self.qualityRevision == revision
            else { return }
            await self.liveVideo.setQuality(quality)
        }
    }

    func restartLiveVideoIfNeeded() {
        guard resourcesActive, !liveVideo.state.displaysVideo else { return }
        resources.restartLiveVideo()
    }

    func captureHostOrigin() {
        guard hostOrigin == nil,
              let head = playback.timeline.head, let arrival = playback.timeline.lastFrameArrival else { return }
        hostOrigin = arrival - head
    }
    var hostHead: Double? { hostOrigin.flatMap { origin in playback.timeline.head.map { origin + $0 } } }
    var hostTail: Double? { hostOrigin.flatMap { origin in playback.timeline.tail.map { origin + $0 } } }
    func localTime(_ host: Double) -> Double? { hostOrigin.map { host - $0 } }
    func close(stopImmediately: Bool = false) {
        guard !isClosed else { return }
        isClosed = true
        controlsRetryTask?.cancel()
        controlsRetryTask = nil
        qualityTask?.cancel()
        qualityTask = nil
        gestures.update(enabled: false)
        playback.close()
        resources.close(stopImmediately: stopImmediately)
    }

    private func prepareHistory(metadata: [String: HBJSONValue]) {
        guard !isClosed, resourcesActive else { return }
        playback.prepareHistory(
            metadata: metadata,
            client: client,
            credentials: resourceAccess?.unlockedCredentials
        )
    }

    private func scheduleControlsRetry(for state: LiveDeviceControlsModel.State) {
        controlsRetryTask?.cancel()
        controlsRetryTask = nil
        guard !isClosed, resourcesActive, case .failed = state else { return }

        controlsRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard let self,
                  !self.isClosed,
                  self.resourcesActive,
                  case .failed = self.controls.state
            else { return }
            self.resources.restartControls()
        }
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
    @Published private(set) var quality: CameraLiveQualitySelection
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
    private var resourcesActive = false
    private var resourceAccess: CameraAccessSession?

    init(client: HomeBaseWebSocketClient, initialSession: CameraGroupSession? = nil,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.client = client; self.clock = clock
        quality = initialSession?.quality ?? .automatic
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
    var historySourceSession: CameraGroupSession? {
        sessions.first(where: \.historyAvailable)
    }
    var hasHistory: Bool { historySourceSession != nil }
    var playbackDate: Date? { source == .history ? cursor.map(Date.init(timeIntervalSince1970:)) : nil }
    var liveEdge: Double? { edgeAnchor.map { $0.canonical + max(0, clock() - $0.host) } }

    var availableConcreteQualities: Set<HBCameraLiveQuality> {
        sessions.reduce(Set(HBCameraLiveQuality.allCases)) { result, session in
            result.intersection(CameraLiveVideoCapability(metadata: session.controls.deviceMetadata)?.qualities ?? session.camera.capability.qualities)
        }
    }

    var supportsDefaultQuality: Bool {
        !sessions.isEmpty && sessions.allSatisfy { session in
            (CameraLiveVideoCapability(metadata: session.controls.deviceMetadata)
                ?? session.camera.capability).supportsDefaultQuality
        }
    }

    var availableQualities: Set<CameraLiveQualitySelection> {
        var result = Set(availableConcreteQualities.map(CameraLiveQualitySelection.init))
        if supportsDefaultQuality { result.insert(.automatic) }
        return result
    }

    func setQuality(_ value: CameraLiveQualitySelection) {
        // A focused pane can change its own quality without changing the group
        // preference. Reapplying that preference must still update that pane.
        guard value != quality || sessions.contains(where: { $0.quality != value }) else { return }
        guard availableQualities.contains(value) else {
            error = "This video quality is not supported by every selected camera."
            return
        }
        quality = value
        sessions.forEach { $0.setQuality(value) }
    }

    /// Resource lifetime is driven only by the stable full-screen owner.
    /// Layout, toolbar, and pane view changes never call these methods.
    func activateResources(access: CameraAccessSession?) {
        resourcesActive = true
        resourceAccess = access
        sessions.forEach {
            $0.setResourcesActive(true, access: access)
        }
    }

    func suspendResources(stopImmediately: Bool = false) {
        resourcesActive = false
        resourceAccess = nil
        sessions.forEach {
            $0.setResourcesActive(
                false,
                access: nil,
                stopImmediately: stopImmediately
            )
        }
    }

    /// Credential changes affect optional history reads only. In particular,
    /// they must never turn background-suspended camera resources back on.
    func refreshHistoryAccess(_ access: CameraAccessSession?) {
        guard resourcesActive else { return }
        resourceAccess = access
        sessions.forEach { $0.refreshHistoryAccess(access) }
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
        let shouldReactivateResources = resourcesActive
        let retainedAccess = resourceAccess
        deactivate()
        resourcesActive = shouldReactivateResources
        resourceAccess = retainedAccess
        quality = camera.capability.fullScreenQuality
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
        if !sessions.contains(where: { $0.id == camera.id }),
           !supports(quality, on: camera.capability) {
            error = "\(camera.device.displayName) does not support \(CameraLiveQualityPresentation.title(for: quality)) quality. Select a supported quality before adding it."
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

    private func supports(
        _ selection: CameraLiveQualitySelection,
        on capability: CameraLiveVideoCapability
    ) -> Bool {
        if let requestedQuality = selection.requestedQuality {
            return capability.qualities.contains(requestedQuality)
        }
        return capability.supportsDefaultQuality
    }

    private func makeSession(_ camera: CameraVideoDevice) -> CameraGroupSession {
        let session = CameraGroupSession(camera: camera, client: client, quality: quality)
        observe(session)
        if resourcesActive {
            session.setResourcesActive(true, access: resourceAccess)
        }
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

    func seek(to date: Date, paused requestedPause: Bool? = nil) {
        guard hasHistory else { return }
        cancelResolution()
        source = .history
        cursor = date.timeIntervalSince1970
        if let requestedPause { isPaused = requestedPause }
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
        guard let session = historySourceSession,
              let metadata = CameraPlaybackHistoryAvailability.metadata(in: session.controls.deviceMetadata) else { return .live }
        let now = clock()
        return .relative(cameraID: metadata.cameraID, offset: min(0, cursor - now), capturedAt: now, paused: isPaused)
    }

    private func resolveHistory(at hostTime: Double) {
        guard !resolvingTime, let session = historySourceSession,
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
        suspend()
        resourcesActive = false
        resourceAccess = nil
        sessions.forEach { $0.close() }
        sessions = []; subscriptions = [:]
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
