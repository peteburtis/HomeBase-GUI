import Foundation
import AVFoundation
import VideoToolbox
import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraHistoryTests: XCTestCase {
    let camera = UUID().uuidString

    func testHistorySuspensionPreservesPausedPositionAndCacheThroughReconnect() async throws {
        for initiallyPaused in [false, true] {
            let controller = CameraLivePlaybackController()
            defer { controller.close() }
            controller.setNVRHistoryAvailable(true)
            controller.history.configure(cameraID: camera, transport: HistoryFetcher())
            controller.seek(to: Date(timeIntervalSince1970: 940), paused: initiallyPaused)
            try await settled(controller.history)
            let cursor = controller.history.position
            let batches = controller.history.buffer.batches.map(\.batch.id)
            controller.suspend(); controller.suspend()
            XCTAssertTrue(controller.isPaused)
            controller.history.advance(by: 600)
            XCTAssertEqual(controller.history.position, cursor)
            controller.resume()
            controller.history.configure(cameraID: camera, transport: HistoryFetcher())
            try await settled(controller.history)
            controller.history.advance(by: 60)
            XCTAssertTrue(controller.isPaused)
            XCTAssertTrue(controller.isUsingHistory)
            XCTAssertEqual(controller.history.position, cursor)
            XCTAssertEqual(controller.history.buffer.batches.map(\.batch.id), batches)
            controller.togglePause()
            XCTAssertFalse(controller.isPaused)
        }
    }

    func testSuspendingPendingCalendarSeekKeepsItsTargetPaused() async throws {
        let controller = CameraLivePlaybackController()
        defer { controller.close() }
        controller.setNVRHistoryAvailable(true)
        controller.history.configure(cameraID: camera, transport: HistoryFetcher(delay: .milliseconds(50)))
        controller.seek(to: Date(timeIntervalSince1970: 940), paused: false)
        controller.suspend()
        XCTAssertTrue(controller.isPaused)
        XCTAssertEqual(controller.history.position, 940)
        controller.resume()
        controller.history.configure(cameraID: camera, transport: HistoryFetcher())
        try await settled(controller.history)
        XCTAssertTrue(controller.isPaused)
        XCTAssertEqual(controller.history.position, 940)
    }

    func testGapFindsNeighborsAndControllerJumpsWithoutChangingPauseState() async throws {
        let neighbors = CameraHistoryNeighbors(previous: .init(start: 100, end: 160), next: .init(start: 800, end: 860))
        for paused in [true, false] {
            let controller = CameraLivePlaybackController()
            controller.setNVRHistoryAvailable(true)
            controller.history.configure(cameraID: camera, transport: HistoryFetcher(unavailable: true, neighbors: neighbors))
            controller.history.enter(canonicalTime: 500, localHead: 0, paused: paused)
            try await settled(controller.history)
            XCTAssertEqual(controller.historyNavigation, .ready(neighbors))
            controller.seekToAdjacentRecording(previous: true)
            XCTAssertEqual(controller.playbackDate, Date(timeIntervalSince1970: 100))
            XCTAssertEqual(controller.isPaused, paused)
            XCTAssertFalse(controller.isLive)
            controller.close()
        }
    }

    func testGapNavigationMissingDirectionsAndStaleResponses() async throws {
        let neighbors = CameraHistoryNeighbors(previous: nil, next: .init(start: 800, end: 860))
        let fetcher = HistoryFetcher(delay: .milliseconds(20), unavailable: true, neighbors: neighbors)
        let history = CameraHistoryPlayback()
        history.configure(cameraID: camera, transport: fetcher)
        history.enter(canonicalTime: 500, localHead: 0, paused: true)
        try await settled(history)
        XCTAssertNil(history.adjacentRecording(previous: true))
        XCTAssertEqual(history.adjacentRecording(previous: false), Date(timeIntervalSince1970: 800))
        history.retry()
        try await Task.sleep(for: .milliseconds(5))
        history.deactivate()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(history.navigation, .idle)
        XCTAssertNil(history.adjacentRecording(previous: false))
        history.close()
    }

    func testNeighborFailureIsNotEvidenceOfAnEmptyArchive() async throws {
        let history = CameraHistoryPlayback()
        history.configure(cameraID: camera, transport: HistoryFetcher(unavailable: true, neighborError: .unavailable))
        history.enter(canonicalTime: 500, localHead: 0, paused: true)
        try await settled(history)
        XCTAssertEqual(history.state, .gap)
        guard case .failed = history.navigation else { return XCTFail("Failure must not disable both directions as known archive ends") }
        history.close()
    }

    func testPausedArchiveEndRefreshesWithoutMovingCursor() async throws {
        var now = 0.0
        let history = CameraHistoryPlayback(clock: { now })
        let fetcher = HistoryFetcher(unavailable: true)
        history.configure(cameraID: camera, transport: fetcher)
        history.enter(canonicalTime: 500, localHead: 0, paused: true)
        try await settled(history)
        XCTAssertEqual(history.navigation, .ready(.init(previous: nil, next: nil)))
        now = 5
        // Exercise the same refresh path as the gap timer, without a wall-clock wait.
        history.advance(by: 0)
        try await settled(history)
        let queries = await fetcher.requests.filter { $0.operation == "neighbors" }
        XCTAssertEqual(queries.count, 2)
        XCTAssertEqual(history.position, 500)
        XCTAssertTrue(history.isPaused)
        history.close()
    }

    func testForwardAdjacentJumpPreservesPauseAndKeepsHistory() async throws {
        let controller = CameraLivePlaybackController()
        controller.setNVRHistoryAvailable(true)
        controller.history.configure(cameraID: camera, transport: HistoryFetcher(unavailable: true,
            neighbors: .init(previous: nil, next: .init(start: 800, end: 860))))
        controller.history.enter(canonicalTime: 500, localHead: 0, paused: true)
        try await settled(controller.history)
        controller.seekToAdjacentRecording(previous: false)
        XCTAssertEqual(controller.playbackDate, Date(timeIntervalSince1970: 800))
        XCTAssertTrue(controller.isPaused)
        XCTAssertTrue(controller.isUsingHistory)
        controller.close()
    }

    func testNeighborParserRequiresCompleteReplyAndValidDirectionalRanges() throws {
        let request = HBNVRMediaRequest(requestID: "near", operation: "neighbors", cameraID: camera,
            timeline: "canonical", range: .init(start: 100, end: 102))
        var parser = CameraHistoryResponseParser(request: request)
        try begin(&parser, request)
        XCTAssertThrowsError(try parser.text(json(["type": "end", "requestID": "near", "outcome": "complete", "frames": 0])))
        XCTAssertThrowsError(try parser.text(json(["type": "neighbors", "requestID": "near", "neighbors": ["previous": ["start": 99, "end": 101]]])))
        try parser.text(json(["type": "neighbors", "requestID": "near", "neighbors": ["next": ["start": 200, "end": 260]]]))
        XCTAssertNil(parser.result)
        XCTAssertThrowsError(try parser.text(json(["type": "neighbors", "requestID": "near", "neighbors": [:]])))
        try parser.text(json(["type": "end", "requestID": "near", "outcome": "complete", "frames": 0]))
        XCTAssertEqual(parser.result?.neighbors, .init(previous: nil, next: .init(start: 200, end: 260)))
        XCTAssertTrue(parser.result?.gaps.isEmpty == true)
    }

    func testOlderServerDoesNotReceiveUnsupportedNeighborRequest() async throws {
        let socket = HistorySocket()
        let transport = CameraHistoryTransport(makeSocket: { socket })
        let request = HBNVRMediaRequest(requestID: "near", operation: "neighbors", cameraID: camera,
            range: .init(start: 100, end: 102))
        do { _ = try await transport.fetch(request); XCTFail("Expected capability error") }
        catch { XCTAssertEqual(error as? CameraHistoryError, .neighborsUnsupported) }
        let operations = await socket.core.operations
        XCTAssertFalse(operations.contains("neighbors"))
        _ = try await transport.fetch(self.request())
        await transport.close()
    }

    func testLoadingTimestampIsGregorian24HourAndUsesHistoricalServerZoneRules() throws {
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let home = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let parser = ISO8601DateFormatter()
        let winter = try XCTUnwrap(parser.date(from: "2026-01-02T03:04:05Z"))
        let summer = try XCTUnwrap(parser.date(from: "2026-07-02T03:04:05Z"))
        let yearBoundary = try XCTUnwrap(parser.date(from: "2021-01-01T00:00:00Z"))
        XCTAssertEqual(CameraHistoryTimestamp.string(for: winter, timeZone: utc), "2026-01-02 03:04:05")
        XCTAssertEqual(CameraHistoryTimestamp.string(for: winter, timeZone: home), "2026-01-01 19:04:05")
        XCTAssertEqual(CameraHistoryTimestamp.string(for: summer, timeZone: home), "2026-07-01 20:04:05")
        XCTAssertEqual(CameraHistoryTimestamp.string(for: yearBoundary, timeZone: utc), "2021-01-01 00:00:00")
    }

    func testPlaybackTimeZoneUsesMetadataWithSafeFallbackForOlderOrInvalidServers() throws {
        let fallback = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        for identifier in [nil, "not/a/time-zone", "America/Los_Angeles"] as [String?] {
            let capability = HBCameraPlaybackMetadata(nvrInstanceID: UUID().uuidString, cameraID: camera,
                stores: [.init(id: UUID().uuidString, name: "Local")], timeZoneIdentifier: identifier)
            let metadata = [HBDeviceMetadataKeys.cameraPlayback: try HBJSONValue(encoding: capability)]
            let zone = CameraHistoryTimestamp.timeZone(in: metadata, fallback: fallback)
            XCTAssertEqual(zone.identifier, identifier == "America/Los_Angeles" ? identifier : fallback.identifier)
        }
        XCTAssertEqual(CameraHistoryTimestamp.timeZone(in: [:], fallback: fallback), fallback)
    }

    func testRelativeLoadingTimestampResolvesBeforeVideoCompletesAndUsesSeekPoint() async throws {
        let history = CameraHistoryPlayback()
        history.configure(cameraID: camera, transport: HistoryFetcher(delay: .milliseconds(200)))
        history.enter(localPosition: -60, localHead: 0, paused: true)
        XCTAssertNil(history.loadingDate, "Do not guess an absolute time before the NVR resolves it")
        for _ in 0..<100 {
            if history.loadingDate != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(history.loadingDate, Date(timeIntervalSince1970: 940))
        XCTAssertTrue(history.fetching)
        XCTAssertNil(history.position, "Early presentation metadata must not start playback")
        XCTAssertTrue(history.buffer.batches.isEmpty)
        try await settled(history)
        XCTAssertNil(history.loadingDate)
        XCTAssertEqual(history.position, 940)
        history.close()
    }

    func testStaleRelativeBeginCannotReplaceNewSeekLoadingTimestamp() async throws {
        let history = CameraHistoryPlayback()
        var displayed: [Date] = []
        history.changed = { if let date = history.loadingDate { displayed.append(date) } }
        history.configure(cameraID: camera, transport: HistoryFetcher(delay: .milliseconds(30), beginDelay: .milliseconds(30)))
        history.enter(localPosition: -60, localHead: 0, paused: true)
        try await Task.sleep(for: .milliseconds(5))
        history.seek(by: -30)
        try await settled(history)
        XCTAssertFalse(displayed.contains(Date(timeIntervalSince1970: 940)))
        XCTAssertTrue(displayed.contains(Date(timeIntervalSince1970: 910)))
        XCTAssertEqual(history.position, 910)
        history.close()
    }

    func testControllerPublishesCalendarLoadingDateImmediatelyAndChangesItBetweenSeeks() async throws {
        let controller = CameraLivePlaybackController()
        controller.setNVRHistoryAvailable(true)
        controller.history.configure(cameraID: camera, transport: HistoryFetcher(delay: .milliseconds(30), unavailable: true))
        controller.seek(to: Date(timeIntervalSince1970: 500))
        XCTAssertEqual(controller.loadingHistoryDate, Date(timeIntervalSince1970: 500))
        controller.seek(to: Date(timeIntervalSince1970: 400))
        XCTAssertEqual(controller.loadingHistoryDate, Date(timeIntervalSince1970: 400))
        try await settled(controller.history)
        XCTAssertNil(controller.loadingHistoryDate)
        controller.goLive()
        XCTAssertNil(controller.loadingHistoryDate)
        controller.close()
    }

    func testTransportReportsValidatedBeginBeforeReadingEnd() async throws {
        let socket = HistorySocket(), probe = HistoryBeginProbe()
        let transport = CameraHistoryTransport(makeSocket: { socket })
        _ = try await transport.fetch(request(), onBegin: { range, _ in
            await probe.record(range, remaining: socket.core.bufferedMessageCount)
        })
        let ranges = await probe.ranges, remaining = await probe.remaining
        XCTAssertEqual(ranges, [.init(start: 100, end: 102)])
        XCTAssertEqual(remaining, [1], "The End record should still be unread at the Begin callback")
        await transport.close()
    }

    func testTimelineVisibilityDoesNotChangeCameraControlsOrSpeedAvailability() {
        for live in [true, false] {
            for timeline in [true, false] {
                let presentation = CameraPlaybackControlsPresentation(isLive: live, timelineVisible: timeline)
                XCTAssertEqual(presentation.cameraControlsEnabled, live)
                XCTAssertEqual(presentation.showsPlaybackSpeed, !live)
            }
        }
    }

    func testDateSelectionPreservesAnAbsoluteInstantAndClampsFutureDefault() {
        let date = Date(timeIntervalSince1970: 1_700_000_123)
        let latest = date.addingTimeInterval(60)
        XCTAssertEqual(CameraHistoryDateSelection(date: date, latestDate: latest).date, date)
        XCTAssertEqual(CameraHistoryDateSelection(date: latest.addingTimeInterval(60), latestDate: latest).date, latest)
    }

    func testFirstCalendarJumpResolvesServerEdgeThenFetchesExactAbsoluteMinute() async throws {
        let fetcher = HistoryFetcher(), history = CameraHistoryPlayback()
        history.configure(cameraID: camera, transport: fetcher)
        history.enter(canonicalTime: 500, localHead: 12, paused: true)
        try await settled(history)
        let requests = await fetcher.requests
        XCTAssertEqual(requests.map(\.operation), ["availability", "frames"])
        XCTAssertEqual(requests[0].relativeTo, "live")
        XCTAssertEqual(requests[0].range, .init(start: -1, end: 0))
        XCTAssertNil(requests[1].relativeTo)
        XCTAssertEqual(requests[1].timeline, "canonical")
        XCTAssertEqual(requests[1].range, .init(start: 470, end: 530))
        XCTAssertEqual(history.position, 500)
        XCTAssertEqual(history.canonicalOffset, 988)
        XCTAssertEqual(history.state, .ready)
        XCTAssertTrue(history.isPaused)
        XCTAssertEqual(history.buffer.batches.count, 1, "The availability probe is not playable cache coverage")
        history.close()
    }

    func testCalendarJumpOnStoppedCameraFallsBackToServerNowAndShowsExistingGap() async throws {
        let fetcher = HistoryFetcher(rejectLive: true, unavailable: true), history = CameraHistoryPlayback()
        history.configure(cameraID: camera, transport: fetcher)
        history.enter(canonicalTime: 500, localHead: 0, paused: false)
        try await settled(history)
        let requests = await fetcher.requests
        XCTAssertEqual(requests.map(\.operation), ["availability", "availability", "frames", "neighbors"])
        XCTAssertEqual(requests.map(\.relativeTo), ["live", "now", nil, nil])
        XCTAssertEqual(history.position, 500)
        XCTAssertEqual(history.state, .gap)
        XCTAssertFalse(history.isPaused)
        history.advance(by: 1)
        XCTAssertEqual(history.position, 501)
        history.close()
    }

    func testCalendarJumpReusesAnchorAndCacheAndKeepsPauseState() async throws {
        let fetcher = HistoryFetcher(), history = CameraHistoryPlayback()
        history.configure(cameraID: camera, transport: fetcher)
        history.enter(localPosition: -60, localHead: 0, paused: true)
        try await settled(history)
        history.enter(canonicalTime: 940, localHead: 0, paused: true)
        XCTAssertFalse(history.fetching)
        XCTAssertTrue(history.isPaused)
        history.enter(canonicalTime: 500, localHead: 0, paused: false)
        try await settled(history)
        let requests = await fetcher.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.range, .init(start: 470, end: 530))
        XCTAssertNil(requests.last?.relativeTo)
        XCTAssertEqual(history.canonicalOffset, 1000)
        XCTAssertFalse(history.isPaused)
        history.close()
    }

    func testCalendarSeekSupersedesPendingRelativeSeekAndAnotherPendingCalendarSeek() async throws {
        let fetcher = HistoryFetcher(delay: .milliseconds(30)), history = CameraHistoryPlayback()
        history.configure(cameraID: camera, transport: fetcher)
        history.enter(localPosition: -60, localHead: 0, paused: true)
        try await Task.sleep(for: .milliseconds(5))
        history.enter(canonicalTime: 500, localHead: 0, paused: true)
        try await Task.sleep(for: .milliseconds(5))
        history.seek(by: -30)
        try await settled(history)
        XCTAssertEqual(history.position, 470)
        XCTAssertEqual(history.state, .ready)
        XCTAssertEqual(history.buffer.batches.count, 1)
        let requests = await fetcher.requests
        XCTAssertEqual(requests.last?.range, .init(start: 440, end: 500))
        history.close()
    }

    func testInterruptedCalendarAnchorRetainsDateForAbsoluteRetry() async throws {
        let fetcher = HistoryFetcher(interruptFirstAfterBegin: true), history = CameraHistoryPlayback()
        history.configure(cameraID: camera, transport: fetcher)
        history.enter(canonicalTime: 500, localHead: 0, paused: true)
        try await settled(history)
        let requests = await fetcher.requests
        XCTAssertEqual(requests.map(\.operation), ["availability", "frames"])
        XCTAssertEqual(requests.last?.range, .init(start: 470, end: 530))
        XCTAssertEqual(history.position, 500)
        XCTAssertEqual(history.state, .ready)
        history.close()
    }

    func testCalendarJumpClampsAtServerLiveEdgeRatherThanPhoneTime() async throws {
        let fetcher = HistoryFetcher(), history = CameraHistoryPlayback()
        history.configure(cameraID: camera, transport: fetcher)
        history.enter(canonicalTime: 2000, localHead: 0, paused: true)
        try await settled(history)
        XCTAssertEqual(history.position!, 1000, accuracy: 0.001)
        let requests = await fetcher.requests
        XCTAssertEqual(requests.last!.range.end, 1000)
        XCTAssertTrue(history.isPaused)
        history.close()
    }

    func testControllerCalendarJumpWorksWithoutLiveFramesAndRequiresHistoryCapability() async throws {
        let controller = CameraLivePlaybackController()
        controller.history.configure(cameraID: camera, transport: HistoryFetcher(unavailable: true))
        controller.seek(to: Date(timeIntervalSince1970: 500))
        XCTAssertTrue(controller.isLive)
        XCTAssertFalse(controller.history.fetching)
        controller.setNVRHistoryAvailable(true)
        controller.seek(to: Date(timeIntervalSince1970: 500))
        try await settled(controller.history)
        XCTAssertTrue(controller.isUsingHistory)
        XCTAssertTrue(controller.canControlPlayback)
        XCTAssertEqual(controller.historyState, .gap)
        XCTAssertEqual(controller.playbackDate?.timeIntervalSince1970 ?? 0, 500, accuracy: 1)
        controller.togglePause()
        controller.seek(to: Date(timeIntervalSince1970: 400))
        try await settled(controller.history)
        XCTAssertTrue(controller.isPaused)
        XCTAssertEqual(controller.playbackDate, Date(timeIntervalSince1970: 400))
        controller.close()
    }

    func testAvailabilityParserAcceptsCoverageWithoutFramesAndRejectsItOnFrameRequests() throws {
        let request = HBNVRMediaRequest(requestID: UUID().uuidString, operation: "availability", cameraID: camera,
            timeline: "canonical", range: .init(start: -1, end: 0), relativeTo: "live")
        var parser = CameraHistoryResponseParser(request: request)
        try parser.text(json(["type": "begin", "requestID": request.requestID, "cameraID": camera,
                              "timeline": "canonical", "range": ["start": 999, "end": 1000], "anchor": 1000]))
        try parser.text(json(["type": "available", "requestID": request.requestID, "range": ["start": 999, "end": 1000]]))
        try parser.text(json(["type": "end", "requestID": request.requestID, "outcome": "complete", "frames": 0]))
        XCTAssertEqual(parser.result?.anchor, 1000)
        XCTAssertEqual(parser.result?.frameCount, 0)
        XCTAssertEqual(parser.result?.gaps, [])
        let frames = self.request()
        var frameParser = CameraHistoryResponseParser(request: frames)
        try begin(&frameParser, frames)
        XCTAssertThrowsError(try frameParser.text(json(["type": "available", "requestID": frames.requestID,
            "range": ["start": 100, "end": 102]])))
    }
    func testMetadataSnapshotDoesNotOverwriteNewerEventsOrReplayOlderOnes() {
        var observation = DeviceMetadataObservation()
        XCTAssertFalse(observation.apply(key: "cameraPlayback", value: .string("old"), sequence: 10))
        observation.install(["cameraPlayback": .string("snapshot")], at: 11)
        XCTAssertEqual(observation.metadata["cameraPlayback"], .string("snapshot"))
        XCTAssertTrue(observation.apply(key: "cameraPlayback", value: .string("new"), sequence: 12))
        XCTAssertFalse(observation.apply(key: "cameraPlayback", value: .string("stale"), sequence: 11))
        XCTAssertEqual(observation.metadata["cameraPlayback"], .string("new"))
        var racing = DeviceMetadataObservation()
        _ = racing.apply(key: "cameraPlayback", value: .string("newer than snapshot"), sequence: 20)
        racing.install(["cameraPlayback": .string("snapshot")], at: 19)
        XCTAssertEqual(racing.metadata["cameraPlayback"], .string("newer than snapshot"))
    }
    func testWindowAndRefillPolicy() {
        XCTAssertEqual(CameraHistoryPolicy.initialWindow(at: 100, liveEdge: 1000), .init(start: 70, end: 130))
        XCTAssertEqual(CameraHistoryPolicy.initialWindow(at: -10, liveEdge: 0), .init(start: -40, end: 0))
        XCTAssertNil(CameraHistoryPolicy.refill(at: 100, knownEnd: 120, liveEdge: 1000))
        XCTAssertEqual(CameraHistoryPolicy.refill(at: 100, knownEnd: 119.9, liveEdge: 1000), .init(start: 119.9, end: 149.9))
        XCTAssertNil(CameraHistoryPolicy.refill(at: 990, knownEnd: 1000, liveEdge: 1000))
        XCTAssertEqual(CameraHistoryPolicy.refill(at: 100, knownEnd: 130, liveEdge: 1000, speed: .double),
            .init(start: 130, end: 190))
        XCTAssertEqual(CameraHistoryPolicy.refill(at: 100, knownEnd: 179, liveEdge: 1000, speed: .quadruple),
            .init(start: 179, end: 299))
        XCTAssertNil(CameraHistoryPolicy.refill(at: 100, knownEnd: 180, liveEdge: 1000, speed: .quadruple))
        XCTAssertEqual(CameraHistoryPolicy.refill(at: 900, knownEnd: 950, liveEdge: 1000, speed: .quadruple),
            .init(start: 950, end: 1000))
    }

    func testHistoryCatchUpResetsSpeedButKeepsHistoryAndFollowsNewFootage() async throws {
        var now = 0.0
        let controller = CameraLivePlaybackController(clock: { now })
        defer { controller.close() }
        controller.setNVRHistoryAvailable(true)
        // Confirmed gaps avoid involving a synthetic decoder in clock tests.
        controller.history.configure(cameraID: camera, transport: HistoryFetcher(unavailable: true))
        controller.seek(to: Date(timeIntervalSince1970: 995), paused: true)
        try await settled(controller.history)
        controller.setPlaybackSpeed(.quadruple)
        controller.togglePause()
        now = 1; controller.tick()
        XCTAssertEqual(controller.history.position, 999)
        XCTAssertEqual(controller.playbackSpeed, .quadruple)
        now = 2; controller.tick()
        XCTAssertEqual(controller.playbackSpeed, .normal)
        XCTAssertTrue(controller.isUsingHistory)
        XCTAssertFalse(controller.isLive)
        XCTAssertFalse(controller.isPaused)
        controller.history.updateLiveHead(10)
        controller.history.advance(by: 0)
        try await settled(controller.history)
        let position = try XCTUnwrap(controller.history.position)
        now += 0.25; controller.tick()
        XCTAssertEqual(try XCTUnwrap(controller.history.position), position + 0.25, accuracy: 0.000_001)
    }

    func testHistoryDownloadBoundaryDoesNotResetSpeedAndRequestsStayBounded() async throws {
        var now = 0.0
        let controller = CameraLivePlaybackController(clock: { now })
        defer { controller.close() }
        let transport = HistoryFetcher(delay: .milliseconds(20), unavailable: true)
        controller.setNVRHistoryAvailable(true)
        controller.history.configure(cameraID: camera, transport: transport)
        controller.seek(to: Date(timeIntervalSince1970: 500), paused: true)
        try await settled(controller.history)
        controller.setPlaybackSpeed(.quadruple)
        controller.togglePause()
        now = 10; controller.tick()
        XCTAssertEqual(controller.history.position, 530, "Do not run ahead through unloaded history")
        XCTAssertEqual(controller.playbackSpeed, .quadruple, "A cache boundary is not the live edge")
        XCTAssertTrue(controller.isUsingHistory)
        try await settled(controller.history)
        let requests = await transport.requests.filter { $0.operation == "frames" }
        XCTAssertTrue(requests.allSatisfy { $0.range.end - $0.range.start <= 60 })
        XCTAssertGreaterThan(requests.count, 2, "4× prefetch splits its larger goal into bounded requests")
    }

    func testCacheRequestsOnlyMissingIntervalsAndExpiresProvisionalGaps() {
        var cache = CameraHistoryBuffer()
        cache.insert(historyBatch(start: 100, end: 160, gaps: [.init(start: 130, end: 140)]), at: 0, around: 130)
        XCTAssertEqual(cache.missing(.init(start: 90, end: 170), now: 1, liveEdge: 160),
                       [.init(start: 90, end: 100), .init(start: 160, end: 170)])
        XCTAssertEqual(cache.missing(.init(start: 100, end: 160), now: 5, liveEdge: 160), [.init(start: 130, end: 140)])
        XCTAssertTrue(cache.missing(.init(start: 100, end: 160), now: 5, liveEdge: 1000).isEmpty)
        XCTAssertEqual(cache.missing(.init(start: 100, end: 160), now: 60, liveEdge: 1000), [.init(start: 130, end: 140)])
        XCTAssertNil(cache.location(at: 135))
        XCTAssertNotNil(cache.location(at: 129.5))
    }

    func testCacheKeepsWholeDecoderPiecesAndBoundsBytesFramesAndTime() {
        var cache = CameraHistoryBuffer(maximumBytes: 650, maximumDuration: 300, maximumFrames: 130)
        for start in stride(from: 0, to: 600, by: 60) {
            cache.insert(historyBatch(start: Double(start), end: Double(start + 60)), at: 0, around: Double(start + 30))
            XCTAssertLessThanOrEqual(cache.bytes, 650)
            XCTAssertLessThanOrEqual(cache.frameCount, 130)
            XCTAssertNotNil(cache.location(at: Double(start + 30)))
        }
        XCTAssertNil(cache.location(at: 0))
        var small = CameraHistoryBuffer(maximumBytes: 1)
        small.insert(historyBatch(start: 0, end: 1), at: 0, around: 0)
        XCTAssertTrue(small.batches.isEmpty)
    }

    func testOverlappingRequestsDoNotConfuseRequestLocalSegmentNumbers() {
        var cache = CameraHistoryBuffer()
        let first = historyBatch(start: 0, end: 60), next = historyBatch(start: 50, end: 90)
        cache.insert(first, at: 0, around: 55); cache.insert(next, at: 1, around: 55)
        XCTAssertNotEqual(first.pieces[0].id, next.pieces[0].id)
        XCTAssertEqual(cache.location(at: 55, preferredPiece: first.pieces[0].id)?.piece.id, first.pieces[0].id)
        XCTAssertEqual(cache.location(at: 65, preferredPiece: first.pieces[0].id)?.piece.id, next.pieces[0].id)
    }

    func testParserCorrelatesRecordsAssemblesChunksAndRequiresEnd() throws {
        let request = request()
        var parser = CameraHistoryResponseParser(request: request)
        try begin(&parser, request)
        let segment = historyBatch(start: 100, end: 102).pieces[0].segment
        try parser.text(json(["type": "segment", "requestID": request.requestID, "segment": try object(segment)]))
        let frame = CameraHistoryFrame(segment: 0, presentationTicks: 0, decodeTicks: nil, durationTicks: 1,
                                      keyFrame: true, preroll: false, byteCount: 5)
        try parser.text(json(["type": "frame", "requestID": request.requestID, "frame": try object(frame)]))
        try parser.bytes(Data([0, 0])); try parser.bytes(Data([0, 1, 0x65]))
        XCTAssertNil(parser.result)
        try parser.text(json(["type": "gap", "requestID": request.requestID, "range": ["start": 101, "end": 102]]))
        try parser.text(json(["type": "end", "requestID": request.requestID, "outcome": "partial", "frames": 1]))
        XCTAssertEqual(parser.result?.frameCount, 1)
        XCTAssertEqual(parser.result?.bytes, 5)
        XCTAssertEqual(parser.result?.gaps, [.init(start: 101, end: 102)])
        XCTAssertThrowsError(try parser.bytes(Data([1])))
    }

    func testParserRejectsBadIdentityOversizedFramesAndInterruptedBinary() throws {
        let request = request()
        var parser = CameraHistoryResponseParser(request: request, maximumBytes: 4)
        XCTAssertThrowsError(try parser.text(json(["type": "end", "requestID": "other", "outcome": "unavailable", "frames": 0])))
        try begin(&parser, request)
        try parser.text(json(["type": "segment", "requestID": request.requestID,
                              "segment": try object(historyBatch(start: 100, end: 102).pieces[0].segment)]))
        let frame: [String: Any] = ["segment": 0, "presentationTicks": 0, "durationTicks": 1,
                                    "keyFrame": true, "preroll": false, "byteCount": 5]
        XCTAssertThrowsError(try parser.text(json(["type": "frame", "requestID": request.requestID, "frame": frame]))) {
            XCTAssertEqual($0 as? CameraHistoryError, .tooLarge)
        }
        parser = CameraHistoryResponseParser(request: request)
        try begin(&parser, request)
        try parser.text(json(["type": "segment", "requestID": request.requestID,
                              "segment": try object(historyBatch(start: 100, end: 102).pieces[0].segment)]))
        try parser.text(json(["type": "frame", "requestID": request.requestID, "frame": frame]))
        try parser.bytes(Data([0]))
        XCTAssertThrowsError(try parser.text(json(["type": "end", "requestID": request.requestID, "outcome": "complete", "frames": 1])))
        XCTAssertNil(parser.result)
    }

    func testParserSupportsNALLengthVariantsAndRemoteErrorsBeforeBegin() throws {
        XCTAssertTrue(CameraHistoryResponseParser.validAccessUnit(Data([1, 0x65]), lengthBytes: 1))
        XCTAssertTrue(CameraHistoryResponseParser.validAccessUnit(Data([0, 1, 0x65]), lengthBytes: 2))
        XCTAssertFalse(CameraHistoryResponseParser.validAccessUnit(Data([0, 2, 0x65]), lengthBytes: 2))
        let request = request()
        var parser = CameraHistoryResponseParser(request: request)
        XCTAssertThrowsError(try parser.text(json(["type": "end", "requestID": request.requestID,
            "outcome": "error", "code": 3, "error": "No live frame"]))) {
            XCTAssertEqual($0 as? CameraHistoryError, .remote(3, "No live frame"))
        }
    }

    func testInitialHandoffUsesServerAnchorThenRefillsThirtyWhenBelowTwenty() async throws {
        let fetcher = HistoryFetcher(), history = CameraHistoryPlayback()
        history.configure(cameraID: camera, transport: fetcher)
        history.enter(localPosition: -60, localHead: 0, paused: false)
        try await settled(history)
        XCTAssertEqual(history.position, 940)
        XCTAssertEqual(history.canonicalOffset, 1000)
        var requests = await fetcher.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].relativeTo, "live")
        XCTAssertEqual(requests[0].range, .init(start: -90, end: -30))
        history.advance(by: 10)
        XCTAssertFalse(history.fetching)
        history.advance(by: 0.1)
        try await settled(history)
        requests = await fetcher.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[1].relativeTo)
        XCTAssertEqual(requests[1].range, .init(start: 970, end: 1000))
        XCTAssertEqual(history.state, .ready)
        history.close()
    }

    func testPausedInitialFetchStopsAndSeekReusesOverlappingCoverage() async throws {
        let fetcher = HistoryFetcher(), history = CameraHistoryPlayback()
        history.configure(cameraID: camera, transport: fetcher)
        history.enter(localPosition: -60, localHead: 0, paused: true)
        try await settled(history)
        history.advance(by: 25)
        XCTAssertEqual(history.position, 940)
        XCTAssertFalse(history.fetching)
        XCTAssertFalse(history.seek(by: -10))
        try await settled(history)
        let requests = await fetcher.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].range, .init(start: 900, end: 910))
        XCTAssertTrue(history.isPaused)
        XCTAssertFalse(history.seek(by: 1000))
        try await settled(history)
        XCTAssertTrue(history.isPaused)
        XCTAssertTrue(history.isActive)
        XCTAssertEqual(history.position!, 1000, accuracy: 0.001)
        history.togglePause()
        XCTAssertTrue(history.seek(by: 30))
        history.close()
    }

    func testNewSeekSupersedesLateResponseAndLiveReturnRetainsCache() async throws {
        let fetcher = HistoryFetcher(delay: .milliseconds(50)), history = CameraHistoryPlayback()
        history.configure(cameraID: camera, transport: fetcher)
        history.enter(localPosition: -60, localHead: 0, paused: true)
        try await Task.sleep(for: .milliseconds(10))
        history.seek(by: -30)
        try await settled(history)
        XCTAssertEqual(history.position, 910)
        XCTAssertEqual(history.buffer.batches.count, 1)
        let bytes = history.buffer.bytes
        history.deactivate()
        XCTAssertEqual(history.buffer.bytes, bytes)
        history.enter(localPosition: -90, localHead: 0, paused: true)
        XCTAssertFalse(history.fetching)
        XCTAssertEqual(history.position, 910)
        history.close()
        XCTAssertEqual(history.buffer.bytes, 0)
    }

    func testUnavailableLiveFallsBackToNVRNowNotPhoneClock() async throws {
        let fetcher = HistoryFetcher(rejectLive: true), history = CameraHistoryPlayback()
        history.configure(cameraID: camera, transport: fetcher)
        history.enter(localPosition: -60, localHead: 0, paused: true)
        try await settled(history)
        let requests = await fetcher.requests
        XCTAssertEqual(requests.map(\.relativeTo), ["live", "now"])
        XCTAssertEqual(history.position, 940)
        history.close()
    }

    func testInterruptedRelativeReadRetriesItsResolvedAbsoluteRangeWhilePaused() async throws {
        let fetcher = HistoryFetcher(interruptFirstAfterBegin: true), history = CameraHistoryPlayback()
        history.configure(cameraID: camera, transport: fetcher)
        history.enter(localPosition: -60, localHead: 0, paused: true)
        try await settled(history)
        let requests = await fetcher.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.relativeTo, "live")
        XCTAssertNil(requests.last?.relativeTo)
        XCTAssertEqual(requests.last?.range, .init(start: 910, end: 970))
        XCTAssertEqual(history.position, 940)
        XCTAssertEqual(history.state, .ready)
        XCTAssertTrue(history.isPaused)
        history.close()
    }

    func testTransportWarmsWithoutMediaAndReusesSameSessionForFetchAndHeartbeat() async throws {
        let socket = HistorySocket()
        let transport = CameraHistoryTransport(makeSocket: { socket })
        await transport.maintain()
        var operations = await socket.core.operations
        XCTAssertEqual(operations, [HBProtocolOperations.openSession, HBProtocolOperations.openNVRMedia, "keepalive"])
        let batch = try await transport.fetch(request())
        XCTAssertEqual(batch.gaps, [.init(start: 100, end: 102)])
        await transport.maintain()
        operations = await socket.core.operations
        XCTAssertEqual(operations, [HBProtocolOperations.openSession, HBProtocolOperations.openNVRMedia, "keepalive", "frames", "keepalive"])
        await transport.close()
    }

    func testTransportNegotiatesOlderServerWithoutSendingUnknownKeepalive() async throws {
        let socket = HistorySocket(keepalive: false)
        let transport = CameraHistoryTransport(makeSocket: { socket })
        await transport.maintain()
        _ = try await transport.fetch(request())
        let operations = await socket.core.operations
        XCTAssertEqual(operations, [HBProtocolOperations.openSession, HBProtocolOperations.openNVRMedia, "frames"])
        await transport.close()
    }

    func testHistoryDecodesSyntheticH264AndHEVCWithDecodeOnlyPreroll() async throws {
        for codec in [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC] {
            let sample = try syntheticHistorySample(codec: codec)
            let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
            var sets: [Data] = []
            for index in 0..<(codec == kCMVideoCodecType_H264 ? 2 : 3) {
                var pointer: UnsafePointer<UInt8>?, size = 0
                let status: OSStatus
                if codec == kCMVideoCodecType_H264 {
                    status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                        parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                } else {
                    status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                        parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                }
                XCTAssertEqual(status, noErr)
                sets.append(Data(bytes: try XCTUnwrap(pointer), count: size))
            }
            let segment = CameraHistorySegment(number: 0, range: .init(start: 1000, end: 1001),
                time: .init(canonicalUTC: 1000, receivedUTC: 1000, cameraUTC: nil, canonicalSource: "received", epochID: UUID().uuidString),
                timescale: 90000, codec: codec == kCMVideoCodecType_H264 ? "H264" : "H265", parameterSets: sets, nalUnitLengthBytes: 4)
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var data = Data(count: CMBlockBufferGetDataLength(block))
            XCTAssertEqual(data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }, noErr)
            let frame = CameraHistoryFrame(segment: 0, presentationTicks: 0, decodeTicks: nil, durationTicks: 6000,
                keyFrame: true, preroll: true, byteCount: data.count)
            let renderer = CameraH264Renderer()
            try renderer.configureHistory(segment)
            let hidden = try XCTUnwrap(renderer.enqueueHistory(.init(frame: frame, data: data), segment: segment, display: false))
            XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(CMSampleBufferGetFormatDescription(hidden))), codec)
            let attachments = CMSampleBufferGetSampleAttachmentsArray(hidden, createIfNecessary: false) as? [[String: Any]]
            XCTAssertEqual(attachments?.first?[kCMSampleAttachmentKey_DoNotDisplay as String] as? Bool, true)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                renderer.layer.sampleBufferRenderer.flush(removingDisplayedImage: true) { continuation.resume() }
            }
        }
    }

    func testRequestDeadlineAndCancellationCloseBlockedSocketReads() async throws {
        let socket = HistorySocket(blockFrames: true)
        let transport = CameraHistoryTransport(requestTimeout: 0.05, makeSocket: { socket })
        await transport.maintain()
        do { _ = try await transport.fetch(request()); XCTFail("Expected deadline") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        await transport.close()

        let another = HistorySocket(blockFrames: true)
        let cancellable = CameraHistoryTransport(makeSocket: { another })
        await cancellable.maintain()
        let request = request()
        let fetch = Task { try await cancellable.fetch(request) }
        try await Task.sleep(for: .milliseconds(20))
        fetch.cancel()
        do { _ = try await fetch.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await cancellable.close()
    }

    func testThumbnailCapabilityAndSessionReuseAndDeadline() async throws {
        let request = HBNVRThumbnailRequest(requestID: UUID().uuidString, cameraID: camera, timestamp: 100, size: .init(width: 320, height: 180))
        let old = HistorySocket()
        let unsupported = CameraHistoryTransport(makeSocket: { old })
        do { _ = try await unsupported.thumbnail(request); XCTFail("Expected unsupported capability") }
        catch { XCTAssertTrue(error is CameraThumbnailError) }
        let operations = await old.core.operations
        XCTAssertFalse(operations.contains("thumbnail"))
        await unsupported.close()

        let socket = HistorySocket(thumbnails: true)
        let transport = CameraHistoryTransport(makeSocket: { socket })
        let thumbnail = try await transport.thumbnail(request)
        XCTAssertNil(thumbnail)
        _ = try await transport.fetch(self.request())
        await transport.maintain()
        let reused = await socket.core.operations
        XCTAssertEqual(reused.filter { $0 == HBProtocolOperations.openSession }.count, 1)
        XCTAssertTrue(reused.contains("keepalive"))
        await transport.close()

        let blocked = HistorySocket(blockFrames: true, thumbnails: true)
        let timeout = CameraHistoryTransport(requestTimeout: 0.03, makeSocket: { blocked })
        do { _ = try await timeout.thumbnail(request); XCTFail("Expected timeout") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        await timeout.close()
    }

    private func request() -> HBNVRMediaRequest {
        .init(requestID: UUID().uuidString, operation: "frames", cameraID: camera,
              timeline: "canonical", range: .init(start: 100, end: 102))
    }
    private func begin(_ parser: inout CameraHistoryResponseParser, _ request: HBNVRMediaRequest) throws {
        try parser.text(json(["type": "begin", "requestID": request.requestID, "cameraID": camera,
                              "timeline": "canonical", "range": ["start": 100, "end": 102]]))
    }
    private func settled(_ history: CameraHistoryPlayback) async throws {
        for _ in 0..<300 {
            if !history.fetching { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("History fetch did not settle")
    }
    private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
}

private nonisolated final class HistoryEncodedSample: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CMSampleBuffer?
    func put(_ value: CMSampleBuffer) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> CMSampleBuffer? { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor private func syntheticHistorySample(codec: CMVideoCodecType) throws -> CMSampleBuffer {
    let sink = HistoryEncodedSample()
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(allocator: nil, width: 64, height: 64, codecType: codec,
        encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: { context, _, status, _, sample in
            if status == noErr, let context, let sample {
                Unmanaged<HistoryEncodedSample>.fromOpaque(context).takeUnretainedValue().put(sample)
            }
        }, refcon: Unmanaged.passUnretained(sink).toOpaque(), compressionSessionOut: &session)
    XCTAssertEqual(status, noErr)
    let encoder = try XCTUnwrap(session)
    defer { VTCompressionSessionInvalidate(encoder) }
    XCTAssertEqual(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse), noErr)
    var pixel: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel), noErr)
    let buffer = try XCTUnwrap(pixel)
    CVPixelBufferLockBaseAddress(buffer, [])
    memset(CVPixelBufferGetBaseAddress(buffer), 80, CVPixelBufferGetDataSize(buffer))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    XCTAssertEqual(VTCompressionSessionEncodeFrame(encoder, imageBuffer: buffer, presentationTimeStamp: .zero,
        duration: CMTime(value: 1, timescale: 15), frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil), noErr)
    XCTAssertEqual(VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid), noErr)
    return try XCTUnwrap(sink.get())
}

private nonisolated func historyBatch(start: Double, end: Double, anchor: Double? = nil,
                                     gaps: [CameraHistoryRange] = []) -> CameraHistoryBatch {
    let zero = floor(start)
    let segment = CameraHistorySegment(number: 0, range: .init(start: zero, end: end),
        time: .init(canonicalUTC: zero, receivedUTC: zero, cameraUTC: nil, canonicalSource: "received", epochID: UUID().uuidString),
        timescale: 1, codec: "H264", parameterSets: [Data([1]), Data([2])], nalUnitLengthBytes: 4)
    let count = Int(ceil(end - zero))
    let samples: [CameraHistorySample] = (0..<count).map { index in
        let frame = CameraHistoryFrame(segment: 0, presentationTicks: Int64(index), decodeTicks: nil,
            durationTicks: 1, keyFrame: index % 10 == 0, preroll: zero + Double(index) < start, byteCount: 5)
        return CameraHistorySample(frame: frame, data: Data([0, 0, 0, 1, 0x65]))
    }
    return CameraHistoryBatch(id: UUID(), range: .init(start: start, end: end), anchor: anchor,
        pieces: [.init(id: UUID(), segment: segment, samples: samples)], gaps: gaps)
}

private actor HistoryFetcher: CameraHistoryFetching {
    var requests: [HBNVRMediaRequest] = []
    let delay: Duration
    let beginDelay: Duration
    let rejectLive: Bool
    let interruptFirstAfterBegin: Bool
    let unavailable: Bool
    let neighbors: CameraHistoryNeighbors
    let neighborError: CameraHistoryError?
    init(delay: Duration = .zero, beginDelay: Duration = .zero, rejectLive: Bool = false, interruptFirstAfterBegin: Bool = false, unavailable: Bool = false,
         neighbors: CameraHistoryNeighbors = .init(previous: nil, next: nil), neighborError: CameraHistoryError? = nil) {
        self.delay = delay; self.rejectLive = rejectLive; self.interruptFirstAfterBegin = interruptFirstAfterBegin
        self.beginDelay = beginDelay
        self.unavailable = unavailable
        self.neighbors = neighbors; self.neighborError = neighborError
    }
    func start() {}
    func close() {}
    func fetch(_ request: HBNVRMediaRequest, onBegin: CameraHistoryBeginHandler?) async throws -> CameraHistoryBatch {
        requests.append(request)
        if rejectLive && request.relativeTo == "live" { throw CameraHistoryError.remote(3, "No live frame") }
        let anchor: Double? = request.relativeTo == nil ? nil : 1000
        try? await Task.sleep(for: beginDelay)
        await onBegin?(.init(start: request.range.start + (anchor ?? 0), end: request.range.end + (anchor ?? 0)), anchor)
        // Intentionally allow a late response after cancellation to prove that
        // obsolete work cannot replace the current seek's cache or anchor.
        try? await Task.sleep(for: delay)
        if request.operation == "neighbors" {
            if let neighborError { throw neighborError }
            return CameraHistoryBatch(id: UUID(), range: .init(start: request.range.start, end: request.range.end),
                anchor: nil, pieces: [], gaps: [], neighbors: neighbors)
        }
        if interruptFirstAfterBegin && requests.count == 1 {
            throw CameraHistoryFetchFailure(underlying: CameraHistoryError.remote(3, "Shard rotated"),
                range: .init(start: request.range.start + 1000, end: request.range.end + 1000), anchor: anchor)
        }
        if request.operation == "availability" || unavailable {
            let range = CameraHistoryRange(start: request.range.start + (anchor ?? 0), end: request.range.end + (anchor ?? 0))
            return CameraHistoryBatch(id: UUID(), range: range, anchor: anchor, pieces: [], gaps: [range])
        }
        return historyBatch(start: request.range.start + (anchor ?? 0), end: request.range.end + (anchor ?? 0), anchor: anchor)
    }
}

private actor HistoryBeginProbe {
    var ranges: [CameraHistoryRange] = []
    var remaining: [Int] = []
    func record(_ range: CameraHistoryRange, remaining count: Int) {
        ranges.append(range); remaining.append(count)
    }
}

private nonisolated final class HistorySocket: CameraHistorySocket, Sendable {
    let core: Core
    init(keepalive: Bool = true, blockFrames: Bool = false, thumbnails: Bool = false) { core = Core(keepalive: keepalive, blockFrames: blockFrames, thumbnails: thumbnails) }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await core.send(message) }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await core.receive() }
    func close() { Task { await core.close() } }
    actor Core {
        var operations: [String] = []
        var messages: [URLSessionWebSocketTask.Message] = []
        var bufferedMessageCount: Int { messages.count }
        let session = UUID(), keepalive: Bool
        let blockFrames: Bool
        let thumbnails: Bool
        var closed = false
        var waiting: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        init(keepalive: Bool, blockFrames: Bool, thumbnails: Bool) { self.keepalive = keepalive; self.blockFrames = blockFrames; self.thumbnails = thumbnails }
        func send(_ message: URLSessionWebSocketTask.Message) throws {
            guard !closed, case .string(let string) = message else { throw URLError(.cancelled) }
            let data = Data(string.utf8)
            let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let operation = value["operation"] as! String
            operations.append(operation)
            if operation == HBProtocolOperations.openSession || operation == HBProtocolOperations.openNVRMedia {
                let request = try JSONDecoder().decode(HBProtocolEnvelope.self, from: data)
                let result: HBProtocolResponse
                if operation == HBProtocolOperations.openSession {
                    result = try .success(HBWebSocketSessionOpened(sessionID: session, resumeToken: "fresh",
                        serverInstanceID: UUID(), authorization: .user, limits: .init(resumeWindowSeconds: 60,
                        maximumReplayMessages: 10, maximumReplayBytes: 65536, maximumRequestRecords: 100)))
                } else {
                    result = HBProtocolResponse(status: .success, result: try HBJSONValue(encoding: [
                        "version": HBJSONValue.integer(1), "framing": .string("websocket-text-json,binary-chunks"),
                        "maxMessageBytes": .integer(65536), "supportsKeepalive": .bool(keepalive), "supportsThumbnails": .bool(thumbnails)]))
                }
                var response = try HBProtocolEnvelope.response(to: request, body: result)
                response.sessionID = session
                messages.append(.string(String(decoding: try JSONEncoder().encode(response), as: UTF8.self)))
            } else if operation == "keepalive" {
                try append(["type": "alive", "requestID": value["requestID"]!])
            } else if operation == "thumbnail" {
                if blockFrames { return }
                try append(["type": "begin", "requestID": value["requestID"]!, "cameraID": value["cameraID"]!,
                            "timeline": "canonical", "timestamp": value["timestamp"]!])
                try append(["type": "end", "requestID": value["requestID"]!, "outcome": "unavailable", "frames": 0])
            } else {
                if blockFrames { return }
                try append(["type": "begin", "requestID": value["requestID"]!, "cameraID": value["cameraID"]!,
                            "timeline": "canonical", "range": value["range"]!])
                try append(["type": "end", "requestID": value["requestID"]!, "outcome": "unavailable", "frames": 0])
            }
        }
        func append(_ value: [String: Any]) throws {
            messages.append(.string(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)))
        }
        func receive() async throws -> URLSessionWebSocketTask.Message {
            guard !closed else { throw URLError(.networkConnectionLost) }
            if messages.isEmpty { return try await withCheckedThrowingContinuation { waiting = $0 } }
            return messages.removeFirst()
        }
        func close() { closed = true; waiting?.resume(throwing: URLError(.cancelled)); waiting = nil }
    }
}
