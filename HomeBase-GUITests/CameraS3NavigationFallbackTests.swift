import Foundation
import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraS3NavigationFallbackTests: XCTestCase {
    private let camera = UUID().uuidString
    private let localVisible = [CameraHistoryRange(start: 0, end: 10), .init(start: 100, end: 110)]
    private let cloudVisible = [CameraHistoryRange(start: 20, end: 30), .init(start: 60, end: 70)]
    private func request(relative: Bool = false) -> HBNVRMediaRequest {
        .init(requestID: UUID().uuidString, operation: "neighbors", cameraID: camera, timeline: "canonical",
            range: .init(start: relative ? -950 : 50, end: relative ? -949.999 : 50.001), relativeTo: relative ? "live" : nil)
    }

    func testCloudIsComparedEvenWhenLocalHasBothDirections() async throws {
        let local = NavigationSource(visible: localVisible), cloud = NavigationSource(visible: cloudVisible)
        let fallback = CameraHistoryFallback(local: local, remote: cloud)
        let result = try await fallback.neighbors(request(), excludingHidden: true)
        XCTAssertEqual(result.neighbors, .init(previous: cloudVisible[0], next: cloudVisible[1]))
        XCTAssertNil(result.sourceWarning)
        let localRequests = await local.requests, cloudFilters = await cloud.filters
        XCTAssertEqual(localRequests.map(\.operation), ["neighbors", "availability", "availability"])
        XCTAssertEqual(cloudFilters, [true])
        await fallback.close()
    }

    func testCloudPublicCopiesCannotBypassHiddenLocalRecordings() async throws {
        let local = NavigationSource(visible: localVisible, recorded: localVisible + [.init(start: 40, end: 80)])
        let cloud = NavigationSource(visible: [.init(start: 20, end: 30), .init(start: 45, end: 60), .init(start: 80, end: 90)])
        let fallback = CameraHistoryFallback(local: local, remote: cloud)
        let result = try await fallback.neighbors(request(), excludingHidden: true)
        XCTAssertEqual(result.neighbors, .init(previous: .init(start: 20, end: 30), next: .init(start: 80, end: 90)))
        let filters = await cloud.filters
        XCTAssertEqual(filters, [true, true, true], "Every continuation preserves the hidden filter")
        await fallback.close()
    }

    func testCloudCandidateIsClippedToGapsInLocalCoverage() async throws {
        let local = NavigationSource(visible: localVisible,
            recorded: localVisible + [.init(start: 20, end: 35), .init(start: 65, end: 80)])
        let cloud = NavigationSource(visible: [.init(start: 20, end: 40), .init(start: 60, end: 90)])
        let fallback = CameraHistoryFallback(local: local, remote: cloud)
        let result = try await fallback.neighbors(request(), excludingHidden: true)
        XCTAssertEqual(result.neighbors, .init(previous: .init(start: 35, end: 40), next: .init(start: 60, end: 65)))
        await fallback.close()
    }

    func testOfflineLocalSourceKeepsCloudDestinationsWithAWarning() async throws {
        let local = NavigationSource(visible: [], neighborError: .unavailable, availabilityError: .unavailable)
        let cloud = NavigationSource(visible: cloudVisible)
        let fallback = CameraHistoryFallback(local: local, remote: cloud)
        let result = try await fallback.neighbors(request(), excludingHidden: true)
        XCTAssertEqual(result.neighbors, .init(previous: cloudVisible[0], next: cloudVisible[1]))
        XCTAssertNotNil(result.sourceWarning)
        await fallback.close()
    }

    func testRelativeFallbackRequiresAndPreservesServerAnchorAndHiddenFilter() async throws {
        for resolved in [false, true] {
            let local = NavigationSource(visible: [], neighborError: .unavailable, availabilityError: .unavailable,
                anchor: resolved ? 1000 : nil)
            let cloud = NavigationSource(visible: cloudVisible)
            let fallback = CameraHistoryFallback(local: local, remote: cloud)
            if resolved {
                let result = try await fallback.neighbors(request(relative: true), excludingHidden: true)
                XCTAssertEqual(result.anchor, 1000)
                XCTAssertEqual(result.range.start, 50, accuracy: 0.000_001)
                XCTAssertEqual(result.range.end, 50.001, accuracy: 0.000_001)
                XCTAssertEqual(result.neighbors, .init(previous: cloudVisible[0], next: cloudVisible[1]))
                let requests = await cloud.requests, filters = await cloud.filters
                XCTAssertEqual(requests.first?.range.start, 50)
                XCTAssertNil(requests.first?.relativeTo)
                XCTAssertEqual(filters, [true])
            } else {
                do { _ = try await fallback.neighbors(request(relative: true), excludingHidden: true); XCTFail("A cloud catalog cannot invent Live") }
                catch { XCTAssertEqual(error as? CameraHistoryError, .unavailable) }
                let requests = await cloud.requests
                XCTAssertTrue(requests.isEmpty)
            }
            await fallback.close()
        }
    }

    func testUnknownSourceAndEmptyKnownSourceNeverConfirmAnEmptyArchive() async throws {
        for localFails in [false, true] {
            let local = NavigationSource(visible: [], neighborError: localFails ? .unavailable : nil)
            let cloud = NavigationSource(visible: [], neighborError: localFails ? nil : .unavailable)
            let fallback = CameraHistoryFallback(local: local, remote: cloud)
            do { _ = try await fallback.neighbors(request(), excludingHidden: true); XCTFail("Unknown coverage must stay unknown") }
            catch { XCTAssertEqual(error as? CameraHistoryError, .unavailable) }
            await fallback.close()
        }
    }

    func testCancelledCloudLookupCannotBecomePartialSuccess() async throws {
        let local = NavigationSource(visible: localVisible), cloud = NavigationSource(visible: [], cancelLookup: true)
        let fallback = CameraHistoryFallback(local: local, remote: cloud)
        do { _ = try await fallback.neighbors(request(), excludingHidden: true); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fallback.close()
    }

    func testCancelledLocalLookupCannotReturnLateSuccessWithoutCloud() async throws {
        let local = NavigationSource(visible: localVisible, delay: .milliseconds(50))
        let fallback = CameraHistoryFallback(local: local, remote: nil)
        let task = Task { try await fallback.neighbors(request(), excludingHidden: true) }
        for _ in 0..<100 {
            if await !local.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("A late reply cannot escape cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fallback.close()
    }
}

private actor NavigationSource: CameraHistoryFetching {
    let visible: [CameraHistoryRange]
    let recorded: [CameraHistoryRange]
    let neighborError: CameraHistoryError?
    let availabilityError: CameraHistoryError?
    let anchor: Double?
    let cancelLookup: Bool
    let delay: Duration
    private(set) var requests: [HBNVRMediaRequest] = []
    private(set) var filters: [Bool] = []
    init(visible: [CameraHistoryRange], recorded: [CameraHistoryRange]? = nil,
         neighborError: CameraHistoryError? = nil, availabilityError: CameraHistoryError? = nil,
         anchor: Double? = nil, cancelLookup: Bool = false, delay: Duration = .zero) {
        self.visible = visible; self.recorded = recorded ?? visible
        self.neighborError = neighborError; self.availabilityError = availabilityError
        self.anchor = anchor; self.cancelLookup = cancelLookup
        self.delay = delay
    }
    func start() {}
    func close() {}
    func neighbors(_ request: HBNVRMediaRequest, excludingHidden: Bool) async throws -> CameraHistoryBatch {
        requests.append(request); filters.append(excludingHidden)
        try? await Task.sleep(for: delay)
        if cancelLookup { throw CancellationError() }
        let offset = request.relativeTo == nil ? 0 : (anchor ?? 0)
        let range = CameraHistoryRange(start: request.range.start + offset, end: request.range.end + offset)
        if let neighborError {
            if let anchor, request.relativeTo != nil { throw CameraHistoryFetchFailure(underlying: neighborError, range: range, anchor: anchor) }
            throw neighborError
        }
        let before = visible.compactMap { value -> CameraHistoryRange? in
            let end = min(value.end, range.start)
            return end > value.start ? .init(start: value.start, end: end) : nil
        }.max { $0.end < $1.end }
        let after = visible.compactMap { value -> CameraHistoryRange? in
            let start = max(value.start, range.end)
            return start < value.end ? .init(start: start, end: value.end) : nil
        }.min { $0.start < $1.start }
        return .init(id: UUID(), range: range, anchor: request.relativeTo == nil ? nil : anchor,
            pieces: [], gaps: [], neighbors: .init(previous: before, next: after))
    }
    func fetch(_ request: HBNVRMediaRequest, onBegin: CameraHistoryBeginHandler?) async throws -> CameraHistoryBatch {
        requests.append(request)
        XCTAssertEqual(request.operation, "availability", "Navigation must not fetch frame payloads")
        if let availabilityError { throw availabilityError }
        let range = CameraHistoryRange(start: request.range.start, end: request.range.end)
        return .init(id: UUID(), range: range, anchor: nil, pieces: [], gaps: range.subtracting(recorded))
    }
}
