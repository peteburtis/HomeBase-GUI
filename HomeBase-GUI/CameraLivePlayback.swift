import Combine
import CoreMedia
import Foundation
import HomeBaseProtocol

/// Use the per-camera playback advertisement, not the presence of an NVR
/// recording control (which need not imply readable history for this camera).
enum CameraPlaybackHistoryAvailability {
    static func metadata(in metadata: [String: HBJSONValue]) -> HBCameraPlaybackMetadata? {
        guard isAvailable(in: metadata), let value = metadata[HBDeviceMetadataKeys.cameraPlayback] else { return nil }
        return try? value.decoded(HBCameraPlaybackMetadata.self)
    }
    static func isAvailable(in metadata: [String: HBJSONValue]) -> Bool {
        guard let value = metadata[HBDeviceMetadataKeys.cameraPlayback],
              let history = try? value.decoded(HBCameraPlaybackMetadata.self) else { return false }
        return ((history.available && !history.stores.isEmpty) || history.s3Store?.playbackManifestVersion == 1)
            && history.provider == "hbnvr"
            && UUID(uuidString: history.cameraID) != nil
            && history.transport == "websocket" && history.endpoint == "sameAsControl"
            && history.subprotocol == "homebase.v2"
            && history.openOperation == HBProtocolOperations.openNVRMedia
            && history.mediaProtocolVersion == 1
    }
}

/// A screen-scoped compressed-video timeline. Collection begins with the first
/// decodable picture and continues in every mode until the screen closes.
struct CameraLivePlaybackTimeline {
    enum Mode: Equatable { case live, paused, playing }

    struct Entry {
        let time: TimeInterval
        let frame: HBMediaFrame
        let epoch: UInt64
    }

    enum Presentation {
        case unchanged
        case black
        case frames([HBMediaFrame], resetDecoder: Bool)
    }

    let maximumDuration: TimeInterval
    let maximumBytes: Int
    // Also bound bookkeeping for pathological streams with tiny access units.
    let maximumFrames: Int
    private(set) var mode: Mode = .live
    private(set) var head: TimeInterval?
    private(set) var position: TimeInterval?
    private(set) var entries: [Entry] = []
    private(set) var retainedBytes = 0
    private(set) var generation: UInt32?
    private(set) var sourceEpoch: UInt64 = 0
    private(set) var presentationEpoch: UInt64?
    var hasAvailableNVRHistory = false
    private let clock: () -> TimeInterval
    private var timeScale: Double = 90_000
    private var origin: UInt64?
    private var previousTimestamp: UInt64?
    private var epochOffset: TimeInterval = 0
    private var lastArrival: TimeInterval?
    private var presentedSequence: UInt64?
    private var needsDecoderReset = true
    private var showingBlack = false

    init(
        maximumDuration: TimeInterval = 5 * 60,
        maximumBytes: Int = 64 * 1024 * 1024,
        maximumFrames: Int = 30_000,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.maximumDuration = maximumDuration
        self.maximumBytes = maximumBytes
        self.maximumFrames = maximumFrames
        self.clock = clock
    }

    var tail: TimeInterval? { entries.first?.time }
    var lastFrameArrival: TimeInterval? { lastArrival }
    var canControlPlayback: Bool { head != nil }
    var isLive: Bool { mode == .live }
    var canSeekBackward: Bool {
        guard canControlPlayback else { return false }
        guard !hasAvailableNVRHistory, mode == .paused else { return true }
        guard let tail, let position else { return false }
        return position > tail
    }

    mutating func configure(generation: UInt32, timeScale: UInt32) {
        // A fresh lease may reuse generation/sequence values. Give it a local
        // epoch so its decoder configuration and old buffered pictures stay distinct.
        sourceEpoch &+= 1
        origin = nil
        previousTimestamp = nil
        resetPresentation()
        self.generation = generation
        self.timeScale = Double(max(1, timeScale))
    }

