import Foundation
import HomeBaseProtocol

/// Policy, not a second playback pipeline. Local frames win; cloud fills only
/// the missing intervals. Cancellation is never a reason to start an AWS read.
actor CameraHistoryFallback: CameraHistoryFetching {
    private let local: any CameraHistoryFetching
    private let remote: (any CameraHistoryFetching)?
    private var closed = false
    init(local: any CameraHistoryFetching, remote: (any CameraHistoryFetching)?) {
        self.local = local; self.remote = remote
    }
    func start() async { await local.start() }
    func close() async { closed = true; await local.close(); await remote?.close() }
    func neighbors(_ request: HBNVRMediaRequest, excludingHidden: Bool) async throws -> CameraHistoryBatch {
        guard request.operation == "neighbors" else { throw CameraHistoryError.invalidResponse }
        guard excludingHidden else { return try await fetch(request) }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        var localResult: CameraHistoryBatch?, localError: Error?
        do {
            let result = try await local.neighbors(request, excludingHidden: true)
            guard result.neighbors != nil else { throw CameraHistoryError.invalidResponse }
            localResult = result
        }
        catch {
            try checkNavigation(deadline: deadline)
            if error is CancellationError || (error as? CameraHistoryFetchFailure)?.underlying is CancellationError { throw CancellationError() }
            localError = error
        }
        try checkCancellation()
        guard let remote else {
            if let localResult { return localResult }
            throw localError ?? CameraHistoryError.unavailable
        }
        let failure = localError as? CameraHistoryFetchFailure
        // A cloud manifest cannot resolve the recorder's relative Live clock.
        guard request.relativeTo == nil || localResult?.anchor != nil || failure?.anchor != nil else {
            throw localError ?? CameraHistoryError.invalidResponse
        }
        let range = localResult?.range ?? failure?.range ?? .init(start: request.range.start, end: request.range.end)
        let absolute = absolute(request, range: range)
        var previous = localResult?.neighbors?.previous, next = localResult?.neighbors?.next
        var warnings = [localResult?.sourceWarning, localError?.localizedDescription].compactMap { $0 }
        var cloudError: Error?, remaining = 128
        do {
            try checkNavigation(deadline: deadline)
            let cloud = try await remote.neighbors(absolute, excludingHidden: true)
            guard cloud.neighbors != nil else { throw CameraHistoryError.invalidResponse }
            if let warning = cloud.sourceWarning { warnings.append(warning) }
            for backward in [true, false] {
                do {
                    let candidate = try await cloudNeighbor(previous: backward, initial: cloud, request: absolute,
                        localDestination: backward ? previous : next, localSearchFailed: localError != nil,
                        remote: remote, remaining: &remaining, deadline: deadline)
                    if let candidate {
                        if backward { previous = candidate } else { next = candidate }
                    }
                } catch {
                    try checkCancellation(error)
                    cloudError = error; warnings.append(error.localizedDescription)
                }
            }
        } catch {
            try checkCancellation(error)
            cloudError = error; warnings.append(error.localizedDescription)
        }
        try checkCancellation()
        // A failed source cannot establish that both archive directions end.
        if previous == nil && next == nil && !warnings.isEmpty {
            throw cloudError ?? localError ?? CameraHistoryError.unavailable
        }
        return .init(id: UUID(), range: range, anchor: localResult?.anchor ?? failure?.anchor, pieces: [], gaps: [],
            neighbors: .init(previous: previous, next: next),
            sourceWarning: warnings.isEmpty ? nil : Array(Set(warnings)).sorted().joined(separator: " "))
    }

    private func checkCancellation(_ error: Error? = nil) throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if error is CancellationError || (error as? CameraHistoryFetchFailure)?.underlying is CancellationError { throw CancellationError() }
    }

    private func checkNavigation(deadline: Double) throws {
        try checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw CameraHistoryError.remote(nil, "Timed out finding available video.")
        }
    }

    private func cloudNeighbor(previous: Bool, initial: CameraHistoryBatch, request: HBNVRMediaRequest,
                               localDestination: CameraHistoryRange?, localSearchFailed: Bool,
                               remote: any CameraHistoryFetching, remaining: inout Int,
                               deadline: Double) async throws -> CameraHistoryRange? {
        var result = initial
        var frontier = previous ? request.range.start : request.range.end
        while let candidate = previous ? result.neighbors?.previous : result.neighbors?.next {
            try checkNavigation(deadline: deadline)
            guard candidate.isValid, previous ? candidate.end <= frontier : candidate.start >= frontier else {
                throw CameraHistoryError.invalidResponse
            }
            if let localDestination, previous ? candidate.end <= localDestination.end : candidate.start >= localDestination.start { return nil }
            var cursor = previous ? candidate.end : candidate.start
            while previous ? cursor > candidate.start : cursor < candidate.end {
                try checkNavigation(deadline: deadline)
                guard remaining > 0 else { throw CameraHistoryError.tooLarge }
                remaining -= 1
                let chunk = CameraHistoryRange(start: previous ? max(candidate.start, cursor - 86_400) : cursor,
                    end: previous ? cursor : min(candidate.end, cursor + 86_400))
                let coverage: CameraHistoryBatch
                do {
                    // Playback gives local video precedence, including hidden
                    // local footage. Cloud destinations must fall in local gaps.
                    let probe = HBNVRMediaRequest(requestID: UUID().uuidString, operation: "availability", cameraID: request.cameraID,
                        timeline: request.timeline, range: .init(start: chunk.start, end: chunk.end))
                    coverage = try await local.fetch(probe)
                    guard coverage.unresolved.isEmpty, coverage.sourceWarning == nil,
                          coverage.range.start <= chunk.start, coverage.range.end >= chunk.end else { throw CameraHistoryError.unavailable }
                } catch {
                    try checkCancellation(error)
                    try checkNavigation(deadline: deadline)
                    // If the local source is offline, retain a cloud result with
                    // the local failure warning, just as cloud playback does.
                    if localSearchFailed { return candidate }
                    throw error
                }
                try checkNavigation(deadline: deadline)
                let gaps = coverage.gaps.compactMap { $0.intersection(chunk) }
                let available = previous ? gaps.max(by: { $0.end < $1.end }) : gaps.min(by: { $0.start < $1.start })
                if let available { return available }
                cursor = previous ? chunk.start : chunk.end
                if let localDestination, previous ? cursor <= localDestination.end : cursor >= localDestination.start { return nil }
            }
            let boundary = previous ? candidate.start : candidate.end
            guard previous ? boundary < frontier : boundary > frontier else { throw CameraHistoryError.invalidResponse }
            frontier = boundary
            guard remaining > 0 else { throw CameraHistoryError.tooLarge }
            remaining -= 1
            let query = CameraHistoryRange(start: previous ? boundary : boundary - 0.000_01,
                end: previous ? boundary + 0.000_01 : boundary)
            result = try await remote.neighbors(absolute(request, range: query), excludingHidden: true)
            guard result.neighbors != nil, result.sourceWarning == nil else { throw CameraHistoryError.unavailable }
        }
        return nil
    }
    func fetch(_ request: HBNVRMediaRequest, onBegin: CameraHistoryBeginHandler?) async throws -> CameraHistoryBatch {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let result: CameraHistoryBatch
        do { result = try await local.fetch(request, onBegin: onBegin) }
        catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? CameraHistoryFetchFailure)?.underlying is CancellationError {
                throw CancellationError()
            }
            guard !closed, let remote else { throw error }
            // A relative seek must first resolve on the NVR. Never mistake the
            // latest uploaded shard for Live or silently use the phone's clock.
            let failure = error as? CameraHistoryFetchFailure
            guard request.relativeTo == nil || failure?.anchor != nil else { throw error }
            let range = failure?.range ?? .init(start: request.range.start, end: request.range.end)
            var response: CameraHistoryBatch
            do { response = try await remote.fetch(absolute(request, range: range), onBegin: nil) }
            catch {
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                if error is CancellationError { throw error }
                // A failed cloud read must not lose the local server's resolved
                // Live-minus anchor. A retry remains the same absolute seek,
                // not a fresh relative request against a later live instant.
                if let anchor = failure?.anchor {
                    throw CameraHistoryFetchFailure(underlying: error, range: range, anchor: anchor)
                }
                throw error
            }
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            response = withAnchor(response, anchor: failure?.anchor)
            await onBegin?(response.range, response.anchor)
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            return response
        }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard let remote else { return result }
        if request.operation == "neighbors" {
            guard let nearby = result.neighbors else { return result }
            if nearby.previous != nil && nearby.next != nil { return result }
            let cloud: CameraHistoryBatch
            do { cloud = try await remote.fetch(absolute(request, range: result.range)) }
            catch {
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                if error is CancellationError { throw error }
                // A failed cloud lookup is not evidence that a valid local
                // neighbor disappeared, or that the unknown direction is empty.
                guard nearby.previous != nil || nearby.next != nil else { throw error }
                return .init(id: UUID(), range: result.range, anchor: result.anchor, pieces: [], gaps: [],
                    neighbors: nearby, sourceWarning: error.localizedDescription)
            }
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            return .init(id: UUID(), range: result.range, anchor: result.anchor, pieces: [], gaps: [],
                neighbors: .init(previous: [nearby.previous, cloud.neighbors?.previous].compactMap { $0 }.max { $0.end < $1.end },
                                 next: [nearby.next, cloud.neighbors?.next].compactMap { $0 }.min { $0.start < $1.start }))
        }
        guard request.operation == "frames", !result.gaps.isEmpty else { return result }
        var pieces = result.pieces, gaps: [CameraHistoryRange] = [], unresolved: [CameraHistoryRange] = []
        var warning: String?
        for gap in result.gaps {
            do {
                let cloud = try await remote.fetch(absolute(request, range: gap))
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                // Preserve the GOP for decoding, but never let its preroll
                // become a display candidate over successfully retrieved local
                // video (including when the renderer prefers this cloud piece).
                let bounded = cloud.pieces.compactMap { Self.selectable($0, onlyWithin: gap) }
                let combined = pieces + bounded
                guard combined.reduce(0, { $0 + $1.samples.reduce(0) { $0 + $1.data.count } }) <= 64 * 1024 * 1024,
                      combined.reduce(0, { $0 + $1.samples.count }) <= 30_000 else { throw CameraHistoryError.tooLarge }
                pieces = combined; gaps += cloud.gaps
            } catch {
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                if error is CancellationError { throw error }
                // Do not throw away successfully retrieved local video because
                // cloud credentials/network failed. But don't call that a gap.
                if pieces.isEmpty { throw CameraHistoryFetchFailure(underlying: error, range: result.range, anchor: result.anchor) }
                unresolved.append(gap); warning = error.localizedDescription
            }
        }
        return .init(id: UUID(), range: result.range, anchor: result.anchor, pieces: pieces,
                     gaps: CameraHistoryRange.merged(gaps), unresolved: unresolved, sourceWarning: warning)
    }
    private func absolute(_ request: HBNVRMediaRequest, range: CameraHistoryRange) -> HBNVRMediaRequest {
        .init(requestID: UUID().uuidString, operation: request.operation, cameraID: request.cameraID,
              timeline: request.timeline, range: .init(start: range.start, end: range.end))
    }
    private static func selectable(_ piece: CameraHistoryPiece, onlyWithin range: CameraHistoryRange) -> CameraHistoryPiece? {
        guard let selected = piece.segment.range.intersection(range) else { return nil }
        let old = piece.segment
        let segment = CameraHistorySegment(number: old.number, range: selected, time: old.time,
            timescale: old.timescale, codec: old.codec, parameterSets: old.parameterSets,
            nalUnitLengthBytes: old.nalUnitLengthBytes)
        return CameraHistoryPiece(id: piece.id, segment: segment, samples: piece.samples)
    }
    private func withAnchor(_ batch: CameraHistoryBatch, anchor: Double?) -> CameraHistoryBatch {
        .init(id: batch.id, range: batch.range, anchor: anchor, pieces: batch.pieces, gaps: batch.gaps,
              neighbors: batch.neighbors, unresolved: batch.unresolved, sourceWarning: batch.sourceWarning)
    }
}

