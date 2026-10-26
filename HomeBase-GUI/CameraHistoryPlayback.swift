import Foundation
import HomeBaseProtocol

@MainActor
final class CameraHistoryPlayback {
    // Lifecycle cleanup is explicit; SwiftUI can release this outside a Swift task.
    nonisolated deinit {}

    enum State: Equatable { case idle, loading, ready, gap, failed(String) }
    private(set) var buffer = CameraHistoryBuffer()
    private(set) var isActive = false
    private(set) var isPaused = false
    private(set) var position: Double?
    private(set) var state: State = .idle
    private(set) var canonicalOffset: Double?
    private(set) var fetching = false
    private(set) var navigation: CameraHistoryNavigationState = .idle
    private var navigationBounds: CameraHistoryRange?
    private var navigationExpires: Double = 0
    private var navigationRefresh: Task<Void, Never>?
    private var showsHiddenVideo = false
    private var bufferNavigation: (position: Double, head: Double)?
    var hasNavigationRegion: Bool {
        if !isActive { return bufferNavigation != nil }
        if state == .gap { return true }
        guard !showsHiddenVideo, let location = location(preferredPiece: nil) else { return false }
        return location.piece.samples[location.index].isHidden
    }

    private var navigationPosition: Double? {
        if isActive { return position }
        guard let bufferNavigation, let canonicalOffset else { return nil }
        return bufferNavigation.position + canonicalOffset
    }

    func setShowsHiddenVideo(_ value: Bool) {
        guard showsHiddenVideo != value else { return }
        showsHiddenVideo = value
        if value { bufferNavigation = nil }
        invalidateNavigation()
        ensureRequest(); changed?()
    }

    /// Live and buffered hidden pictures can offer archive navigation without
    /// changing their playback mode or moving the visible cursor.
    func updateBufferNavigation(position: Double?, head: Double?) {
        guard !isActive else { return }
        guard let position, let head, !showsHiddenVideo else {
            guard bufferNavigation != nil else { return }
            bufferNavigation = nil; invalidateNavigation(); changed?()
            return
        }
        let wasEmpty = bufferNavigation == nil
        bufferNavigation = (position, head)
        if wasEmpty { invalidateNavigation() }
        ensureRequest()
    }

    private func invalidateNavigation() {
        if navigation == .loading { cancelRequest() }
        else {
            navigationRefresh?.cancel(); navigationRefresh = nil
            navigation = .idle; navigationBounds = nil
        }
    }
    private var resolvedLoadingPosition: Double?
    var loadingDate: Date? {
        guard state == .loading, let target = position ?? resolvedLoadingPosition else { return nil }
        return Date(timeIntervalSince1970: target)
    }
    var changed: (() -> Void)?
    var resetPresentation: (() -> Void)?
    private var cameraID: String?
    private var transport: (any CameraHistoryFetching)?
    private var task: Task<Void, Never>?
    private var token = UUID()
    private var tagObserver: Task<Void, Never>?
    private let tagRefresh = CameraFootageRefreshTask()
    private var tagSerial: UInt64 = 0
    private var tagRegistrationPending = false
    private var tagGeneration = UUID()
    private var localHead: Double = 0
    private var initialOffset: Double = 0
    private var relativeCaptureTime: Double = 0
    private var goal: CameraHistoryRange?
    private var retryAfter: Double = 0
    private var failure: String?
    private var quickRetries = 0
    private let clock: () -> Double
    private var groupClock = false
    private var groupLiveEdge: Double?
    private(set) var playbackSpeed: CameraPlaybackSpeed = .normal