    mutating func reset() {
        goLive()
        discardBuffer()
        head = nil
        position = nil
        generation = nil
        origin = nil
        previousTimestamp = nil
        lastArrival = nil
        epochOffset = 0
    }

    /// Returns true if a backwards timestamp requires decoder resynchronization.
    @discardableResult
    mutating func receive(_ frame: HBMediaFrame) -> Bool {
        guard frame.type == .videoAccessUnit, frame.generation == generation else {
            return false
        }
        let discontinuity = previousTimestamp.map {
            frame.presentationTimestamp < $0
        } ?? false
        if discontinuity {
            sourceEpoch &+= 1
            origin = nil
        }
        previousTimestamp = frame.presentationTimestamp
        let arrival = clock()
        if origin == nil {
            epochOffset = head.map {
                $0 + max(1 / timeScale, arrival - (lastArrival ?? arrival))
            } ?? 0
        }
        let origin = origin ?? frame.presentationTimestamp
        self.origin = origin
        lastArrival = arrival
        let time = epochOffset + Double(frame.presentationTimestamp - origin) / timeScale
        head = time
        if isLive {
            position = time
        }
        // Each source epoch starts at a keyframe; never retain undecodable
        // dependent frames at initial connection or after a stream restart.
        if entries.last?.epoch != sourceEpoch && !frame.flags.contains(.keyFrame) {
            return discontinuity
        }
        entries.append(Entry(time: time, frame: frame, epoch: sourceEpoch))
        retainedBytes += frame.payload.count
        trim()
        return discontinuity
    }

    mutating func pause() {
        guard canControlPlayback || !isLive else { return }
        mode = .paused
        needsDecoderReset = true
    }

    mutating func play() {
        guard canControlPlayback, !isLive else { return }
        mode = .playing
        clampToBufferStart()
    }

    mutating func seek(by seconds: TimeInterval) {
        guard let head, seconds.isFinite else { return }
        // Forward at Live is already at the head, not a reason to create a
        // buffer or replace a perfectly good live picture with black.
        if isLive && seconds >= 0 { return }
        let requestedPosition = (position ?? head) + seconds
        if mode == .playing && seconds > 0 && requestedPosition >= head {
            goLive()
            return
        }
        if isLive { mode = .playing }
        position = min(head, requestedPosition)
        if !hasAvailableNVRHistory {
            // Before the first keyframe there is no pre-roll; begin at the current
            // head and wait for the first decodable frame, not 30s of black.
            position = max(position!, tail ?? head)
        }
        needsDecoderReset = true
    }

    @discardableResult
    mutating func advance(by seconds: TimeInterval) -> Bool {
        guard mode == .playing, let head, let position,
              seconds.isFinite, seconds >= 0 else { return false }
        self.position = min(head, position + seconds)
        clampToBufferStart()
        return seconds > 0 && self.position == head
    }

    private mutating func clampToBufferStart() {
        guard !hasAvailableNVRHistory, let tail, let position, position < tail else { return }
        self.position = tail
        needsDecoderReset = true
    }

    mutating func goLive() {
        mode = .live
        position = head
        resetPresentation()
    }

    /// A multi-camera clock owns this cursor. Do not independently clamp a pane
    /// to its own tail/head: missing footage must be black, not a different time.
    mutating func followGroup(position: Double?, paused: Bool, seeking: Bool) {
        mode = paused ? .paused : .playing
        self.position = position
        if seeking { resetPresentation() }
    }

    mutating func discardBuffer() {
        entries.removeAll(keepingCapacity: false)
        retainedBytes = 0
        resetPresentation()
    }

    /// Retain the newest complete GOP under OS pressure, and keep collecting.
    /// The normal duration/byte/frame limits continue to apply in Live mode too.
    mutating func trimForMemoryPressure() {
        guard let newestKeyframe = entries.lastIndex(where: { $0.frame.flags.contains(.keyFrame) }) else { return }
        retainedBytes -= entries[..<newestKeyframe].reduce(0) { $0 + $1.frame.payload.count }
        entries.removeFirst(newestKeyframe)
        resetPresentation()
    }

