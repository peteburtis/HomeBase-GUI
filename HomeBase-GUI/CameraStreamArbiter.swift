import Foundation
import HomeBaseProtocol

/// A user's live-video choice. `automatic` preserves the protocol's omitted
/// quality request, allowing HomeBase to select its shared/default source.
nonisolated enum CameraLiveQualitySelection: String, CaseIterable, Comparable, Sendable {
    case automatic
    case low
    case medium
    case high

    init(_ quality: HBCameraLiveQuality) {
        switch quality {
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        }
    }

    var requestedQuality: HBCameraLiveQuality? {
        switch self {
        case .automatic: nil
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }

    private var priority: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        case .automatic: 3
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.priority < rhs.priority
    }
}

/// Invalidated synchronously by the camera lock, including during an acquire.
nonisolated final class CameraStreamAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
}

nonisolated struct CameraStreamUpstream: Sendable {
    let frames: AsyncThrowingStream<HBMediaFrame, Error>
    let close: @Sendable () async -> Void
}
nonisolated enum CameraStreamEvent: Sendable {
    /// Configuration and its keyframe-led bootstrap travel as one queue entry.
    case frames([HBMediaFrame])
    case qualityWarning(String?)
}
nonisolated struct CameraStreamSubscription: Sendable {
    let id: UUID
    let camera: String
    let events: AsyncThrowingStream<CameraStreamEvent, Error>
}
nonisolated enum CameraStreamError: Error, LocalizedError, Equatable {
    case closed, invalidMedia, slowConsumer, ended, warmupTimeout
    var errorDescription: String? {
        switch self {
        case .closed: "Camera streaming is closed."
        case .invalidMedia: "The camera sent invalid stream configuration or video."
        case .slowConsumer: "This view could not keep up with the camera stream. Try again."
        case .ended: "The live video connection ended."
        case .warmupTimeout: "The replacement stream did not become ready in time."
        }
    }
}

