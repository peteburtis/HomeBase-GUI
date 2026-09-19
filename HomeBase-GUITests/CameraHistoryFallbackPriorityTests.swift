import Foundation
import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraHistoryFallbackPriorityTests: XCTestCase {
    func testRemotePrerollCannotReplaceLocalSamplesEvenWhenPreferred() async throws {
        let local = piece(start: 100, end: 110, byte: 1)
        let remote = piece(start: 105, end: 120, byte: 2)
        let range = CameraHistoryRange(start: 100, end: 120)
        let fallback = CameraHistoryFallback(
            local: PrioritySource(batch: .init(id: UUID(), range: range, anchor: nil,
                pieces: [local], gaps: [.init(start: 110, end: 120)])),
            remote: PrioritySource(batch: .init(id: UUID(), range: .init(start: 110, end: 120), anchor: nil,
                pieces: [remote], gaps: [])))
        let batch = try await fallback.fetch(.init(requestID: UUID().uuidString, operation: "frames",
            cameraID: UUID().uuidString, timeline: "canonical", range: .init(start: 100, end: 120)))
        var buffer = CameraHistoryBuffer()
        buffer.insert(batch, at: 0, around: 110)
        let overlapping = try XCTUnwrap(buffer.location(at: 108, preferredPiece: remote.id))
        XCTAssertEqual(overlapping.piece.id, local.id)
        let cloud = try XCTUnwrap(buffer.location(at: 112, preferredPiece: remote.id))
        XCTAssertEqual(cloud.piece.id, remote.id)
        XCTAssertEqual(cloud.piece.segment.range.start, 110)
        XCTAssertEqual(cloud.piece.samples.first?.frame.presentationTicks, 105)
        XCTAssertEqual(cloud.piece.samples.first?.frame.keyFrame, true)
        XCTAssertEqual(cloud.piece.samples.map(\.data), remote.samples.map(\.data), "Clipping eligibility must retain decode-only GOP preroll")
        await fallback.close()
    }

    func testFailedCloudReadPreservesTheLocallyResolvedRelativeSeek() async throws {
        let resolved = CameraHistoryRange(start: 940, end: 970)
        let fallback = CameraHistoryFallback(local: FallbackFailureSource(.resolved(anchor: 1000, range: resolved)),
            remote: FallbackFailureSource(.unavailable))
        do {
            _ = try await fallback.fetch(.init(requestID: UUID().uuidString, operation: "frames", cameraID: UUID().uuidString,
                timeline: "canonical", range: .init(start: -60, end: -30), relativeTo: "live"))
            XCTFail("Expected cloud retrieval failure")
        } catch {
            let failure = try XCTUnwrap(error as? CameraHistoryFetchFailure)
            XCTAssertEqual(failure.range, resolved)
            XCTAssertEqual(failure.anchor, 1000)
            XCTAssertEqual(failure.underlying as? CameraHistoryError, .unavailable)
        }
        await fallback.close()
    }

    func testCancelledLocalRetrievalNeverStartsCloudRead() async throws {
        let range = CameraHistoryRange(start: 100, end: 120)
        let cloud = PrioritySource(batch: .init(id: UUID(), range: range, anchor: nil, pieces: [], gaps: [range]))
        let fallback = CameraHistoryFallback(local: FallbackFailureSource(.cancelled), remote: cloud)
        do {
            _ = try await fallback.fetch(absoluteRequest())
            XCTFail("Transport cancellation is not a local failure to bypass")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(Task.isCancelled, "Fixture returns cancellation independently of the calling task")
        let calls = await cloud.calls
        XCTAssertEqual(calls, 0)
        await fallback.close()
    }

    func testCancelledCloudRetrievalIsNotWrappedAsAnAnchoredFailure() async throws {
        let fallback = CameraHistoryFallback(
            local: FallbackFailureSource(.resolved(anchor: 1000, range: .init(start: 940, end: 970))),
            remote: FallbackFailureSource(.cancelled))
        do {
            _ = try await fallback.fetch(.init(requestID: UUID().uuidString, operation: "frames", cameraID: UUID().uuidString,
                timeline: "canonical", range: .init(start: -60, end: -30), relativeTo: "live"))
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        await fallback.close()
    }

    func testClosingDuringBeginCallbackRejectsTheAlreadyDownloadedResponse() async throws {
        let fallback = successfulRemoteFallback()
        do {
            _ = try await fallback.fetch(absoluteRequest(), onBegin: { _, _ in await fallback.close() })
            XCTFail("No response may escape a closed reader")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCancellingDuringBeginCallbackRejectsTheAlreadyDownloadedResponse() async throws {
        let fallback = successfulRemoteFallback(), request = absoluteRequest()
        let task = Task {
            try await fallback.fetch(request, onBegin: { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        do { _ = try await task.value; XCTFail("No response may escape a cancelled retrieval") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fallback.close()
    }

    func testCloudNeighborFailurePreservesTheKnownLocalDirectionWithWarning() async throws {
        let range = CameraHistoryRange(start: 100, end: 120)
        for previous in [true, false] {
            let nearby = CameraHistoryNeighbors(previous: previous ? .init(start: 90, end: 100) : nil,
                next: previous ? nil : .init(start: 120, end: 130))
            let fallback = CameraHistoryFallback(local: PrioritySource(batch: .init(id: UUID(), range: range,
                anchor: nil, pieces: [], gaps: [], neighbors: nearby)), remote: FallbackFailureSource(.unavailable))
            let result = try await fallback.fetch(absoluteRequest(operation: "neighbors"))
            XCTAssertEqual(result.neighbors, nearby)
            XCTAssertNotNil(result.sourceWarning, "An unknown cloud direction must not be reported as a confirmed archive end")
            await fallback.close()
        }
    }

    func testCloudNeighborFailureWithNoKnownLocalDirectionRemainsAnError() async throws {
        let range = CameraHistoryRange(start: 100, end: 120)
        let fallback = CameraHistoryFallback(local: PrioritySource(batch: .init(id: UUID(), range: range,
            anchor: nil, pieces: [], gaps: [], neighbors: .init(previous: nil, next: nil))),
            remote: FallbackFailureSource(.unavailable))
        do { _ = try await fallback.fetch(absoluteRequest(operation: "neighbors")); XCTFail("Both unknown directions must remain unknown") }
        catch { XCTAssertEqual(error as? CameraHistoryError, .unavailable) }
        await fallback.close()
    }

    func testCancelledCloudNeighborLookupDoesNotBecomeAPartialSuccess() async throws {
        let range = CameraHistoryRange(start: 100, end: 120)
        let fallback = CameraHistoryFallback(local: PrioritySource(batch: .init(id: UUID(), range: range,
            anchor: nil, pieces: [], gaps: [], neighbors: .init(previous: .init(start: 90, end: 100), next: nil))),
            remote: FallbackFailureSource(.cancelled))
        do { _ = try await fallback.fetch(absoluteRequest(operation: "neighbors")); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fallback.close()
    }

    func testCancelledCloudGapReadDoesNotBecomeAPartialSuccess() async throws {
        let range = CameraHistoryRange(start: 100, end: 120)
        let fallback = CameraHistoryFallback(local: PrioritySource(batch: .init(id: UUID(), range: range,
            anchor: nil, pieces: [piece(start: 100, end: 110, byte: 1)], gaps: [.init(start: 110, end: 120)])),
            remote: FallbackFailureSource(.cancelled))
        do { _ = try await fallback.fetch(absoluteRequest()); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fallback.close()
    }

    private func absoluteRequest(operation: String = "frames") -> HBNVRMediaRequest {
        .init(requestID: UUID().uuidString, operation: operation, cameraID: UUID().uuidString,
            timeline: "canonical", range: .init(start: 100, end: 120))
    }
    private func successfulRemoteFallback() -> CameraHistoryFallback {
        let range = CameraHistoryRange(start: 100, end: 120)
        return CameraHistoryFallback(local: FallbackFailureSource(.unavailable),
            remote: PrioritySource(batch: .init(id: UUID(), range: range, anchor: nil,
                pieces: [piece(start: 100, end: 120, byte: 2)], gaps: [])))
    }

    private func piece(start: Int, end: Int, byte: UInt8) -> CameraHistoryPiece {
        let segment = CameraHistorySegment(number: 0, range: .init(start: Double(start), end: Double(end)),
            time: .init(canonicalUTC: 0, receivedUTC: 0, cameraUTC: nil, canonicalSource: "received", epochID: UUID().uuidString),
            timescale: 1, codec: "H264", parameterSets: [Data([1]), Data([2])], nalUnitLengthBytes: 4)
        return .init(id: UUID(), segment: segment, samples: (start..<end).map {
            .init(frame: .init(segment: 0, presentationTicks: Int64($0), decodeTicks: nil, durationTicks: 1,
                keyFrame: $0 == start, preroll: $0 < 110, byteCount: 1), data: Data([byte]))
        })
    }
}

private actor PrioritySource: CameraHistoryFetching {
    let batch: CameraHistoryBatch
    private(set) var calls = 0
    init(batch: CameraHistoryBatch) { self.batch = batch }
    func start() {}
    func close() {}
    func fetch(_ request: HBNVRMediaRequest, onBegin: CameraHistoryBeginHandler?) async throws -> CameraHistoryBatch {
        calls += 1; return batch
    }
}

private actor FallbackFailureSource: CameraHistoryFetching {
    enum Failure: Sendable { case unavailable, cancelled, resolved(anchor: Double, range: CameraHistoryRange) }
    let failure: Failure
    init(_ failure: Failure) { self.failure = failure }
    func start() {}
    func close() {}
    func fetch(_ request: HBNVRMediaRequest, onBegin: CameraHistoryBeginHandler?) async throws -> CameraHistoryBatch {
        switch failure {
        case .unavailable: throw CameraHistoryError.unavailable
        case .cancelled: throw CancellationError()
        case .resolved(let anchor, let range):
            await onBegin?(range, anchor)
            throw CameraHistoryFetchFailure(underlying: CameraHistoryError.unavailable, range: range, anchor: anchor)
        }
    }
}