    private mutating func resetPresentation() {
        presentedSequence = nil
        presentationEpoch = nil
        needsDecoderReset = true
        showingBlack = false
    }

    mutating func presentation() -> Presentation {
        guard !isLive, let position else { return .unchanged }
        // Preserve the current picture while a buffer-only session waits for
        // its first keyframe. There is no older history to request or display.
        if !hasAvailableNVRHistory && entries.isEmpty { return .unchanged }
        guard let first = entries.first, position >= first.time,
              let target = entries.lastIndex(where: { $0.time <= position }) else {
            presentedSequence = nil
            needsDecoderReset = true
            if showingBlack { return .unchanged }
            showingBlack = true
            return .black
        }

        let previous = presentedSequence.flatMap { sequence in
            entries.firstIndex(where: { $0.frame.sequence == sequence && $0.epoch == presentationEpoch })
        }
        let targetEpoch = entries[target].epoch
        let reset = needsDecoderReset || previous == nil || previous! > target || presentationEpoch != targetEpoch
        let start: Int
        if reset {
            start = entries[...target].lastIndex(where: {
                $0.epoch == targetEpoch && $0.frame.flags.contains(.keyFrame)
            }) ?? 0
        } else {
            start = previous! + 1
        }
        needsDecoderReset = false
        showingBlack = false
        guard start <= target else { return .unchanged }
        presentedSequence = entries[target].frame.sequence
        presentationEpoch = targetEpoch
        return .frames(entries[start...target].map(\.frame), resetDecoder: reset)
    }

    private mutating func trim() {
        while let first = entries.first,
              retainedBytes > maximumBytes || entries.count > maximumFrames
                || (head ?? first.time) - first.time > maximumDuration {
            let nextKeyframe = entries.dropFirst().firstIndex(where: {
                $0.frame.flags.contains(.keyFrame)
            }) ?? entries.endIndex
            retainedBytes -= entries[..<nextKeyframe].reduce(0) {
                $0 + $1.frame.payload.count
            }
            entries.removeFirst(nextKeyframe)
        }
    }
}

