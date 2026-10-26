import Foundation
import HomeBaseProtocol

/// A metadata-only companion to the existing video reader. Observers are
/// bounded and coalescing means "refresh all", never silently lost ranges.
nonisolated protocol CameraFootageTagRefreshing: CameraHistoryFetching {
    func tagChanges() async -> AsyncStream<HBNVRTagChange>
    func refreshTags(_ batch: CameraHistoryBatch) async throws -> CameraHistoryBatch
    func refreshTags(_ batches: [CameraHistoryBatch]) async throws -> [CameraHistoryBatch]
    func refreshThumbnails(_ images: [CameraThumbnail], cameraID: String) async throws -> [CameraThumbnail]
}

extension CameraFootageTagRefreshing {
    func refreshTags(_ batch: CameraHistoryBatch) async throws -> CameraHistoryBatch { batch }
    func refreshTags(_ batches: [CameraHistoryBatch]) async throws -> [CameraHistoryBatch] {
        var result: [CameraHistoryBatch] = []
        for batch in batches { result.append(try await refreshTags(batch)) }
        return result
    }
    func refreshThumbnails(_ images: [CameraThumbnail], cameraID: String) async throws -> [CameraThumbnail] { images }
}

nonisolated enum CameraFootageTags {
    static func reset(_ change: HBNVRTagChange) -> HBNVRTagChange {
        .init(instanceID: change.instanceID, revision: change.revision, reset: true, ranges: [])
    }
    static func yield(_ change: HBNVRTagChange, to continuation: AsyncStream<HBNVRTagChange>.Continuation) {
        if case .dropped = continuation.yield(change) { continuation.yield(reset(change)) }
    }
    static func affects(_ change: HBNVRTagChange, cameraID: String, range: CameraHistoryRange? = nil) -> Bool {
        change.reset || change.ranges.contains { value in
            value.cameraID.caseInsensitiveCompare(cameraID) == .orderedSame
                && (range.map { value.start < $0.end && value.end > $0.start } ?? true)
        }
    }
    static func hidden(at time: Double, epoch: String?, in snapshot: HBNVRTagSnapshot) -> Bool? {
        let matches = snapshot.spans.filter { $0.start <= time && $0.end > time && (epoch == nil || $0.epochID == epoch) }
        // A thumbnail with a legacy missing epoch cannot choose between clocks.
        guard Set(matches.map(\.epochID)).count <= 1, !matches.isEmpty else { return nil }
        let values = matches.compactMap { span -> Bool? in
            if span.tags.values[CameraVideoTags.hiddenKey] != nil { return true }
            if span.tags.complete || span.tags.knownAbsent.contains(CameraVideoTags.hiddenKey) { return false }
            return nil
        }
        guard values.count == matches.count, Set(values).count == 1 else { return nil }
        return values.first
    }
    static func ranges(for batches: [CameraHistoryBatch]) -> [HBNVRTagQueryRange] {
        let groups = Dictionary(grouping: batches.flatMap(\.pieces), by: { $0.segment.time.epochID })
        return groups.keys.sorted().flatMap { epoch in
            let ranges = groups[epoch]!.compactMap { piece -> CameraHistoryRange? in
                guard let first = piece.samples.first, let last = piece.samples.last else { return nil }
                return .init(start: first.time(in: piece.segment), end: last.end(in: piece.segment))
            }
            return CameraHistoryRange.merged(ranges).flatMap { range -> [HBNVRTagQueryRange] in
                var result: [HBNVRTagQueryRange] = [], cursor = range.start
                while cursor < range.end {
                    let end = min(range.end, cursor + 300)
                    result.append(.init(start: cursor, end: end, epochID: epoch)); cursor = end
                }
                return result
            }
        }
    }
    static func applying(_ snapshot: HBNVRTagSnapshot, to batch: CameraHistoryBatch) -> CameraHistoryBatch {
        let pieces = batch.pieces.map { piece in
            var copy = piece
            for index in copy.samples.indices {
                let sample = copy.samples[index]
                if let hidden = hidden(at: sample.time(in: copy.segment), epoch: copy.segment.time.epochID, in: snapshot) {
                    copy.samples[index].isHidden = hidden
                }
            }
            return copy
        }
        return .init(id: batch.id, range: batch.range, anchor: batch.anchor, pieces: pieces,
            gaps: batch.gaps, neighbors: batch.neighbors, unresolved: batch.unresolved, sourceWarning: batch.sourceWarning)
    }
}