/// One arbiter per Homebase client/session. This shares encoded media, not view
/// renderers, five-minute playback buffers, Photos writers, or history readers.
actor CameraStreamArbiter {
    typealias Open = @Sendable (String, CameraLiveQualitySelection) async throws -> CameraStreamUpstream
    typealias Sleep = @Sendable (Double) async throws -> Void
    struct Policy: Sendable {
        var idleGrace = 2.0
        var downgradeDelay = 2.0
        var warmupDeadline = 20.0
        var bootstrapBytes = 8 * 1024 * 1024
        var bootstrapFrames = 150
        var consumerQueue = 120
    }
    private final class Consumer {
        var quality: CameraLiveQualitySelection
        let continuation: AsyncThrowingStream<CameraStreamEvent, Error>.Continuation
        var joinedGeneration: UInt32?
        init(_ quality: CameraLiveQualitySelection, _ continuation: AsyncThrowingStream<CameraStreamEvent, Error>.Continuation) {
            self.quality = quality; self.continuation = continuation
        }
    }
    private final class Worker {
        let id = UUID()
        let quality: CameraLiveQualitySelection
        var task: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var configuration: HBMediaFrame?
        var wireGeneration: UInt32?
        var generation: UInt32 = 0
        var gop: [HBMediaFrame] = []
        var bytes = 0
        var retiring = false
        init(_ quality: CameraLiveQualitySelection) { self.quality = quality }
    }
    private final class Entry {
        let authorization: CameraStreamAuthorization?
        var consumers: [UUID: Consumer] = [:]
        var workers: [UUID: Worker] = [:]
        var current: UUID?
        var candidate: UUID?
        var idle: Task<Void, Never>?
        var idleToken: UUID?
        var delayed: Task<Void, Never>?
        var delayToken: UUID?
        var retryCount = 0
        var requested: CameraLiveQualitySelection?
        init(_ authorization: CameraStreamAuthorization?) { self.authorization = authorization }
    }
    private let open: Open
    private let sleep: Sleep
    private let policy: Policy
    private var entries: [String: Entry] = [:]
    private var nextGeneration: UInt32 = 0
    private var closed = false

    init(policy: Policy = Policy(), sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) }, open: @escaping Open) {
        self.policy = policy; self.sleep = sleep; self.open = open
    }

    func subscribe(camera: String, quality: CameraLiveQualitySelection, authorization: CameraStreamAuthorization? = nil) throws -> CameraStreamSubscription {
        try Task.checkCancellation()
        // Keep the advertised address intact: the server's initial device
        // lookup is case-sensitive even though its internal fanout key is not.
        guard !closed, authorization?.isValid != false else { throw CameraStreamError.closed }
        if let old = entries[camera], old.authorization !== authorization { remove(camera, error: CancellationError()) }
        let entry = entries[camera] ?? Entry(authorization)
        entries[camera] = entry
        entry.idle?.cancel(); entry.idle = nil; entry.idleToken = nil
        let id = UUID()
        let pair = AsyncThrowingStream<CameraStreamEvent, Error>.makeStream(bufferingPolicy: .bufferingNewest(policy.consumerQueue))
        let consumer = Consumer(quality, pair.continuation)
        entry.consumers[id] = consumer
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(camera: camera, id: id) } }
        if let current = entry.current.flatMap({ entry.workers[$0] }), !current.gop.isEmpty { prime(consumer, worker: current) }
        reconcile(camera, entry)
        return .init(id: id, camera: camera, events: pair.stream)
    }

    func update(_ subscription: CameraStreamSubscription, quality: CameraLiveQualitySelection) {
        guard let entry = entries[subscription.camera], let consumer = entry.consumers[subscription.id] else { return }
        consumer.quality = quality
        reconcile(subscription.camera, entry)
    }
    func unsubscribe(camera: String, id: UUID, immediately: Bool = false) {
        guard let entry = entries[camera], let consumer = entry.consumers.removeValue(forKey: id) else { return }
        consumer.continuation.finish()
        guard entry.authorization?.isValid != false else { remove(camera, error: CancellationError()); return }
        if entry.consumers.isEmpty {
            if immediately { remove(camera, error: CancellationError()); return }
            entry.delayed?.cancel(); entry.delayed = nil; entry.delayToken = nil
            if let candidate = entry.candidate { retire(entry, id: candidate) }
            entry.candidate = nil
            let token = UUID(); entry.idleToken = token
            entry.idle = Task { [weak self, sleep, policy] in
                do { try await sleep(policy.idleGrace) } catch { return }
                await self?.expire(camera, entry: entry, token: token)
            }
        } else { reconcile(camera, entry) }
    }
    private func expire(_ camera: String, entry: Entry, token: UUID) {
        guard entries[camera] === entry, entry.idleToken == token, entry.consumers.isEmpty else { return }
        remove(camera, error: CancellationError())
    }
    func revoke(_ authorization: CameraStreamAuthorization) {
        authorization.invalidate()
        for camera in Array(entries.keys) where entries[camera]?.authorization === authorization { remove(camera, error: CancellationError()) }
    }
    func shutdown() {
        closed = true
        for camera in Array(entries.keys) { remove(camera, error: CancellationError()) }
    }
    private func remove(_ camera: String, error: Error) {
        guard let entry = entries.removeValue(forKey: camera) else { return }
        entry.idle?.cancel(); entry.delayed?.cancel()
        for worker in entry.workers.values { retire(entry, id: worker.id) }
        for consumer in entry.consumers.values { consumer.continuation.finish(throwing: error) }
        entry.consumers.removeAll()
    }
    private func retire(_ entry: Entry, id: UUID) {
        guard let worker = entry.workers[id] else { return }
        worker.retiring = true; worker.gop.removeAll(); worker.bytes = 0
        worker.deadline?.cancel(); worker.task?.cancel()
    }

    private func reconcile(_ camera: String, _ entry: Entry, allowDowngrade: Bool = false) {
        guard entries[camera] === entry else { return }
        guard entry.authorization?.isValid != false else { remove(camera, error: CancellationError()); return }
        guard let desired = entry.consumers.values.map(\.quality).max() else { return }
        if entry.requested != desired {
            entry.requested = desired; entry.retryCount = 0
            entry.delayed?.cancel(); entry.delayed = nil; entry.delayToken = nil
            broadcast(.qualityWarning(nil), camera: camera, entry: entry)
        }
        if let candidate = entry.candidate, entry.workers[candidate]?.quality != desired {
            retire(entry, id: candidate); entry.candidate = nil
        }
        if let current = entry.current.flatMap({ entry.workers[$0] }), current.quality == desired { return }
        guard entry.candidate == nil, entry.delayed == nil else { return }
        if !allowDowngrade, let current = entry.current.flatMap({ entry.workers[$0] }), desired < current.quality {
            schedule(camera, entry, seconds: policy.downgradeDelay); return
        }
        // Normally current + candidate. A cancelled warm-up may briefly still
        // be closing; at most one such retiree can overlap a new warm-up.
        guard entry.workers.count < 3 else { return }
        start(camera, entry, quality: desired)
    }
    private func schedule(_ camera: String, _ entry: Entry, seconds: Double) {
        let token = UUID(); entry.delayToken = token
        entry.delayed = Task { [weak self, sleep] in
            do { try await sleep(seconds) } catch { return }
            await self?.resume(camera, entry: entry, token: token)
        }
    }
    private func resume(_ camera: String, entry: Entry, token: UUID) {
        guard entries[camera] === entry, entry.delayToken == token else { return }
        entry.delayed = nil; entry.delayToken = nil
        reconcile(camera, entry, allowDowngrade: true)
    }
    private func start(_ camera: String, _ entry: Entry, quality: CameraLiveQualitySelection) {
        let worker = Worker(quality)
        entry.workers[worker.id] = worker; entry.candidate = worker.id
        worker.task = Task { [weak self, open] in
            var upstream: CameraStreamUpstream?
            var failure: Error = CameraStreamError.ended
            do {
                let stream = try await open(camera, quality); upstream = stream
                try Task.checkCancellation()
                for try await frame in stream.frames {
                    try Task.checkCancellation()
                    guard let self, try await self.receive(frame, camera: camera, entry: entry, worker: worker) else { break }
                }
            } catch { failure = error }
            if let upstream { await upstream.close() }
            await self?.finished(camera, entry: entry, worker: worker, error: failure)
        }
        worker.deadline = Task { [weak self, sleep, policy] in
            do { try await sleep(policy.warmupDeadline) } catch { return }
            await self?.timedOut(camera, entry: entry, worker: worker)
        }
    }
    private func timedOut(_ camera: String, entry: Entry, worker: Worker) {
        guard entries[camera] === entry, entry.candidate == worker.id else { return }
        retire(entry, id: worker.id); entry.candidate = nil
        failedCandidate(camera, entry, error: CameraStreamError.warmupTimeout)
    }
    private func failedCandidate(_ camera: String, _ entry: Entry, error: Error) {
        guard !entry.consumers.isEmpty else { return }
        guard entry.current != nil else { remove(camera, error: error); return }
        broadcast(.qualityWarning("Could not change video quality. Continuing the current stream; retrying…"), camera: camera, entry: entry)
        entry.retryCount = min(5, entry.retryCount + 1)
        schedule(camera, entry, seconds: min(30, pow(2, Double(entry.retryCount))))
    }
    private func finished(_ camera: String, entry: Entry, worker: Worker, error: Error) {
        worker.deadline?.cancel(); worker.gop.removeAll(); worker.bytes = 0
        guard entries[camera] === entry else { return }
        entry.workers[worker.id] = nil
        if entry.candidate == worker.id { entry.candidate = nil; failedCandidate(camera, entry, error: error) }
        else if entry.current == worker.id {
            entry.current = nil
            // A replacement already opening can still recover this view. Its
            // existing deadline bounds the wait; don't throw it away merely
            // because the old feed ended first.
            if entry.candidate == nil { remove(camera, error: error) }
        }
        else { reconcile(camera, entry) }
    }

    private func receive(_ incoming: HBMediaFrame, camera: String, entry: Entry, worker: Worker) throws -> Bool {
        guard entries[camera] === entry, !worker.retiring else { return false }
        guard entry.authorization?.isValid != false else { remove(camera, error: CancellationError()); return false }
        var frame = incoming
        switch frame.type {
        case .streamConfiguration:
            var configuration = try JSONDecoder().decode(HBMediaStreamConfiguration.self, from: frame.payload)
            guard configuration.generation == incoming.generation, configuration.codec.lowercased() == "h264",
                  configuration.timeScale > 0, configuration.timeScale <= UInt32(Int32.max),
                  let sps = Data(base64Encoded: configuration.sequenceParameterSet), !sps.isEmpty,
                  let pps = Data(base64Encoded: configuration.pictureParameterSet), !pps.isEmpty else { throw CameraStreamError.invalidMedia }
            nextGeneration &+= 1
            worker.wireGeneration = incoming.generation; worker.generation = nextGeneration
            configuration.generation = nextGeneration; frame.generation = nextGeneration
            frame.payload = try JSONEncoder().encode(configuration); worker.configuration = frame
            worker.gop.removeAll(); worker.bytes = 0
        case .videoAccessUnit:
            guard let configuration = worker.configuration, worker.wireGeneration == incoming.generation,
                  CameraH264Renderer.isValidAVCCAccessUnit(frame.payload) else { throw CameraStreamError.invalidMedia }
            frame.generation = worker.generation
            let keyframe = frame.flags.contains(.keyFrame)
            if keyframe { worker.gop = [frame]; worker.bytes = frame.payload.count }
            else if !worker.gop.isEmpty { worker.gop.append(frame); worker.bytes += frame.payload.count }
            if worker.bytes > policy.bootstrapBytes || worker.gop.count > policy.bootstrapFrames {
                worker.gop.removeAll(); worker.bytes = 0 // Joiners wait for the next keyframe, never receive an incomplete GOP.
            }
            if entry.candidate == worker.id, keyframe {
                let previous = entry.current
                entry.current = worker.id; entry.candidate = nil; entry.retryCount = 0
                worker.deadline?.cancel()
                broadcast(.qualityWarning(nil), camera: camera, entry: entry)
                for consumer in entry.consumers.values { consumer.joinedGeneration = worker.generation }
                broadcast(.frames([configuration, frame]), camera: camera, entry: entry)
                if let previous { retire(entry, id: previous) }
            } else if entry.current == worker.id {
                for (id, consumer) in Array(entry.consumers) {
                    if consumer.joinedGeneration != worker.generation {
                        guard keyframe else { continue }
                        consumer.joinedGeneration = worker.generation
                        deliver(.frames([configuration, frame]), consumer: consumer, camera: camera, id: id)
                    } else { deliver(.frames([frame]), consumer: consumer, camera: camera, id: id) }
                }
            }
        case .streamStatus:
            if entry.current == nil || entry.current == worker.id { broadcast(.frames([frame]), camera: camera, entry: entry) }
        case .streamEnd:
            if (entry.current == worker.id && entry.candidate == nil) || entry.current == nil {
                broadcast(.frames([frame]), camera: camera, entry: entry)
            }
            return false
        case .clientHello: throw CameraStreamError.invalidMedia
        }
        return true
    }
    private func prime(_ consumer: Consumer, worker: Worker) {
        guard let configuration = worker.configuration, !worker.gop.isEmpty else { return }
        consumer.joinedGeneration = worker.generation
        consumer.continuation.yield(.frames([configuration] + worker.gop))
    }
    private func broadcast(_ event: CameraStreamEvent, camera: String, entry: Entry) {
        for (id, consumer) in Array(entry.consumers) { deliver(event, consumer: consumer, camera: camera, id: id) }
    }
    private func deliver(_ event: CameraStreamEvent, consumer: Consumer, camera: String, id: UUID) {
        switch consumer.continuation.yield(event) {
        case .enqueued: break
        case .dropped:
            consumer.continuation.finish(throwing: CameraStreamError.slowConsumer)
            unsubscribe(camera: camera, id: id)
        case .terminated: unsubscribe(camera: camera, id: id)
        @unknown default: unsubscribe(camera: camera, id: id)
        }
    }
}