/// Owns playback, not the camera connection. The latter continues feeding frames
/// in every viewing mode. It never writes media to disk.
@MainActor
final class CameraLivePlaybackController: ObservableObject {
    @Published private(set) var mode: CameraLivePlaybackTimeline.Mode = .live
    @Published private(set) var playbackSpeed: CameraPlaybackSpeed = .normal
    @Published private(set) var canControlPlayback = false
    @Published private(set) var canSeekBackward = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var historyState: CameraHistoryPlayback.State = .idle
    @Published private(set) var loadingHistoryDate: Date?
    @Published private(set) var historyNavigation: CameraHistoryNavigationState = .idle
    @Published private(set) var isUsingHistory = false
    let renderer = CameraH264Renderer()
    private(set) var timeline: CameraLivePlaybackTimeline
    let history: CameraHistoryPlayback
    private let clock: () -> TimeInterval
    private var ownerID: UUID?
    private var ticker: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?
    private var presentationID = UUID()
    private var lastTick: TimeInterval?
    private var configurations: [UInt64: HBMediaStreamConfiguration] = [:]
    private var rendererEpoch: UInt64?
    private var lastPrunedEpochs: (oldest: UInt64, source: UInt64)?
    private var isClosed = false
    private var isSuspended = false
    private var historyIdentity: String?
    private var historyCapability: HBCameraPlaybackMetadata?
    private var historyCredentials: CameraS3Credentials?
    private var historyGeneration = UUID()
    private var historyTransport: (any CameraHistoryFetching)?
    private var historyPreparation: Task<Void, Never>?
    private var historyPiece: UUID?
    private var historyIndex: Int?
    private var historyShowingBlack = false
    private(set) var externallyClocked = false
    /// A valid media-lease interruption also pauses the shared multi-camera clock.
    var streamDidStop: (() -> Void)?

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        timeline = CameraLivePlaybackTimeline(clock: clock)
        history = CameraHistoryPlayback(clock: clock)
        history.changed = { [weak self] in
            self?.publishState()
            self?.present()
        }
        history.resetPresentation = { [weak self] in self?.resetHistoryPresentation() }
    }

    var isLive: Bool { mode == .live }
    var isPaused: Bool { mode == .paused }

    func setPlaybackSpeed(_ speed: CameraPlaybackSpeed) {
        guard !isClosed, !isLive, speed != playbackSpeed else { return }
        updateClock() // Elapsed time belongs to the previous speed.
        followGroupSpeed(speed)
        lastTick = clock()
    }

    /// The shared clock owns speed and catch-up decisions for every pane.
    func followGroupSpeed(_ speed: CameraPlaybackSpeed) {
        guard playbackSpeed != speed else { return }
        playbackSpeed = speed
        history.setPlaybackSpeed(speed)
    }

    var playbackDate: Date? {
        if history.isActive, let position = history.position {
            return Date(timeIntervalSince1970: position)
        }
        if let offset = history.canonicalOffset, let position = timeline.position {
            return Date(timeIntervalSince1970: offset + position)
        }
        return nil
    }

    func setNVRHistoryAvailable(_ available: Bool) {
        timeline.hasAvailableNVRHistory = available
        publishState()
    }

    func positionForCameraSwitch(metadata: [String: HBJSONValue]) -> CameraSwitchPosition {
        updateClock()
        guard !isLive else { return .live }
        let source = CameraPlaybackHistoryAvailability.metadata(in: metadata)
        if let position = history.switchPosition(cameraID: source?.cameraID) { return position }
        if let date = playbackDate { return .canonical(date.timeIntervalSince1970, paused: isPaused) }
        guard let source,
              let position = timeline.position, let head = timeline.head else { return .live }
        let now = clock()
        let age = max(0, now - (timeline.lastFrameArrival ?? now))
        return .relative(cameraID: source.cameraID, offset: min(0, position - head) - age,
            capturedAt: now, paused: isPaused)
    }

    func applyCameraSwitch(_ position: CameraSwitchPosition) {
        switch position {
        case .live: break // A fresh camera session already starts Live.
        case .canonical(let time, let paused): seek(to: Date(timeIntervalSince1970: time), paused: paused)
        case .relative: assertionFailure("Resolve the source camera clock before switching sessions")
        }
    }

    func useGroupClock() {
        externallyClocked = true
        ticker?.cancel(); ticker = nil
        history.setGroupClock(true)
    }

    func useLocalClock() {
        externallyClocked = false
        history.setGroupClock(false)
        lastTick = clock()
        if mode == .playing { startTicker() }
    }

    func followGroupBuffer(position: Double?, paused: Bool, seeking: Bool) {
        guard !isClosed else { return }
        if position == nil, seeking || history.isActive || timeline.isLive {
            cancelPresentation(); renderer.reset()
        }
        if history.isActive { history.deactivate(); resetHistoryPresentation() }
        if seeking { cancelPresentation(); errorMessage = nil }
        timeline.followGroup(position: position, paused: paused, seeking: seeking)
        publishState(); present()
    }

    func followGroupHistory(time: Double, liveEdge: Double?, paused: Bool, seeking: Bool) {
        guard !isClosed else { return }
        if seeking || !history.isActive {
            cancelTasks(); timeline.goLive(); errorMessage = nil
            history.enterGroup(time: time, liveEdge: liveEdge, localHead: timeline.head ?? 0, paused: paused)
        } else {
            history.followGroup(time: time, liveEdge: liveEdge, paused: paused)
        }
        publishState(); present()
    }

    /// Called on screen entry and capability changes, before any rewind gesture.
    func prepareHistory(metadata: [String: HBJSONValue], client: HomeBaseWebSocketClient,
                        credentials: CameraS3Credentials? = nil) {
        guard !isClosed, !isSuspended else { return }
        let capability = CameraPlaybackHistoryAvailability.metadata(in: metadata)
        setNVRHistoryAvailable(capability != nil)
        guard let capability else { return }
        let identity = capability.nvrInstanceID + "/" + capability.cameraID
        guard identity != historyIdentity || capability != historyCapability || credentials != historyCredentials
            || (historyTransport == nil && historyPreparation == nil) else { return }
        let replacing = identity == historyIdentity
        if !replacing { history.close(); resetHistoryPresentation() }
        historyIdentity = identity
        historyCapability = capability; historyCredentials = credentials
        let generation = UUID(); historyGeneration = generation
        historyPreparation?.cancel()
        // Stop the previous authenticated reader before publishing a replacement.
        history.disconnect(); historyTransport = nil
        historyPreparation = Task { [weak self] in
            let transport = await CameraHistorySources.make(metadata: capability, client: client, credentials: credentials)
            guard let self, !self.isClosed, !Task.isCancelled, self.historyGeneration == generation else {
                await transport.close(); return
            }
            self.historyTransport = transport
            if replacing { self.history.replaceSource(cameraID: capability.cameraID, transport: transport) }
            else { self.history.configure(cameraID: capability.cameraID, transport: transport) }
            self.publishState()
            if self.mode == .playing {
                self.lastTick = self.clock()
                self.startTicker(); self.present()
            }
            await transport.start()
            self.historyPreparation = nil
        }
    }

    func retryHistory() { history.retry() }

    func seekToAdjacentRecording(previous: Bool) {
        guard let date = history.adjacentRecording(previous: previous) else { return }
        seek(to: date)
    }

    /// Freeze the existing playback cursor, without ever turning Live into Pause.
    /// This is deliberately idempotent; lease cleanup and scene suspension can
    /// both arrive for the same interruption.
    func pauseForInterruption() {
        guard !isClosed, !isLive else { return }
        cancelTasks()
        if history.isActive { history.pause() }
        else { timeline.pause() }
        resetHistoryPresentation()
        renderer.reset(removingDisplayedImage: false)
        lastTick = nil
        publishState()
    }

    func suspend() {
        isSuspended = true
        pauseForInterruption()
        historyPreparation?.cancel(); historyPreparation = nil
        history.disconnect(); historyTransport = nil
        historyCredentials = nil
        cancelTasks()
    }

    /// An authentication lock is stronger than a transient scene interruption.
    /// Preserve only the paused cursor, never decrypted cloud samples or keys.
    func revokeCameraAccess() {
        suspend()
        timeline.discardBuffer()
        history.trimForMemoryPressure()
        renderer.reset()
        publishState()
    }

    /// Reconnect collection separately from playback. Non-live playback stays
    /// paused until an explicit Play or Live action.
    func resume() {
        guard !isClosed, isSuspended else { return }
        isSuspended = false
        lastTick = clock()
        present()
    }

    func configure(
        _ configuration: HBMediaStreamConfiguration,
        ownerID: UUID,
        preservingDisplayedImage: Bool = false
    ) throws -> CMVideoFormatDescription {
        guard !isClosed else { throw CancellationError() }
        if !history.isActive { cancelTasks() }
        let description = try renderer.configure(configuration, removingDisplayedImage: !isPaused && !preservingDisplayedImage,
                                                  updateRenderer: !history.isActive)
        self.ownerID = ownerID
        timeline.configure(
            generation: configuration.generation,
            timeScale: configuration.timeScale
        )
        configurations[timeline.sourceEpoch] = configuration
        if !history.isActive { rendererEpoch = timeline.sourceEpoch }
        pruneConfigurations()
        errorMessage = nil
        publishState()
        if mode == .playing { startTicker() }
        return description
    }

    func receive(_ frame: HBMediaFrame, ownerID: UUID) throws -> CMSampleBuffer? {
        guard !isClosed, !isSuspended, self.ownerID == ownerID,
              frame.generation == timeline.generation else { return nil }
        guard CameraH264Renderer.isValidAVCCAccessUnit(frame.payload) else {
            throw CameraH264Renderer.RendererError.invalidAccessUnit
        }
        let previousEpoch = timeline.sourceEpoch
        if timeline.receive(frame) {
            configurations[timeline.sourceEpoch] = configurations[previousEpoch]
            if timeline.isLive && !history.isActive {
                cancelPresentation()
                renderer.reset()
            }
        }
        pruneConfigurations()
        history.updateLiveHead(timeline.head)
        publishState()
        // Only actual live samples can enter the explicit Photos recorder.
        guard timeline.isLive, !history.isActive else { return nil }
        try activateRenderer(for: timeline.sourceEpoch)
        return try renderer.enqueue(frame)
    }

    func togglePause() {
        guard canControlPlayback else { return }
        updateClock()
        if history.isActive {
            history.togglePause()
            if history.isPaused {
                ticker?.cancel(); ticker = nil
                resetHistoryPresentation()
                renderer.reset(removingDisplayedImage: false)
            } else {
                lastTick = clock()
                startTicker(); present()
            }
            publishState()
            return
        }
        if timeline.mode == .paused {
            timeline.play()
            lastTick = clock()
            startTicker()
            present()
        } else {
            timeline.pause()
            ticker?.cancel()
            ticker = nil
            cancelPresentation()
            renderer.reset(removingDisplayedImage: false)
        }
        publishState()
    }

    func seek(by seconds: TimeInterval) {
        guard canControlPlayback, seconds.isFinite else { return }
        if isLive && seconds >= 0 { return }
        updateClock()
        cancelPresentation()
        if history.isActive {
            history.updateLiveHead(timeline.head)
            if history.seek(by: seconds) { goLive(); return }
            lastTick = clock()
            if !history.isPaused { startTicker() }
            publishState(); present()
            return
        }
        timeline.seek(by: seconds)
        if timeline.isLive {
            goLive()
            return
        }
        if timeline.hasAvailableNVRHistory, historyTransport != nil || historyPreparation != nil,
           let position = timeline.position, let head = timeline.head,
           position < (timeline.tail ?? head) {
            let paused = timeline.mode == .paused
            timeline.goLive() // Collection stays live; history owns the visible cursor.
            history.enter(localPosition: position, localHead: head, paused: paused)
        }
        lastTick = clock()
        present()
        if mode == .playing || (!history.isActive && timeline.mode == .playing) { startTicker() }
        publishState()
    }

    /// A calendar seek always uses the NVR's absolute canonical timeline, even
    /// when the live stream has not started or the camera is currently offline.
    func seek(to date: Date, paused requestedPause: Bool? = nil) {
        let time = date.timeIntervalSince1970
        guard !isClosed, timeline.hasAvailableNVRHistory,
              time.isFinite, abs(time) < 1e11 - 60 else { return }
        let paused = requestedPause ?? isPaused
        cancelTasks()
        timeline.goLive()
        errorMessage = nil
        history.enter(canonicalTime: time, localHead: timeline.head ?? 0, paused: paused)
        lastTick = clock()
        if !paused { startTicker() }
        publishState(); present()
    }

    func goLive() {
        cancelTasks()
        history.deactivate()
        followGroupSpeed(.normal)
        resetHistoryPresentation()
        timeline.goLive()
        errorMessage = nil
        // Reset only decoder state. Encoded history remains available, with its
        // own configuration, even if Live has changed quality or reconnected.
        do {
            if configurations[timeline.sourceEpoch] != nil {
                try activateRenderer(for: timeline.sourceEpoch)
            }
            renderer.reset()
        } catch { errorMessage = error.localizedDescription }
        publishState()
    }

    func dismissError() { errorMessage = nil }

    func stop(ownerID: UUID) {
        guard self.ownerID == ownerID else { return }
        pauseForInterruption()
        if !history.isActive {
            cancelTasks()
            renderer.reset(removingDisplayedImage: false)
        }
        self.ownerID = nil
        streamDidStop?()
        // Ending a lease (backgrounding, retry, quality change) is not closing
        // the screen. The next lease appends a distinct epoch to this history.
        publishState()
    }

    func close() {
        isClosed = true
        cancelTasks()
        historyPreparation?.cancel(); historyPreparation = nil
        history.close(); historyTransport = nil; historyCredentials = nil; historyCapability = nil
        followGroupSpeed(.normal)
        self.ownerID = nil
        timeline.reset()
        configurations.removeAll()
        lastPrunedEpochs = nil
        rendererEpoch = nil
        renderer.reset()
        publishState()
    }

    func trimBufferForMemoryPressure() {
        cancelPresentation()
        timeline.trimForMemoryPressure()
        history.trimForMemoryPressure()
        pruneConfigurations()
        if !isPaused { present() }
        publishState()
    }

    private func pruneConfigurations() {
        // Only rescan when an epoch starts or expires, not on every picture.
        // Discard configurations of failed leases that never supplied a GOP.
        let oldest = timeline.entries.first?.epoch ?? timeline.sourceEpoch
        guard lastPrunedEpochs?.oldest != oldest || lastPrunedEpochs?.source != timeline.sourceEpoch else { return }
        let retained = Set(timeline.entries.map(\.epoch)).union([timeline.sourceEpoch])
        configurations = configurations.filter { retained.contains($0.key) }
        lastPrunedEpochs = (oldest, timeline.sourceEpoch)
    }

    private func activateRenderer(for epoch: UInt64) throws {
        guard rendererEpoch != epoch else { return }
        guard let configuration = configurations[epoch] else { throw PlaybackError.missingConfiguration }
        _ = try renderer.configure(configuration)
        rendererEpoch = epoch
    }

    private func publishState() {
        let currentMode: CameraLivePlaybackTimeline.Mode = history.isActive ? (history.isPaused ? .paused : .playing) : timeline.mode
        if mode != currentMode { mode = currentMode }
        if isUsingHistory != history.isActive { isUsingHistory = history.isActive }
        if historyState != history.state { historyState = history.state }
        if loadingHistoryDate != history.loadingDate { loadingHistoryDate = history.loadingDate }
        if historyNavigation != history.navigation { historyNavigation = history.navigation }
        let controllable = timeline.canControlPlayback || history.isActive
        if canControlPlayback != controllable {
            canControlPlayback = controllable
        }
        let backward = history.isActive || timeline.canSeekBackward
        if canSeekBackward != backward {
            canSeekBackward = backward
        }
    }

    private func startTicker() {
        guard !isSuspended, !externallyClocked, ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
                guard let self else { return }
                self.tick()
            }
        }
    }

    func tick() {
        updateClock()
        present()
    }

    private func updateClock() {
        guard !isSuspended, !externallyClocked else { return }
        let now = clock()
        if let lastTick {
            let elapsed = max(0, now - lastTick) * playbackSpeed.multiplier
            let caughtUp = history.isActive
                ? history.advance(by: elapsed)
                : timeline.advance(by: elapsed)
            // Stay in buffered/history playback at the edge. Only the speed
            // changes; neither pause state nor the visible controls change.
            if caughtUp { followGroupSpeed(.normal) }
        }
        lastTick = now
    }

    private func present() {
        guard !isClosed, !isSuspended, presentationTask == nil else { return }
        if history.isActive { presentHistory(); return }
        switch timeline.presentation() {
        case .unchanged:
            break
        case .black:
            renderer.reset()
            if !externallyClocked, timeline.hasAvailableNVRHistory, historyTransport != nil,
               let position = timeline.position, let head = timeline.head {
                let paused = timeline.mode == .paused
                timeline.goLive()
                history.enter(localPosition: position, localHead: head, paused: paused)
            }
        case .frames(let frames, let resetDecoder):
            do {
                guard let epoch = timeline.presentationEpoch else { throw PlaybackError.missingConfiguration }
                try activateRenderer(for: epoch)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            if resetDecoder { renderer.reset() }
            let id = UUID()
            presentationID = id
            presentationTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for (index, frame) in frames.enumerated() {
                        try Task.checkCancellation()
                        // Keep decoder input bounded, including unusually long
                        // keyframe prerolls. Never block networking or the UI.
                        let deadline = ProcessInfo.processInfo.systemUptime + 2
                        while !self.renderer.isReadyForMoreMediaData {
                            guard ProcessInfo.processInfo.systemUptime < deadline else {
                                throw PlaybackError.decoderStalled
                            }
                            try await Task.sleep(for: .milliseconds(5))
                        }
                        try Task.checkCancellation()
                        try self.renderer.enqueue(frame, display: index == frames.count - 1)
                        if index % 16 == 15 { await Task.yield() }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard self.presentationID == id else { return }
                    self.errorMessage = error.localizedDescription
                    self.timeline.pause()
                    self.ticker?.cancel()
                    self.ticker = nil
                    self.renderer.reset()
                    self.publishState()
                }
                if self.presentationID == id { self.presentationTask = nil }
            }
        }
    }

    private func resetHistoryPresentation() {
        cancelPresentation()
        historyPiece = nil; historyIndex = nil; historyShowingBlack = false
    }

    private func presentHistory() {
        guard let location = history.location(preferredPiece: historyPiece) else {
            if !historyShowingBlack { renderer.reset(); historyShowingBlack = true }
            historyPiece = nil; historyIndex = nil
            return
        }
        let piece = location.piece, target = location.index
        let reset = historyPiece != piece.id || historyIndex == nil || historyIndex! > target
        let start = reset ? (piece.samples[...target].lastIndex(where: { $0.frame.keyFrame }) ?? 0) : historyIndex! + 1
        guard start <= target else { return }
        do {
            if reset { try renderer.configureHistory(piece.segment); rendererEpoch = nil }
        } catch { errorMessage = error.localizedDescription; return }
        historyPiece = piece.id; historyIndex = target; historyShowingBlack = false
        let samples = Array(piece.samples[start...target]), id = UUID()
        presentationID = id
        presentationTask = Task { [weak self] in
            guard let self else { return }
            do {
                for (index, sample) in samples.enumerated() {
                    try Task.checkCancellation()
                    let deadline = ProcessInfo.processInfo.systemUptime + 2
                    while !self.renderer.isReadyForMoreMediaData {
                        guard ProcessInfo.processInfo.systemUptime < deadline else { throw PlaybackError.decoderStalled }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    try Task.checkCancellation()
                    try self.renderer.enqueueHistory(sample, segment: piece.segment, display: index == samples.count - 1)
                    if index % 16 == 15 { await Task.yield() }
                }
            } catch is CancellationError { return }
            catch {
                guard self.presentationID == id else { return }
                self.errorMessage = error.localizedDescription
                if !self.history.isPaused { self.history.togglePause() }
                self.ticker?.cancel(); self.ticker = nil
                self.renderer.reset()
            }
            if self.presentationID == id { self.presentationTask = nil }
        }
    }

    private func cancelPresentation() {
        presentationID = UUID()
        presentationTask?.cancel()
        presentationTask = nil
    }

    private func cancelTasks() {
        ticker?.cancel()
        ticker = nil
        cancelPresentation()
        lastTick = nil
    }

    private enum PlaybackError: LocalizedError {
        case decoderStalled
        case missingConfiguration
        var errorDescription: String? {
            "Buffered playback could not resume. Try seeking again or returning to Live."
        }
    }
}