    init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }

    func configure(cameraID: String, transport: any CameraHistoryFetching) {
        self.cameraID = cameraID; self.transport = transport
        tagObserver?.cancel(); tagRefresh.cancel(); tagGeneration = UUID()
        tagRegistrationPending = transport is any CameraFootageTagRefreshing
        if let source = transport as? any CameraFootageTagRefreshing {
            let generation = tagGeneration
            tagObserver = Task { [weak self] in
                let stream = await source.tagChanges()
                guard let self, self.tagGeneration == generation, !Task.isCancelled else { return }
                self.tagRegistrationPending = false
                self.refreshFootageTags(using: source)
                self.ensureRequest()
                for await change in stream {
                    guard !Task.isCancelled, self.tagGeneration == generation else { return }
                    if CameraFootageTags.affects(change, cameraID: cameraID) {
                        self.tagSerial &+= 1
                        self.invalidateNavigation()
                        self.refreshFootageTags(using: source)
                    }
                }
            }
        } else { ensureRequest() }
    }
    private func refreshFootageTags(using source: any CameraFootageTagRefreshing) {
        let generation = tagGeneration
        tagRefresh.schedule { [weak self] revision in
            guard let self else { return }
            let batches = self.buffer.batches.map(\.batch)
            do {
                let refreshed = try await source.refreshTags(batches)
                guard self.tagRefresh.isCurrent(revision), self.tagGeneration == generation else { return }
                let current = self.location(preferredPiece: nil)
                let wasHidden = current.map { $0.piece.samples[$0.index].isHidden }
                for batch in refreshed { self.buffer.replaceTags(in: batch) }
                let updated = self.location(preferredPiece: nil)
                if wasHidden != updated.map({ $0.piece.samples[$0.index].isHidden }) {
                    // A hidden paused target may have been decoded with
                    // display:false. Replay its retained GOP after a clear;
                    // also supersede an in-flight presentation when hiding.
                    self.resetPresentation?()
                }
                self.invalidateNavigation(); self.refreshState(); self.ensureRequest(); self.changed?()
            } catch {
                guard self.tagRefresh.isCurrent(revision), self.tagGeneration == generation else { return }
                self.failure = error.localizedDescription
                self.refreshState(); self.changed?()
            }
        }
    }
    /// Credential repair can make previously confirmed LOCAL gaps readable.
    /// Keep the cursor/pause state, but invalidate that source's cached coverage.
    func replaceSource(cameraID: String, transport: any CameraHistoryFetching) {
        disconnect(); buffer.removeAll(); failure = nil; retryAfter = 0; quickRetries = 0
        configure(cameraID: cameraID, transport: transport)
        if let position, let liveEdge { goal = CameraHistoryPolicy.initialWindow(at: position, liveEdge: liveEdge) }
        resetPresentation?(); refreshState(); ensureRequest(); changed?()
    }
    var sourceLiveEdge: Double? { canonicalOffset.map { $0 + localHead } }
    var liveEdge: Double? { groupLiveEdge ?? sourceLiveEdge }
    func updateLiveHead(_ head: Double?) { if let head { localHead = head } }

    func setPlaybackSpeed(_ speed: CameraPlaybackSpeed) {
        guard playbackSpeed != speed else { return }
        playbackSpeed = speed
        ensureRequest()
    }

    func enter(localPosition: Double, localHead: Double, paused: Bool) {
        bufferNavigation = nil
        groupClock = false; groupLiveEdge = nil
        cancelRequest()
        isActive = true; isPaused = paused; self.localHead = localHead
        initialOffset = min(0, localPosition - localHead)
        relativeCaptureTime = clock()
        position = canonicalOffset.map { $0 + localPosition }
        goal = position.map { CameraHistoryPolicy.initialWindow(at: $0, liveEdge: liveEdge!) }
        failure = nil; retryAfter = 0; quickRetries = 0
        refreshState(); resetPresentation?(); ensureRequest(); changed?()
    }

    func enter(canonicalTime: Double, localHead: Double, paused: Bool, groupClock: Bool = false) {
        guard canonicalTime.isFinite, abs(canonicalTime) < 1e11 - 60 else { return }
        bufferNavigation = nil
        self.groupClock = groupClock
        if !groupClock { groupLiveEdge = nil }
        cancelRequest()
        isActive = true; isPaused = paused; self.localHead = localHead
        position = canonicalTime
        if let liveEdge {
            if !groupClock { position = min(canonicalTime, liveEdge - 0.000_001) }
            goal = CameraHistoryPolicy.initialWindow(at: position!, liveEdge: requestLiveEdge(liveEdge))
        } else {
            goal = nil
        }
        failure = nil; retryAfter = 0; quickRetries = 0
        refreshState(); resetPresentation?(); ensureRequest(); changed?()
    }

    func enterGroup(time: Double, liveEdge: Double?, localHead: Double, paused: Bool) {
        groupLiveEdge = liveEdge
        enter(canonicalTime: time, localHead: localHead, paused: paused, groupClock: true)
    }

    /// Changing the clock owner does not cancel a fetch or discard its cache.
    func setGroupClock(_ enabled: Bool) {
        groupClock = enabled
        if !enabled { groupLiveEdge = nil }
    }

    func followGroup(time: Double, liveEdge: Double?, paused: Bool) {
        guard isActive, groupClock else { return }
        position = time; groupLiveEdge = liveEdge; isPaused = paused
        refreshState(); ensureRequest(); changed?()
    }

    /// A stopped/lagging camera's anchor cannot move a shared absolute seek to
    /// an earlier recording. Query the requested instant and report a gap there.
    private func requestLiveEdge(_ edge: Double) -> Double {
        groupClock ? max(edge, (position ?? edge) + 0.001) : edge
    }

    /// Returns true only for a playing forward seek at/past the live edge.
    @discardableResult
    func seek(by seconds: Double) -> Bool {
        guard isActive, seconds.isFinite else { return false }
        if let position, let liveEdge {
            if !isPaused && seconds > 0 && position + seconds >= liveEdge { return true }
            self.position = min(liveEdge - 0.000_001, position + seconds)
            goal = CameraHistoryPolicy.initialWindow(at: self.position!, liveEdge: liveEdge)
        } else if let position {
            // A calendar seek can precede the first server anchor. Keep the
            // absolute selection when another shuttle seek supersedes that probe.
            self.position = position + seconds
        } else {
            if !isPaused && seconds > 0 && initialOffset + seconds >= 0 { return true }
            initialOffset = min(-0.000_001, initialOffset + seconds)
        }
        cancelRequest()
        failure = nil; retryAfter = 0; quickRetries = 0
        refreshState(); resetPresentation?(); ensureRequest(); changed?()
        return false
    }

    func togglePause() { isPaused.toggle(); ensureRequest(); changed?() }
    func pause() {
        guard isActive, !isPaused else { return }
        isPaused = true
        changed?()
    }
    @discardableResult
    func advance(by seconds: Double) -> Bool {
        guard isActive else { return false }
        var caughtUp = false
        if !isPaused, let position, let liveEdge, seconds.isFinite, seconds >= 0 {
            // Never run the playback clock through unknown/unloaded media. A
            // confirmed recording gap does advance, with an explicit black state.
            let end = buffer.knownEnd(from: position, now: clock(), liveEdge: liveEdge)
            if end > position {
                self.position = min(position + seconds, end, liveEdge - 0.000_001)
                caughtUp = seconds > 0 && self.position! >= liveEdge - CameraPlaybackSpeed.historyEdgeTolerance
            }
        }
        refreshState(); ensureRequest(); changed?()
        return caughtUp
    }
    func retry() {
        navigation = .idle; navigationBounds = nil
        failure = nil; retryAfter = 0; quickRetries = 0
        if let position, let liveEdge { goal = CameraHistoryPolicy.initialWindow(at: position, liveEdge: liveEdge) }
        refreshState(); ensureRequest(); changed?()
    }
    func deactivate() {
        bufferNavigation = nil
        isActive = false; state = .idle; goal = nil
        cancelRequest(); changed?()
    }
    func close() {
        deactivate()
        disconnect()
        buffer.removeAll(); position = nil; canonicalOffset = nil
        groupClock = false; groupLiveEdge = nil
    }
    func disconnect() {
        tagGeneration = UUID(); tagObserver?.cancel(); tagObserver = nil
        tagRefresh.cancel(); tagRegistrationPending = false
        cancelRequest()
        let old = transport; transport = nil
        Task { await old?.close() }
    }
    func trimForMemoryPressure() {
        buffer.removeAll()
        resetPresentation?()
        if isActive { retry() }
    }
    func location(preferredPiece: UUID?) -> CameraHistoryBuffer.Location? {
        guard isActive, let position else { return nil }
        return buffer.location(at: position, preferredPiece: preferredPiece)
    }

    private func cancelRequest() {
        navigationRefresh?.cancel(); navigationRefresh = nil
        token = UUID(); task?.cancel()
        resolvedLoadingPosition = nil
        // Retain the task so its canceled socket read can unwind before the
        // replacement request begins. The transport never has two readers.
        fetching = false
        navigation = .idle; navigationBounds = nil
    }
    private func refreshState() {
        guard isActive else { state = .idle; return }
        guard let position, let liveEdge else {
            state = failure.map(State.failed) ?? .loading; return
        }
        if buffer.location(at: position) != nil { state = .ready }
        else if buffer.isKnown(position, now: clock(), liveEdge: liveEdge) { state = .gap }
        else { state = failure.map(State.failed) ?? .loading }
    }
    private func ensureRequest() {
        guard isActive || bufferNavigation != nil else { return }
        guard !tagRegistrationPending, !fetching, clock() >= retryAfter, let transport, let cameraID else { return }
        let request: HBNVRMediaRequest
        let capturedHead = bufferNavigation?.head ?? localHead
        let capturedOffset = bufferNavigation.map { min(0, $0.position - $0.head) } ?? initialOffset
        let capturedPosition = position
        let excludingHidden = !showsHiddenVideo
        if !isActive {
            guard navigation != .unsupported, navigation != .hiddenUnsupported else { return }
            guard let bufferNavigation,
                  navigationPosition.map({ navigationNeedsRefresh(at: $0) })
                    ?? (navigation == .idle || clock() >= navigationExpires) else { return }
            if let navigationPosition {
                request = HBNVRMediaRequest(requestID: UUID().uuidString, operation: "neighbors", cameraID: cameraID,
                    timeline: "canonical", range: .init(start: navigationPosition, end: navigationPosition + 0.000_01))
            } else {
                let end = min(0, bufferNavigation.position - bufferNavigation.head)
                request = HBNVRMediaRequest(requestID: UUID().uuidString, operation: "neighbors", cameraID: cameraID,
                    timeline: "canonical", range: .init(start: end - 0.000_01, end: end), relativeTo: "live")
            }
            navigation = .loading
        } else if position != nil, canonicalOffset == nil {
            // Resolve the live edge without fetching unrelated video or using
            // the phone's wall clock as a live-to-canonical mapping.
            request = HBNVRMediaRequest(requestID: UUID().uuidString, operation: "availability", cameraID: cameraID,
                timeline: "canonical", range: .init(start: -1, end: 0), relativeTo: "live")
        } else if let position, let liveEdge {
            if hasNavigationRegion, navigationNeedsRefresh(at: position) {
                // Search the retained catalog around the unviewable cursor.
                var excluded = CameraHistoryRange(start: position, end: position + 0.000_01)
                if !showsHiddenVideo, let location = location(preferredPiece: nil), location.piece.samples[location.index].isHidden {
                    let sample = location.piece.samples[location.index]
                    let start = max(sample.time(in: location.piece.segment), position - 43_200)
                    // Exclude the entire known hidden frame. Approximate S3 tag
                    // boundaries inside it must not advertise that frame again.
                    excluded = .init(start: start,
                        end: min(max(sample.end(in: location.piece.segment), position + 0.000_01), start + 86_400))
                }
                request = HBNVRMediaRequest(requestID: UUID().uuidString, operation: "neighbors", cameraID: cameraID,
                    timeline: "canonical", range: .init(start: excluded.start, end: excluded.end))
                navigation = .loading
            } else {
                if let goal, buffer.missing(goal, now: clock(), liveEdge: liveEdge).isEmpty { self.goal = nil }
                if goal == nil, !isPaused {
                    goal = CameraHistoryPolicy.refill(at: position,
                        knownEnd: buffer.knownEnd(from: position, now: clock(), liveEdge: liveEdge),
                        liveEdge: liveEdge, speed: playbackSpeed)
                }
                guard let goal, let missing = buffer.missing(goal, now: clock(), liveEdge: liveEdge).first else { return }
                request = HBNVRMediaRequest(requestID: UUID().uuidString, operation: "frames", cameraID: cameraID,
                    timeline: "canonical", range: .init(start: missing.start, end: min(missing.end, missing.start + 60)))
            }
        } else {
            let window = CameraHistoryPolicy.initialWindow(at: initialOffset, liveEdge: 0)
            request = HBNVRMediaRequest(requestID: UUID().uuidString, operation: "frames", cameraID: cameraID,
                timeline: "canonical", range: .init(start: window.start, end: window.end), relativeTo: "live")
        }
        let id = UUID(); token = id
        let previous = task, initialTagSerial = tagSerial
        fetching = true
        task = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let batch: CameraHistoryBatch
                var fetchedFrames = request.operation == "frames"
                let onBegin: CameraHistoryBeginHandler = { [weak self] _, anchor in
                    await self?.requestBegan(id: id, anchor: anchor, offset: capturedOffset)
                }
                do {
                    do {
                        if request.operation == "neighbors" { batch = try await transport.neighbors(request, excludingHidden: excludingHidden) }
                        else { batch = try await transport.fetch(request, onBegin: onBegin) }
                    }
                    catch CameraHistoryError.remote(3, _) where request.relativeTo == "live" {
                        var fallback = request; fallback.relativeTo = "now"
                        if request.operation == "neighbors" { batch = try await transport.neighbors(fallback, excludingHidden: excludingHidden) }
                        else { batch = try await transport.fetch(fallback, onBegin: onBegin) }
                    }
                } catch {
                    try Task.checkCancellation()
                    guard request.operation == "availability", let target = capturedPosition else { throw error }
                    // An absolute archive seek does not need a live-camera clock.
                    // If NVR is offline, keep its exact selected UTC instant and
                    // use wall time only as an approximate forward-play ceiling.
                    // Relative Live-minus seeks still require a server anchor.
                    let ceiling = max(Date().timeIntervalSince1970, target + 30)
                    let range = CameraHistoryPolicy.initialWindow(at: target, liveEdge: ceiling)
                    let absolute = HBNVRMediaRequest(requestID: UUID().uuidString, operation: "frames", cameraID: cameraID,
                        timeline: "canonical", range: .init(start: range.start, end: range.end))
                    let resolved = try await transport.fetch(absolute, onBegin: onBegin)
                    batch = .init(id: resolved.id, range: resolved.range, anchor: ceiling, pieces: resolved.pieces,
                        gaps: resolved.gaps, neighbors: resolved.neighbors, unresolved: resolved.unresolved,
                        sourceWarning: resolved.sourceWarning)
                    fetchedFrames = true
                }
                guard let self, self.token == id, !Task.isCancelled else { return }
                if self.canonicalOffset == nil {
                    guard let anchor = batch.anchor else { throw CameraHistoryError.invalidResponse }
                    self.canonicalOffset = anchor - capturedHead
                    if self.isActive, let position = self.position {
                        if !self.groupClock { self.position = min(position, anchor - 0.000_001) }
                        self.goal = CameraHistoryPolicy.initialWindow(at: self.position!, liveEdge: self.requestLiveEdge(self.liveEdge!))
                    } else if self.isActive {
                        self.position = anchor + capturedOffset
                    }
                }
                if fetchedFrames {
                    self.buffer.insert(batch, at: self.clock(), around: self.position!)
                    if self.tagSerial != initialTagSerial, let source = transport as? any CameraFootageTagRefreshing {
                        self.refreshFootageTags(using: source)
                    }
                } else if request.operation == "neighbors" {
                    guard let neighbors = batch.neighbors else { throw CameraHistoryError.invalidResponse }
                    self.navigation = batch.sourceWarning.map { .partial(neighbors, $0) } ?? .ready(neighbors)
                    self.navigationBounds = CameraHistoryRange(start: neighbors.previous?.end ?? -1e11,
                        end: neighbors.next?.start ?? 1e11)
                    // New live footage can appear quickly; older gaps still get
                    // periodic refreshes for newly accessible stores or retention.
                    self.navigationExpires = self.clock() + (neighbors.next == nil || batch.sourceWarning != nil ? 5 : 60)
                    self.scheduleNavigationRefresh()
                }
                self.fetching = false; self.task = nil; self.quickRetries = 0
                if request.operation != "neighbors" {
                    self.failure = batch.sourceWarning
                    if batch.sourceWarning != nil { self.retryAfter = self.clock() + 5 }
                }
                self.refreshState(); self.ensureRequest(); self.changed?()
            } catch {
                guard let self, self.token == id, !Task.isCancelled else { return }
                if self.canonicalOffset == nil, let resolved = error as? CameraHistoryFetchFailure, let anchor = resolved.anchor {
                    self.canonicalOffset = anchor - capturedHead
                    if self.isActive, let position = self.position {
                        if !self.groupClock { self.position = min(position, anchor - 0.000_001) }
                        self.goal = CameraHistoryPolicy.initialWindow(at: self.position!, liveEdge: self.requestLiveEdge(self.liveEdge!))
                    } else if self.isActive {
                        self.position = anchor + capturedOffset
                        self.goal = resolved.range
                    }
                }
                let underlying = (error as? CameraHistoryFetchFailure)?.underlying ?? error
                if request.operation == "neighbors" {
                    self.fetching = false; self.task = nil
                    switch underlying as? CameraHistoryError {
                    case .neighborsUnsupported: self.navigation = .unsupported
                    case .hiddenNeighborsUnsupported: self.navigation = .hiddenUnsupported
                    default: self.navigation = .failed(error.localizedDescription)
                    }
                    let failedRange = (error as? CameraHistoryFetchFailure)?.range
                        ?? .init(start: request.range.start, end: request.range.end)
                    self.navigationBounds = .init(start: failedRange.start - 30, end: failedRange.end + 30)
                    self.navigationExpires = self.clock() + 5
                    if self.navigation != .unsupported && self.navigation != .hiddenUnsupported { self.scheduleNavigationRefresh() }
                    self.changed?()
                    return
                }
                if case CameraHistoryError.remote(3, _) = underlying, self.quickRetries < 1 {
                    self.quickRetries += 1
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    guard self.token == id, !Task.isCancelled else { return }
                    self.fetching = false; self.task = nil
                    self.ensureRequest(); self.changed?()
                    return
                }
                self.fetching = false; self.task = nil
                self.failure = error.localizedDescription; self.retryAfter = self.clock() + 5
                self.refreshState(); self.changed?()
            }
        }
        if request.operation == "neighbors" { changed?() }
    }

    private func navigationNeedsRefresh(at position: Double) -> Bool {
        if navigation == .unsupported || navigation == .hiddenUnsupported { return false }
        return navigationBounds?.contains(position) != true || clock() >= navigationExpires
    }

    private func scheduleNavigationRefresh() {
        navigationRefresh?.cancel()
        let delay = max(0.1, navigationExpires - clock())
        navigationRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.hasNavigationRegion, !Task.isCancelled else { return }
            self.ensureRequest(); self.changed?()
        }
    }

    func adjacentRecording(previous: Bool) -> Date? {
        guard hasNavigationRegion, let position = navigationPosition,
              navigationBounds?.contains(position) == true else { return nil }
        let neighbors: CameraHistoryNeighbors
        switch navigation {
        case .ready(let value), .partial(let value, _): neighbors = value
        default: return nil
        }
        guard let range = previous ? neighbors.previous : neighbors.next else { return nil }
        if !showsHiddenVideo, let refined = buffer.visiblePosition(near: range.start, before: range.end) {
            return Date(timeIntervalSince1970: refined)
        }
        return Date(timeIntervalSince1970: range.start)
    }

    func switchPosition(cameraID fallback: String?) -> CameraSwitchPosition? {
        guard isActive else { return nil }
        if let position = position ?? resolvedLoadingPosition { return .canonical(position, paused: isPaused) }
        // Capability metadata is available before the asynchronous connection is
        // configured. Switching during that initial wait must retain the seek.
        guard let cameraID = fallback ?? cameraID else { return nil }
        return .relative(cameraID: cameraID, offset: initialOffset, capturedAt: relativeCaptureTime, paused: isPaused)
    }

    private func requestBegan(id: UUID, anchor: Double?, offset: Double) {
        guard token == id, isActive, !Task.isCancelled else { return }
        if position == nil, let anchor {
            // Show the selected point, not the request's 30 seconds of preroll.
            // Do not use the phone clock or start playback before the full reply.
            resolvedLoadingPosition = anchor + offset
            changed?()
        }
    }
}
