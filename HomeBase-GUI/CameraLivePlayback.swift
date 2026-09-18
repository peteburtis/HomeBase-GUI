import Combine
import CoreMedia
import Foundation
import HomeBaseProtocol

/// Use the per-camera playback advertisement, not the presence of an NVR
/// recording control (which need not imply readable history for this camera).
enum CameraPlaybackHistoryAvailability {
    static func isAvailable(in metadata: [String: HBJSONValue]) -> Bool {
        guard let value = metadata[HBDeviceMetadataKeys.cameraPlayback],
              let history = try? value.decoded(HBCameraPlaybackMetadata.self) else { return false }
        return history.available && history.provider == "hbnvr"
            && !history.stores.isEmpty
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
        guard canControlPlayback else { return }
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

    mutating func advance(by seconds: TimeInterval) {
        guard mode == .playing, let head, let position,
              seconds.isFinite, seconds >= 0 else { return }
        self.position = min(head, position + seconds)
        clampToBufferStart()
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
    @Published private(set) var canControlPlayback = false
    @Published private(set) var canSeekBackward = false
    @Published private(set) var errorMessage: String?
    let renderer = CameraH264Renderer()
    private(set) var timeline = CameraLivePlaybackTimeline()
    private var ownerID: UUID?
    private var ticker: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?
    private var presentationID = UUID()
    private var lastTick: TimeInterval?
    private var configurations: [UInt64: HBMediaStreamConfiguration] = [:]
    private var rendererEpoch: UInt64?
    private var lastPrunedEpochs: (oldest: UInt64, source: UInt64)?
    private var isClosed = false

    var isLive: Bool { mode == .live }
    var isPaused: Bool { mode == .paused }

    func setNVRHistoryAvailable(_ available: Bool) {
        timeline.hasAvailableNVRHistory = available
        publishState()
    }

    func configure(
        _ configuration: HBMediaStreamConfiguration,
        ownerID: UUID
    ) throws -> CMVideoFormatDescription {
        guard !isClosed else { throw CancellationError() }
        cancelTasks()
        let description = try renderer.configure(configuration, removingDisplayedImage: !isPaused)
        self.ownerID = ownerID
        timeline.configure(
            generation: configuration.generation,
            timeScale: configuration.timeScale
        )
        configurations[timeline.sourceEpoch] = configuration
        rendererEpoch = timeline.sourceEpoch
        pruneConfigurations()
        errorMessage = nil
        publishState()
        if timeline.mode == .playing { startTicker() }
        return description
    }

    func receive(_ frame: HBMediaFrame, ownerID: UUID) throws -> CMSampleBuffer? {
        guard self.ownerID == ownerID,
              frame.generation == timeline.generation else { return nil }
        guard CameraH264Renderer.isValidAVCCAccessUnit(frame.payload) else {
            throw CameraH264Renderer.RendererError.invalidAccessUnit
        }
        let previousEpoch = timeline.sourceEpoch
        if timeline.receive(frame) {
            configurations[timeline.sourceEpoch] = configurations[previousEpoch]
            if timeline.isLive {
                cancelPresentation()
                renderer.reset()
            }
        }
        pruneConfigurations()
        publishState()
        // Only actual live samples can enter the explicit Photos recorder.
        guard timeline.isLive else { return nil }
        try activateRenderer(for: timeline.sourceEpoch)
        return try renderer.enqueue(frame)
    }

    func togglePause() {
        guard canControlPlayback else { return }
        updateClock()
        if timeline.mode == .paused {
            timeline.play()
            lastTick = ProcessInfo.processInfo.systemUptime
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
        timeline.seek(by: seconds)
        if timeline.isLive {
            goLive()
            return
        }
        lastTick = ProcessInfo.processInfo.systemUptime
        present()
        if timeline.mode == .playing { startTicker() }
        publishState()
    }

    func goLive() {
        cancelTasks()
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
        cancelTasks()
        self.ownerID = nil
        renderer.reset(removingDisplayedImage: false)
        // Ending a lease (backgrounding, retry, quality change) is not closing
        // the screen. The next lease appends a distinct epoch to this history.
        publishState()
    }

    func close() {
        isClosed = true
        cancelTasks()
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
        if mode != timeline.mode { mode = timeline.mode }
        if canControlPlayback != timeline.canControlPlayback {
            canControlPlayback = timeline.canControlPlayback
        }
        if canSeekBackward != timeline.canSeekBackward {
            canSeekBackward = timeline.canSeekBackward
        }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
                guard let self else { return }
                self.updateClock()
                self.present()
            }
        }
    }

    private func updateClock() {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastTick { timeline.advance(by: max(0, now - lastTick)) }
        lastTick = now
    }

    private func present() {
        guard presentationTask == nil else { return }
        switch timeline.presentation() {
        case .unchanged:
            break
        case .black:
            renderer.reset()
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