@MainActor
enum CameraHistorySources {
    static func thumbnails(metadata: HBCameraPlaybackMetadata, client: HomeBaseWebSocketClient,
                           credentials: CameraS3Credentials?) async -> any CameraThumbnailFetching {
        let local = await client.makeHistoryTransport()
        guard let store = metadata.s3Store, store.playbackManifestVersion == 1,
              let credentials, credentials.destinationID == CameraS3Destination(store: store).id,
              let objects = try? CameraS3ObjectReader(destination: store, credentials: credentials) else { return local }
        return CameraThumbnailFallback(local: local, remote: CameraS3ThumbnailReader(store: store,
            cameraID: metadata.cameraID, password: credentials.encryptionPassword, objects: objects))
    }
    static func make(metadata: HBCameraPlaybackMetadata, client: HomeBaseWebSocketClient,
                     credentials: CameraS3Credentials?) async -> any CameraHistoryFetching {
        let local = await client.makeHistoryTransport()
        guard let store = metadata.s3Store, store.playbackManifestVersion == 1,
              let credentials, credentials.destinationID == CameraS3Destination(store: store).id else { return local }
        do {
            let objects = try CameraS3ObjectReader(destination: store, credentials: credentials)
            let remote = CameraS3HistoryReader(store: store, cameraID: metadata.cameraID,
                password: credentials.encryptionPassword, objects: objects)
            return CameraHistoryFallback(local: local, remote: remote)
        } catch {
            return CameraHistoryFallback(local: local, remote: CameraHistoryUnavailableSource(message: error.localizedDescription))
        }
    }
}

private actor CameraHistoryUnavailableSource: CameraHistoryFetching {
    let message: String
    init(message: String) { self.message = message }
    func start() {}
    func close() {}
    func neighbors(_ request: HBNVRMediaRequest, excludingHidden: Bool) async throws -> CameraHistoryBatch {
        try fetch(request, onBegin: nil)
    }
    func fetch(_ request: HBNVRMediaRequest, onBegin: CameraHistoryBeginHandler?) throws -> CameraHistoryBatch {
        throw CameraHistoryError.remote(nil, message)
    }
}