/// Applies current NVR metadata after either source finishes. An old S3 manifest
/// or delayed read can never overwrite a newer accepted tag snapshot.
actor CameraTaggedHistorySource: CameraThumbnailFetching, CameraFootageTagRefreshing {
    typealias Snapshot = @Sendable (HBNVRTagQuery) async throws -> HBNVRTagSnapshot?
    private let source: any CameraHistoryFetching
    private let snapshot: Snapshot
    private let updates: AsyncStream<HBNVRTagChange>
    private var observer: Task<Void, Never>?
    private var listeners: [UUID: AsyncStream<HBNVRTagChange>.Continuation] = [:]
    private var closed = false
    private var generation: UInt64 = 0
    // At most 64 validated 64-KiB snapshots, matching the retained batch cap.
    // This is last-known metadata only: no event journal or deferred requests.
    private var knownSnapshots: [HBNVRTagSnapshot] = []

    init(source: any CameraHistoryFetching, updates: AsyncStream<HBNVRTagChange>, snapshot: @escaping Snapshot) {
        self.source = source; self.updates = updates; self.snapshot = snapshot
    }
    func observe() {
        guard observer == nil, !closed else { return }
        observer = Task { [weak self, updates] in
            for await change in updates {
                guard !Task.isCancelled else { return }
                await self?.changed(change)
            }
        }
    }
    private func changed(_ change: HBNVRTagChange) {
        generation &+= 1
        for listener in listeners.values { CameraFootageTags.yield(change, to: listener) }
    }
    func tagChanges() -> AsyncStream<HBNVRTagChange> {
        let id = UUID(), pair = AsyncStream<HBNVRTagChange>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard !closed else { pair.continuation.finish(); return pair.stream }
        listeners[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
        return pair.stream
    }
    private func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }
    func start() async { observe(); await source.start() }
    func close() async {
        closed = true; observer?.cancel(); observer = nil
        for listener in listeners.values { listener.finish() }; listeners.removeAll()
        knownSnapshots.removeAll()
        await source.close()
    }
    private func remember(_ snapshot: HBNVRTagSnapshot) {
        if knownSnapshots.first?.instanceID != snapshot.instanceID { knownSnapshots.removeAll() }
        func supersedes(_ newer: HBNVRTagSnapshot, _ older: HBNVRTagSnapshot) -> Bool {
            guard newer.cameraID.caseInsensitiveCompare(older.cameraID) == .orderedSame,
                  newer.revision >= older.revision else { return false }
            return older.spans.allSatisfy { old in
                let coverage = newer.spans.filter { span in
                    span.epochID == old.epochID && (span.tags.values[CameraVideoTags.hiddenKey] != nil
                        || span.tags.complete || span.tags.knownAbsent.contains(CameraVideoTags.hiddenKey))
                }.map { CameraHistoryRange(start: $0.start, end: $0.end) }
                return CameraHistoryRange(start: old.start, end: old.end).subtracting(coverage).isEmpty
            }
        }
        // Full retained-window refreshes replace older snapshots of that window.
        // A slower earlier read must never replace newer accepted knowledge.
        guard !knownSnapshots.contains(where: { supersedes($0, snapshot) }) else { return }
        knownSnapshots.removeAll { supersedes(snapshot, $0) }
        knownSnapshots.append(snapshot)
        knownSnapshots.sort { $0.revision < $1.revision }
        if knownSnapshots.count > 64 { knownSnapshots.removeFirst(knownSnapshots.count - 64) }
    }
    private func known(for cameraID: String) -> [HBNVRTagSnapshot] {
        knownSnapshots.filter { $0.cameraID.caseInsensitiveCompare(cameraID) == .orderedSame }
    }
    private func read(_ query: HBNVRTagQuery, deadline: Double? = nil) async throws -> HBNVRTagSnapshot? {
        try query.validate()
        func checkDeadline() throws {
            if let deadline, ProcessInfo.processInfo.systemUptime >= deadline {
                throw CameraHistoryError.remote(nil, "Timed out refreshing footage tags for navigation.")
            }
        }
        for _ in 0..<2 {
            try checkDeadline()
            try Task.checkCancellation(); guard !closed else { throw CancellationError() }
            let token = generation, result = try await snapshot(query)
            try checkDeadline()
            try Task.checkCancellation(); guard !closed else { throw CancellationError() }
            if token == generation { return result }
        }
        throw CameraHistoryError.remote(nil, "Footage tags changed while being refreshed; try again.")
    }
    func refreshTags(_ batch: CameraHistoryBatch) async throws -> CameraHistoryBatch {
        try await refreshTags([batch])[0]
    }
    func refreshTags(_ batches: [CameraHistoryBatch]) async throws -> [CameraHistoryBatch] {
        let ranges = CameraFootageTags.ranges(for: batches)
        guard !ranges.isEmpty else { return batches }
        // Queries are bounded even when independent batches include GOP preroll.
        guard ranges.count <= 64, ranges.reduce(0, { $0 + $1.end - $1.start }) <= 3600 else { throw CameraHistoryError.tooLarge }
        guard let camera = currentCameraID else { throw CameraHistoryError.invalidResponse }
        do {
            if let result = try await read(.init(cameraID: camera, ranges: ranges, keys: [CameraVideoTags.hiddenKey])) { remember(result) }
        } catch let error as HBProtocolError where error.code == "nvr_offline" {
            // Direct S3 playback remains usable when the recorder is offline.
            // Retained authoritative knowledge wins over delayed cloud tags.
        }
        return known(for: camera).reduce(batches) { batches, snapshot in
            batches.map { CameraFootageTags.applying(snapshot, to: $0) }
        }
    }
    private var currentCameraID: String?
    func setCamera(_ cameraID: String) { currentCameraID = cameraID }
    func fetch(_ request: HBNVRMediaRequest, onBegin: CameraHistoryBeginHandler?) async throws -> CameraHistoryBatch {
        currentCameraID = request.cameraID
        let batch = try await source.fetch(request, onBegin: onBegin)
        return try await refreshTags(batch)
    }
    func refreshThumbnails(_ images: [CameraThumbnail], cameraID: String) async throws -> [CameraThumbnail] {
        guard !images.isEmpty else { return images }
        let ranges = images.map { HBNVRTagQueryRange(start: $0.timestamp, end: $0.timestamp + 0.001, epochID: $0.epochID) }
        do {
            if let result = try await read(.init(cameraID: cameraID, ranges: ranges, keys: [CameraVideoTags.hiddenKey])) { remember(result) }
        } catch let error as HBProtocolError where error.code == "nvr_offline" {
            // Same bounded, source-lifetime knowledge as full-frame playback.
        }
        return known(for: cameraID).reduce(images) { images, snapshot in
            images.map { image in
                var copy = image
                if let hidden = CameraFootageTags.hidden(at: image.timestamp, epoch: image.epochID, in: snapshot) { copy.isHidden = hidden }
                return copy
            }
        }
    }
    func thumbnail(_ request: HBNVRThumbnailRequest) async throws -> CameraThumbnail? {
        guard let source = source as? any CameraThumbnailFetching else { throw CameraThumbnailError.unsupported }
        guard let image = try await source.thumbnail(request) else { return nil }
        return try await refreshThumbnails([image], cameraID: request.cameraID).first
    }
    func neighbors(_ request: HBNVRMediaRequest, excludingHidden: Bool) async throws -> CameraHistoryBatch {
        // Ordinary availability stays independent of privacy. Filtered searches
        // use the authoritative snapshot instead of potentially old cloud tags.
        guard excludingHidden else { return try await source.neighbors(request, excludingHidden: false) }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        func checkBudget() throws {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CameraHistoryError.remote(nil, "Timed out refreshing footage tags for navigation.")
            }
        }
        var initial = try await source.neighbors(request, excludingHidden: false)
        try checkBudget()
        guard initial.neighbors != nil else { throw CameraHistoryError.invalidResponse }
        var resolved: [CameraHistoryRange?] = []
        for previous in [true, false] {
            // Unfiltered neighbors omit the recording containing the cursor.
            // Inspect that recording's nearby timeline before jumping farther.
            var candidate: CameraHistoryRange? = previous
                ? (initial.range.start > 0 ? .init(start: max(0, initial.range.start - 300), end: initial.range.start) : nil)
                : .init(start: initial.range.end, end: initial.range.end + 300)
            var knownCoverage = false
            var visible: CameraHistoryRange?
            var remaining = 32
            while let range = candidate, remaining > 0, visible == nil {
                try checkBudget()
                remaining -= 1
                let window = CameraHistoryRange(start: previous ? max(range.start, range.end - 300) : range.start,
                    end: previous ? range.end : min(range.end, range.start + 300))
                let tags: HBNVRTagSnapshot
                do {
                    guard let result = try await read(.init(cameraID: request.cameraID,
                        ranges: [.init(start: window.start, end: window.end)], keys: [CameraVideoTags.hiddenKey]), deadline: deadline) else {
                        return try await source.neighbors(request, excludingHidden: true)
                    }
                    tags = result
                } catch let error as HBProtocolError where error.code == "nvr_offline" {
                    return try await source.neighbors(request, excludingHidden: true)
                }
                try checkBudget()
                guard (!knownCoverage || !tags.spans.isEmpty), tags.spans.allSatisfy({ $0.tags.values[CameraVideoTags.hiddenKey] != nil
                    || $0.tags.complete || $0.tags.knownAbsent.contains(CameraVideoTags.hiddenKey) }) else {
                    throw CameraHistoryError.remote(nil, "Footage tags are not available for this navigation range.")
                }
                let spans = tags.spans.filter { $0.tags.values[CameraVideoTags.hiddenKey] == nil
                    && ($0.tags.complete || $0.tags.knownAbsent.contains(CameraVideoTags.hiddenKey)) }
                if let span = previous ? spans.max(by: { $0.end < $1.end }) : spans.min(by: { $0.start < $1.start }) {
                    visible = .init(start: max(window.start, span.start), end: min(window.end, span.end)); break
                }
                if previous && window.start > range.start { candidate = .init(start: range.start, end: window.start) }
                else if !previous && window.end < range.end { candidate = .init(start: window.end, end: range.end) }
                else if tags.spans.contains(where: { previous ? $0.start <= window.start : $0.end >= window.end }) {
                    candidate = previous
                        ? (window.start > 0 ? .init(start: max(0, window.start - 300), end: window.start) : nil)
                        : .init(start: window.end, end: window.end + 300)
                    knownCoverage = false
                } else {
                    let nextRange = CameraHistoryRange(start: previous ? range.start : initial.range.start,
                        end: previous ? initial.range.end : range.end)
                    let next = try await source.neighbors(.init(requestID: UUID().uuidString, operation: "neighbors",
                        cameraID: request.cameraID, timeline: "canonical", range: .init(start: nextRange.start, end: nextRange.end)), excludingHidden: false)
                    try checkBudget()
                    let nextCandidate = previous ? next.neighbors?.previous : next.neighbors?.next
                    guard nextCandidate != candidate else { break }
                    candidate = nextCandidate; knownCoverage = true
                }
            }
            if remaining == 0 && visible == nil { throw CameraHistoryError.tooLarge }
            resolved.append(visible)
        }
        initial.neighbors = .init(previous: resolved[0], next: resolved[1])
        return initial
    }
}

/// One active metadata read and one dirty bit per cache. Events that arrive
/// during a read supersede its result and cause one latest-state refresh.
@MainActor
final class CameraFootageRefreshTask {
    // SwiftUI can release the owner outside a Swift task; cleanup is explicit.
    nonisolated deinit {}
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var lifecycle = UUID()
    private var dirty = false
    private var work: (@MainActor (UInt64) async -> Void)?
    func isCurrent(_ token: UInt64) -> Bool { !Task.isCancelled && generation == token }
    func schedule(_ operation: @escaping @MainActor (UInt64) async -> Void) {
        generation &+= 1; dirty = true; work = operation
        guard task == nil else { return }
        let lifetime = lifecycle
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.lifecycle == lifetime, self.dirty {
                self.dirty = false
                let token = self.generation
                await self.work?(token)
            }
            if self.lifecycle == lifetime { self.task = nil; self.work = nil }
        }
    }
    func cancel() {
        lifecycle = UUID(); generation &+= 1; dirty = false; work = nil
        task?.cancel(); task = nil
    }
}
