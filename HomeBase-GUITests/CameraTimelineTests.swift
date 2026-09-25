import XCTest
import SwiftUI
import Combine
import ImageIO
import UniformTypeIdentifiers
import HomeBaseProtocol
@testable import HomeBase_GUI

@MainActor
final class CameraTimelineTests: XCTestCase {
    private let camera = UUID().uuidString

    func testTimelineStandardThumbnailIsFullSixteenByNineSize() {
        XCTAssertEqual(
            CameraTimelineSizing.standard,
            CGSize(width: CameraTimelineScale.cellWidth, height: 63)
        )
    }

    func testDynamicScaleRoundTripsAndKeepsSnapDistanceInPoints() async throws {
        let model = CameraTimelineModel(clock: { 100 })
        let fetcher = TimelineFetcher()
        await model.open(cameraID: camera, transport: fetcher)
        defer { model.close() }
        let target = TimelineFetcher.anchor - 3900
        model.follow(.canonical(target, paused: true))
        for width in [64.0, 77.25, 112.0] {
            model.setViewport(852, cellWidth: width)
            XCTAssertEqual(model.cursor, target, "Changing cell width is not a seek")
            XCTAssertEqual(model.feedbackTick, 0)
            let offset = CameraTimelineScale.offset(time: target, start: model.start, cellWidth: width)
            XCTAssertEqual(CameraTimelineScale.time(offset: offset, start: model.start, end: model.end, cellWidth: width),
                target, accuracy: 0.001)
            for points in [2.9, 3.1] {
                let time = 1200 + points / width * CameraTimelineScale.seconds
                XCTAssertEqual(CameraTimelineScale.settledTime(time, start: 0, end: 2400, cellWidth: width),
                    points < 3 ? 1200 : time)
            }
            let point = CameraTimelineScale.seconds / width
            var feedback = CameraTimelineDetents()
            feedback.begin(at: 1200 - 2 * point)
            XCTAssertTrue(feedback.advance(to: 1200, now: 0.1, cellWidth: width))
            XCTAssertFalse(feedback.advance(to: 1200 + 1.9 * point, now: 0.2, cellWidth: width))
            XCTAssertFalse(feedback.advance(to: 1200, now: 0.3, cellWidth: width))
            XCTAssertFalse(feedback.advance(to: 1200 + 2.1 * point, now: 0.4, cellWidth: width))
            XCTAssertTrue(feedback.advance(to: 1200, now: 0.5, cellWidth: width))
            model.beginDrag(); model.scrub(offset: offset)
            XCTAssertEqual(try XCTUnwrap(model.endDrag()), target, accuracy: 0.001)
        }
        model.beginDrag()
        model.setViewport(393, cellWidth: 64)
        XCTAssertFalse(model.dragging)
        XCTAssertNil(model.endDrag(), "Resizing cannot commit stale native drag offsets")
        XCTAssertEqual(model.cursor, target)
    }

    func testCompactScaleFetchesVisibleCellsAndKeepsCacheBounded() async throws {
        let model = CameraTimelineModel(clock: { 100 })
        let fetcher = TimelineFetcher()
        model.setViewport(852, cellWidth: 64)
        await model.open(cameraID: camera, transport: fetcher)
        defer { model.close() }
        model.follow(.canonical(TimelineFetcher.anchor - 4 * 3600, paused: true))
        try await wait { model.previews.count >= 19 }
        let tile = Int(floor((TimelineFetcher.anchor - 4 * 3600) / 1200))
        XCTAssertNotNil(model.previews[tile - 8], "Narrow tiles require more visible thumbnails")
        XCTAssertNotNil(model.previews[tile + 8])
        XCTAssertLessThanOrEqual(model.previews.count, 48)
        let active = await fetcher.maximumActive
        XCTAssertEqual(active, 1)
    }

    func testTimelineTimestampOnlyAddsDateBeyondTwentyFourHours() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        // A DST transition and midnight do not replace the elapsed-24h rule.
        let latest = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-09T08:00:00Z"))
        XCTAssertEqual(CameraHistoryTimestamp.timelineString(for: latest, latest: latest, timeZone: zone), "01:00:00")
        XCTAssertEqual(CameraHistoryTimestamp.timelineString(for: latest.addingTimeInterval(-2 * 3600), latest: latest, timeZone: zone), "23:00:00")
        XCTAssertEqual(CameraHistoryTimestamp.timelineString(for: latest.addingTimeInterval(-86400), latest: latest, timeZone: zone), "00:00:00")
        XCTAssertEqual(CameraHistoryTimestamp.timelineString(for: latest.addingTimeInterval(-86401), latest: latest, timeZone: zone), "23:59:59 2026-03-07")
    }

    func testIntervalLabelMustFitEntirelyBeforeThePlayhead() {
        XCTAssertTrue(CameraTimelineScale.intervalLabelIsVisible(trailingEdge: 198.9, playhead: 200))
        XCTAssertFalse(CameraTimelineScale.intervalLabelIsVisible(trailingEdge: 199, playhead: 200), "Touching the line hides the whole label")
        XCTAssertFalse(CameraTimelineScale.intervalLabelIsVisible(trailingEdge: 208, playhead: 200), "Crossing labels are not partially clipped")
        XCTAssertFalse(CameraTimelineScale.intervalLabelIsVisible(trailingEdge: 350, playhead: 200), "The trailing half belongs to the current timestamp")
    }

    func testThumbnailAspectAndGentleSnapZone() {
        XCTAssertEqual(CameraTimelineScale.cellWidth / CameraTimelineScale.thumbnailHeight, 16.0 / 9.0, accuracy: 0.0001)
        let mark = 1200.0, pointsToTime = CameraTimelineScale.seconds / CameraTimelineScale.cellWidth
        for points in [-3.0, -1.0, 0.0, 1.0, 3.0] {
            XCTAssertEqual(CameraTimelineScale.settledTime(mark + points * pointsToTime, start: 0, end: 2400), mark)
        }
        for points in [-10.0, -3.1, 3.1, 10.0] {
            let time = mark + points * pointsToTime
            XCTAssertEqual(CameraTimelineScale.settledTime(time, start: 0, end: 2400), time)
        }
        XCTAssertEqual(CameraTimelineScale.settledTime(1195, start: 0, end: 1196), 1195, "Never snap into the future")
        XCTAssertEqual(CameraTimelineScale.settledTime(1205, start: 1201, end: 2400), 1205, "Never snap outside the loaded window")
    }

    func testHapticsCrossBothWaysWithoutChatteringOrPulsingOnDeparture() {
        var feedback = CameraTimelineDetents()
        feedback.begin(at: 1100)
        XCTAssertFalse(feedback.advance(to: 1199, now: 0))
        XCTAssertTrue(feedback.advance(to: 1200, now: 0.1))
        XCTAssertFalse(feedback.advance(to: 1201, now: 0.2))
        XCTAssertFalse(feedback.advance(to: 1199, now: 0.3))
        XCTAssertFalse(feedback.advance(to: 1201, now: 0.4))
        XCTAssertFalse(feedback.advance(to: 1300, now: 0.5))
        XCTAssertTrue(feedback.advance(to: 1200, now: 0.6))
        XCTAssertFalse(feedback.advance(to: 1199, now: 0.7))
        XCTAssertTrue(feedback.advance(to: 3700, now: 0.8), "One tick, not a queued tick for every skipped mark")
        XCTAssertFalse(feedback.advance(to: 4900, now: 0.81), "Rate-limit fast flicks")
        feedback.begin(at: 2400)
        XCTAssertFalse(feedback.advance(to: 2399, now: 1), "Leaving the initial mark is not crossing it")
    }

    func testSnappingAndHapticsAreOnlyAppliedToUserScrubs() async throws {
        let model = CameraTimelineModel(clock: { 100 })
        await model.open(cameraID: camera, transport: TimelineFetcher())
        defer { model.close() }
        let mark = floor(TimelineFetcher.anchor / 1200) * 1200
        model.follow(.canonical(mark - 1, paused: false))
        model.follow(.canonical(mark + 1, paused: false))
        XCTAssertEqual(model.feedbackTick, 0)
        XCTAssertEqual(model.cursor, mark + 1, "Following playback must never quantize time")
        model.beginDrag()
        model.scrub(offset: CameraTimelineScale.offset(time: mark - 1, start: model.start))
        XCTAssertEqual(model.feedbackTick, 1)
        XCTAssertEqual(try XCTUnwrap(model.endDrag()), mark, accuracy: 0.001)
        XCTAssertEqual(model.feedbackTick, 1, "Snapping back to the same mark must not double-click")
        model.scrub(offset: 0)
        XCTAssertEqual(model.feedbackTick, 1, "Programmatic scrolling is silent")
        XCTAssertNil(model.endDrag(), "Snap commits only one seek")
    }

    func testScaleIsContinuousPastLeftFutureRightAndClampsFuture() {
        let start = 1_700_000_000.0
        XCTAssertEqual(CameraTimelineScale.offset(time: start + 1200, start: start), 112)
        XCTAssertEqual(CameraTimelineScale.time(offset: 56, start: start, end: start + 1200), start + 600)
        XCTAssertEqual(CameraTimelineScale.time(offset: -100, start: start, end: start + 1200), start)
        XCTAssertEqual(CameraTimelineScale.time(offset: 1000, start: start, end: start + 1200), start + 1200)
        let currentStart = CameraTimelineScale.windowStart(at: start, latest: start)
        XCTAssertLessThan(currentStart, start)
        XCTAssertGreaterThan(currentStart + 72 * 1200, start)
        let old = start - 7 * 86400
        let oldStart = CameraTimelineScale.windowStart(at: old, latest: start)
        XCTAssertLessThan(oldStart, old - 6 * 1200)
        XCTAssertGreaterThan(oldStart + 72 * 1200, old + 6 * 1200)
    }

    func testFollowsNVRAnchorNotPhoneClockAndDragDoesNotGetOverwritten() async throws {
        var clock = 100.0
        let fetcher = TimelineFetcher()
        let model = CameraTimelineModel(clock: { clock })
        await model.open(cameraID: camera, transport: fetcher)
        defer { model.close() }
        let anchor = try XCTUnwrap(model.latest)
        XCTAssertEqual(anchor, TimelineFetcher.anchor)
        clock += 10
        model.follow(.live)
        XCTAssertEqual(model.cursor, anchor + 10)
        model.follow(.relative(cameraID: camera, offset: -30, capturedAt: 105, paused: true))
        XCTAssertEqual(model.cursor, anchor - 25)
        model.beginDrag()
        let target = anchor - 3600
        model.scrub(offset: CameraTimelineScale.offset(time: target, start: model.start))
        model.follow(.live)
        XCTAssertEqual(try XCTUnwrap(model.cursor), target, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(model.endDrag()), target, accuracy: 0.001)
        XCTAssertNil(model.endDrag(), "One seek only after a user scroll")
        model.follow(.canonical(target + 30, paused: false))
        XCTAssertEqual(model.cursor, target + 30)
    }

    func testVisibleOnlySequentialPreviewsNoFutureRequestsAndBoundedCache() async throws {
        let fetcher = TimelineFetcher()
        let model = CameraTimelineModel(clock: { 100 })
        model.setViewport(400)
        await model.open(cameraID: camera, transport: fetcher)
        defer { model.close() }
        try await wait { model.previews.count >= 4 }
        let initial = await fetcher.requests
        XCTAssertLessThanOrEqual(initial.count, 6, "Do not fetch the whole day on entry")
        XCTAssertTrue(initial.allSatisfy { $0.timestamp <= TimelineFetcher.anchor })
        XCTAssertTrue(initial.allSatisfy { $0.size.width == 320 && $0.size.height == 180 && $0.relativeTo == nil })
        XCTAssertGreaterThan(try XCTUnwrap(initial.first).timestamp, try XCTUnwrap(initial.last).timestamp)
        for day in 1...12 {
            let time = TimelineFetcher.anchor - Double(day) * 86400
            model.follow(.canonical(time, paused: true))
            let tile = Int(floor(time / 1200))
            try await wait { model.previews[tile] != nil }
            XCTAssertLessThanOrEqual(model.previews.count, 48)
        }
        let active = await fetcher.maximumActive
        XCTAssertEqual(active, 1)
        model.beginDrag()
        model.scrub(offset: 1e8)
        XCTAssertLessThanOrEqual(try XCTUnwrap(model.endDrag()), try XCTUnwrap(model.latest))
    }

    func testUnsupportedPreviewsAreQuietAndDoNotPreventSeeking() async throws {
        let fetcher = TimelineFetcher(unsupported: true)
        let model = CameraTimelineModel()
        await model.open(cameraID: camera, transport: fetcher)
        defer { model.close() }
        try await wait { model.message != nil }
        XCTAssertTrue(model.message?.contains("Update") == true)
        model.beginDrag()
        model.scrub(offset: 0)
        XCTAssertNotNil(model.endDrag())
        try await Task.sleep(for: .milliseconds(20))
        let requests = await fetcher.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testStoppedCameraUsesServerNowAndLateRepliesCannotPopulateNextCamera() async throws {
        let old = TimelineFetcher(rejectLive: true, delay: .milliseconds(100))
        let model = CameraTimelineModel()
        await model.open(cameraID: camera, transport: old)
        for _ in 0..<50 {
            if await !old.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let availability = await old.availability
        XCTAssertEqual(availability.map(\.relativeTo), ["live", "now"])
        let new = TimelineFetcher(unsupported: true)
        await model.open(cameraID: UUID().uuidString, transport: new)
        defer { model.close() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(model.previews.isEmpty)
        XCTAssertNotNil(model.message)
        let closed = await old.closed
        XCTAssertTrue(closed)
    }

    func testEmptyPreviewsRefreshAfterAMinute() async throws {
        var clock = 100.0
        let fetcher = TimelineFetcher()
        let model = CameraTimelineModel(clock: { clock })
        model.setViewport(112)
        await model.open(cameraID: camera, transport: fetcher)
        defer { model.close() }
        try await wait { model.previews.count >= 3 }
        let count = await fetcher.requests.count
        model.follow(.live)
        try await Task.sleep(for: .milliseconds(15))
        let unchanged = await fetcher.requests.count
        XCTAssertEqual(unchanged, count)
        clock += 61
        model.follow(.live)
        for _ in 0..<100 {
            if await fetcher.requests.count > count { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let refreshed = await fetcher.requests.count
        XCTAssertGreaterThan(refreshed, count)
    }

    func testCorruptJPEGIsAFailureNotAGapAndHugeViewportStaysBounded() async throws {
        let model = CameraTimelineModel()
        model.setViewport(100_000)
        let fetcher = TimelineFetcher(jpeg: Data([0, 1, 2]))
        await model.open(cameraID: camera, transport: fetcher)
        defer { model.close() }
        model.follow(.canonical(TimelineFetcher.anchor - 3 * 86400, paused: true))
        try await wait { model.previews.count >= 47 }
        try await Task.sleep(for: .milliseconds(20))
        let count = await fetcher.requests.count
        XCTAssertLessThanOrEqual(count, 48)
        XCTAssertLessThanOrEqual(model.previews.count, 48)
        for entry in model.previews.values {
            guard case .failed = entry.preview else { return XCTFail("Decode errors must not be presented as gaps") }
        }
    }

    func testThumbnailParserAssemblesChunksOnlyAfterSuccessfulEnd() throws {
        let request = thumbnailRequest()
        var parser = CameraThumbnailParser(request: request)
        try begin(&parser, request)
        try header(&parser, request, count: 4)
        try parser.bytes(Data([1, 2]))
        XCTAssertFalse(parser.finished)
        XCTAssertNil(parser.result)
        try parser.bytes(Data([3, 4]))
        XCTAssertNil(parser.result)
        try parser.text(json(["type": "end", "requestID": request.requestID, "outcome": "complete", "frames": 1]))
        XCTAssertTrue(parser.finished)
        XCTAssertEqual(parser.result?.data, Data([1, 2, 3, 4]))
        XCTAssertEqual(parser.result?.width, 320)
        XCTAssertThrowsError(try parser.bytes(Data([5])))
    }

    func testThumbnailParserAcceptsGapsAndRejectsMalformedTruncatedAndOversizedReplies() throws {
        let request = thumbnailRequest()
        var gap = CameraThumbnailParser(request: request)
        try begin(&gap, request)
        try gap.text(json(["type": "end", "requestID": request.requestID, "outcome": "unavailable", "frames": 0]))
        XCTAssertTrue(gap.finished); XCTAssertNil(gap.result)
        var truncated = CameraThumbnailParser(request: request)
        try begin(&truncated, request)
        try header(&truncated, request, count: 4)
        try truncated.bytes(Data([1]))
        XCTAssertThrowsError(try truncated.text(json(["type": "end", "requestID": request.requestID, "outcome": "complete", "frames": 1])))
        XCTAssertThrowsError(try truncated.bytes(Data(repeating: 0, count: 65537)))
        var huge = CameraThumbnailParser(request: request)
        try begin(&huge, request)
        XCTAssertThrowsError(try header(&huge, request, count: 8 * 1024 * 1024 + 1))
        var wrong = CameraThumbnailParser(request: request)
        XCTAssertThrowsError(try begin(&wrong, thumbnailRequest()))
        var wrongTime = CameraThumbnailParser(request: request)
        XCTAssertThrowsError(try wrongTime.text(json(["type": "begin", "requestID": request.requestID,
            "cameraID": camera, "timeline": "canonical", "timestamp": 99])))
        var remote = CameraThumbnailParser(request: request)
        XCTAssertThrowsError(try remote.text(json(["type": "end", "requestID": request.requestID,
            "outcome": "error", "code": 5, "error": "Unsupported"]))) { error in
            XCTAssertEqual(error as? CameraHistoryError, .remote(5, "Unsupported"))
        }
    }

    func testRealThumbnailAPIAndPlaybackRemainIndependent() async throws {
        guard let url = ProcessInfo.processInfo.environment["HB_HISTORY_PLAYBACK_SMOKE_URL"],
              let endpoint = HomeBasePairingCode.endpoint(from: url) else { throw XCTSkip("Explicit history smoke opt-in required") }
        let client = HomeBaseWebSocketClient(endpoint: endpoint)
        try await client.connect()
        let preview = await client.makeHistoryTransport()
        let playback = await client.makeHistoryTransport()
        do {
            let cameras = try await client.listTopology().devices.compactMap { CameraPlaybackHistoryAvailability.metadata(in: $0.metadata) }
            XCTAssertFalse(cameras.isEmpty)
            for camera in cameras {
                async let thumbnail = preview.thumbnail(.init(requestID: UUID().uuidString, cameraID: camera.cameraID,
                    timestamp: -30, relativeTo: "live", size: .init(width: 320, height: 180)))
                async let frames = playback.fetch(.init(requestID: UUID().uuidString, operation: "frames", cameraID: camera.cameraID,
                    range: .init(start: -3, end: -1), relativeTo: "live"))
                let (image, batch) = try await (thumbnail, frames)
                let result = try XCTUnwrap(image)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
                let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(decoded.width, result.width); XCTAssertEqual(decoded.height, result.height)
                XCTAssertGreaterThan(batch.frameCount, 0)
                print("Timeline smoke: \(camera.cameraID): \(decoded.width)×\(decoded.height) JPEG; \(batch.frameCount) simultaneous playback frames")
            }
            _ = try await client.listTopology()
        } catch { await preview.close(); await playback.close(); await client.disconnect(); throw error }
        await preview.close(); await playback.close(); await client.disconnect()
    }

    private func thumbnailRequest() -> HBNVRThumbnailRequest {
        .init(requestID: UUID().uuidString, cameraID: camera, timestamp: 100, size: .init(width: 320, height: 180))
    }
    private func begin(_ parser: inout CameraThumbnailParser, _ request: HBNVRThumbnailRequest) throws {
        try parser.text(json(["type": "begin", "requestID": request.requestID, "cameraID": camera,
            "timeline": "canonical", "timestamp": request.timestamp]))
    }
    private func header(_ parser: inout CameraThumbnailParser, _ request: HBNVRThumbnailRequest, count: Int) throws {
        try parser.text(json(["type": "thumbnail", "requestID": request.requestID, "thumbnail": [
            "mimeType": "image/jpeg", "width": 320, "height": 180, "byteCount": count, "timestamp": 99, "keyFrame": true]]))
    }
    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timeline did not settle")
    }

#if os(iOS)
    func testToolbarScrubRelayDrivesTheMountedTimeline() async throws {
        let relay = CameraToolbarScrubRelay()
        let fetcher = TimelineFetcher()
        var begins = 0
        var seeks: [Date] = []
        let host = UIHostingController(rootView: CameraHistoryTimeline(
            makeTransport: { fetcher },
            cameraID: camera,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            position: { .canonical(TimelineFetcher.anchor, paused: true) },
            onBegin: { begins += 1 },
            onSeek: { seeks.append($0) },
            toolbarScrubRelay: relay
        ).environment(\.scenePhase, .active))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 852, height: 100)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))

        relay.events.send(.began)
        relay.events.send(.changed(translation: CameraTimelineScale.cellWidth))
        relay.events.send(.ended(translation: CameraTimelineScale.cellWidth))
        try await wait { seeks.count == 1 }

        XCTAssertEqual(begins, 1)
        XCTAssertEqual(
            try XCTUnwrap(seeks.first).timeIntervalSince1970,
            TimelineFetcher.anchor - CameraTimelineScale.seconds,
            accuracy: 0.001
        )
    }

    func testHiddenTimelineHasNoHandleDoesNotFetchOrInterceptVideoAndClosingReleasesConnection() async throws {
        let state = TimelineTestPanelState()
        let fetcher = TimelineFetcher(jpeg: try sampleJPEG(width: 320, height: 180))
        var transportCount = 0, begins = 0, seeks = 0
        let host = UIHostingController(rootView: TimelineTestPanel(state: state) {
            CameraHistoryTimeline(makeTransport: { transportCount += 1; return fetcher },
                cameraID: self.camera, timeZone: TimeZone(secondsFromGMT: 0)!,
                position: { .live }, onBegin: { begins += 1 }, onSeek: { _ in seeks += 1 })
        }.environment(\.scenePhase, .active).ignoresSafeArea())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(transportCount, 0, "Opening the screen does not fetch a hidden timeline")
        let collapsed = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let collapsedAttachment = XCTAttachment(image: collapsed)
        collapsedAttachment.name = "Hidden timeline — no grab handle"
        collapsedAttachment.lifetime = .keepAlways; add(collapsedAttachment)
        let outside = try XCTUnwrap(host.view.hitTest(CGPoint(x: 30, y: 360), with: nil))
        XCTAssertTrue(outside is CameraLiveGestureUIView, "The hidden timeline must not cover video gestures")
        let bottomCenter = try XCTUnwrap(host.view.hitTest(CGPoint(x: 426, y: 380), with: nil))
        XCTAssertTrue(bottomCenter is CameraLiveGestureUIView, "No grab handle or vertical show/hide gesture intercepts the bottom center")

        state.active = true
        state.presented = true
        try await wait { transportCount == 1 }
        try await Task.sleep(for: .milliseconds(400))
        let requests = await fetcher.requests
        XCTAssertFalse(requests.isEmpty)
        let open = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: open)
        attachment.name = "Visible timeline — no grab handle"
        attachment.lifetime = .keepAlways; add(attachment)
        state.presented = false
        try await Task.sleep(for: .milliseconds(400))
        var closed = await fetcher.closed
        XCTAssertFalse(closed, "Hiding controls keeps the timeline connection and thumbnails alive")
        XCTAssertEqual(transportCount, 1)
        XCTAssertTrue(host.view.hitTest(CGPoint(x: 30, y: 360), with: nil) is CameraLiveGestureUIView)
        state.active = false
        try await Task.sleep(for: .milliseconds(400))
        closed = await fetcher.closed
        XCTAssertTrue(closed, "Leaving history releases the timeline connection")
        XCTAssertEqual(begins, 0, "Showing or hiding a timeline never pauses playback")
        XCTAssertEqual(seeks, 0, "Showing or hiding a timeline never seeks")
        XCTAssertEqual(transportCount, 1)
        XCTAssertTrue(host.view.hitTest(CGPoint(x: 30, y: 360), with: nil) is CameraLiveGestureUIView)
        window.rootViewController = nil
    }

    func testMountedLayoutMaximizesVideoAreaAndUsesSizeClassesOnlyForSafeArea() async throws {
        let layout = TimelineTestLayout()
        let host = UIHostingController(rootView: TimelineTestCanvas(layout: layout).preferredColorScheme(.dark))
        host.traitOverrides.horizontalSizeClass = .compact
        host.traitOverrides.verticalSizeClass = .regular
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        for count in 2...4 {
            layout.count = count
            try await Task.sleep(for: .milliseconds(200))
            let canvas = host.view.safeAreaLayoutGuide.layoutFrame
            let arrangement = CameraGroupLayout.arrangement(count: count, in: canvas.size)
            XCTAssertEqual(arrangement, .column)
            let expected = CameraGroupLayout.cells(count: count, in: canvas.size, arrangement: arrangement)
                .map { $0.offsetBy(dx: canvas.minX, dy: canvas.minY) }
            XCTAssertEqual(layout.paneFrames.count, count)
            for index in 0..<count {
                let frame = try XCTUnwrap(layout.paneFrames[index])
                XCTAssertEqual(frame.minX, expected[index].minX, accuracy: 0.5)
                XCTAssertEqual(frame.minY, expected[index].minY, accuracy: 0.5)
                XCTAssertEqual(frame.width, expected[index].width, accuracy: 0.5)
                XCTAssertEqual(frame.height, expected[index].height, accuracy: 0.5)
                let label = try XCTUnwrap(layout.labelFrames[index])
                XCTAssertTrue(frame.insetBy(dx: -0.5, dy: -0.5).contains(label))
                XCTAssertTrue(host.view.safeAreaLayoutGuide.layoutFrame.insetBy(dx: -0.5, dy: -0.5).contains(label))
            }
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Area-maximized portrait column — \(count) cameras"
            attachment.lifetime = .keepAlways; add(attachment)
        }

        host.traitOverrides.horizontalSizeClass = .regular
        host.traitOverrides.verticalSizeClass = .compact
        window.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        for count in 2...4 {
            layout.paneFrames = layout.paneFrames.filter { $0.key < count }
            layout.labelFrames = layout.labelFrames.filter { $0.key < count }
            layout.count = count
            try await Task.sleep(for: .milliseconds(200))
            let arrangement = CameraGroupLayout.arrangement(count: count, in: window.bounds.size)
            XCTAssertEqual(arrangement, .grid)
            let expected = CameraGroupLayout.cells(count: count, in: window.bounds.size, arrangement: arrangement)
            XCTAssertEqual(layout.paneFrames.count, count)
            for index in 0..<count {
                let frame = try XCTUnwrap(layout.paneFrames[index])
                XCTAssertEqual(frame.minX, expected[index].minX, accuracy: 0.5)
                XCTAssertEqual(frame.minY, expected[index].minY, accuracy: 0.5)
                XCTAssertEqual(frame.width, expected[index].width, accuracy: 0.5)
                XCTAssertEqual(frame.height, expected[index].height, accuracy: 0.5)
            }
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Area-maximized landscape grid — \(count) cameras"
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testMountedTimelineCentersLiveEdgeAndHasAnEmptyFutureHalf() async throws {
        // Exercise a non-16:9 source too: it should fill the tile, with only
        // centered cropping, rather than leaving bars around the image.
        let fetcher = TimelineFetcher(
            availabilityDelay: .milliseconds(300),
            jpeg: try sampleJPEG(width: 240, height: 180),
            jpegWidth: 240
        )
        var position = CameraSwitchPosition.live
        var thumbnailSize = CameraTimelineSizing.standard
        let layout = TimelineTestLayout()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: TimelineTestCanvas(layout: layout).overlay(alignment: .top) {
            TimelineTestPlacement(edge: .top) {
            CameraHistoryTimeline(makeTransport: { fetcher }, cameraID: self.camera, timeZone: TimeZone(secondsFromGMT: 0)!,
                position: { position }, onBegin: { XCTFail("Initial alignment must not seek") }, onSeek: { _ in XCTFail("Following is not scrubbing") })
                .background(TimelineSizingProbe { thumbnailSize = $0 })
            }
        }.environment(\.scenePhase, .active).preferredColorScheme(.dark))
        host.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 12, bottom: 24, right: 8)
        host.traitOverrides.verticalSizeClass = .compact
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let scroll = try XCTUnwrap(findScroll(in: host.view))
        let reservedHeight = scroll.bounds.height
        XCTAssertGreaterThan(reservedHeight, CameraTimelineSizing.standard.height)
        try await Task.sleep(for: .milliseconds(800))
        let count = await fetcher.requests.count
        XCTAssertGreaterThan(count, 0)
        XCTAssertEqual(scroll.bounds.height, reservedHeight, accuracy: 0.5,
            "Loading and loaded timelines reserve the same height")
        let landscapeFrame = scroll.convert(scroll.bounds, to: host.view)
        XCTAssertGreaterThan(host.view.safeAreaInsets.bottom, 0, "Test must have a real protected bottom inset")
        XCTAssertEqual(landscapeFrame.minY, host.view.bounds.minY, accuracy: 1,
            "Compact height ignores the top safe-area inset")
        XCTAssertEqual(landscapeFrame.minX, 0, accuracy: 1)
        XCTAssertEqual(landscapeFrame.maxX, host.view.bounds.maxX, accuracy: 1)
        let maxOffset = scroll.contentSize.width - scroll.bounds.width + scroll.adjustedContentInset.right
        XCTAssertEqual(scroll.contentOffset.x, maxOffset, accuracy: 2, "Live edge is at center, not at the right edge")
        let start = CameraTimelineScale.windowStart(at: TimelineFetcher.anchor, latest: TimelineFetcher.anchor)
        XCTAssertEqual(scroll.contentOffset.x + scroll.adjustedContentInset.left,
            CameraTimelineScale.offset(time: TimelineFetcher.anchor, start: start, cellWidth: thumbnailSize.width), accuracy: 2,
            "Native safe-area insets must not change the time under the marker")
        XCTAssertEqual(thumbnailSize, CameraTimelineSizing.standard)
        XCTAssertGreaterThan(scroll.contentSize.width, 72 * 64)
        XCTAssertEqual(layout.labelFrames.count, 2)
        let screenshot = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "Full-size top timeline in compact height"
        attachment.lifetime = .keepAlways; add(attachment)
        position = .canonical(TimelineFetcher.anchor - 3600, paused: true)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(scroll.contentOffset.x + scroll.adjustedContentInset.left,
            CameraTimelineScale.offset(time: TimelineFetcher.anchor - 3600, start: start, cellWidth: thumbnailSize.width), accuracy: 2)
        host.view.layoutIfNeeded()
        let history = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let historical = XCTAttachment(image: history)
        historical.name = "Timeline in History — recordings on both sides of the marker"
        historical.lifetime = .keepAlways; add(historical)
        try assertTimelineBottom(in: history, bottom: landscapeFrame.maxY)
        // One minute past a mark leaves that interval label straddling the
        // playhead. It must disappear entirely, not leave a clipped prefix.
        let mark = floor((TimelineFetcher.anchor - 3600) / 1200) * 1200
        position = .canonical(mark + 60, paused: true)
        try await Task.sleep(for: .milliseconds(500))
        let overlap = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let overlapAttachment = XCTAttachment(image: overlap)
        overlapAttachment.name = "Timeline — overlapping interval label fully hidden"
        overlapAttachment.lifetime = .keepAlways; add(overlapAttachment)
        try assertTimelineBottom(in: overlap, bottom: landscapeFrame.maxY, intervalCrossesPlayhead: true)
        position = .canonical(TimelineFetcher.anchor - 25 * 3600, paused: true)
        try await Task.sleep(for: .milliseconds(500))
        let oldTarget = TimelineFetcher.anchor - 25 * 3600
        let oldStart = CameraTimelineScale.windowStart(at: oldTarget, latest: TimelineFetcher.anchor)
        XCTAssertEqual(scroll.contentOffset.x + scroll.adjustedContentInset.left,
            CameraTimelineScale.offset(time: oldTarget, start: oldStart, cellWidth: thumbnailSize.width), accuracy: 2,
            "Rebasing to an older day keeps the timestamp under the playhead")
        let dated = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let datedAttachment = XCTAttachment(image: dated)
        datedAttachment.name = "Timeline — full date beyond 24 hours"
        datedAttachment.lifetime = .keepAlways; add(datedAttachment)
        try assertTimelineBottom(in: dated, bottom: landscapeFrame.maxY)
        let referenceSize = CameraTimelineSizing.standard
        for (count, multiple) in [(1, false), (1, true), (3, true), (4, true), (2, true)] {
            layout.count = count; layout.multiple = multiple
            let expectedSize = CameraTimelineSizing.standard
            // Geometry and ScrollPosition updates settle across separate layout
            // passes. Wait for the result, not an arbitrary 150 ms deadline.
            try await wait {
                thumbnailSize == expectedSize && abs(scroll.contentOffset.x + scroll.adjustedContentInset.left -
                    CameraTimelineScale.offset(time: oldTarget, start: oldStart, cellWidth: expectedSize.width)) < 2
            }
            XCTAssertEqual(thumbnailSize, expectedSize,
                "Timeline sizing is independent of camera count and picker mode; \(count) cameras, Multiple=\(multiple)")
            XCTAssertEqual(scroll.contentOffset.x + scroll.adjustedContentInset.left,
                CameraTimelineScale.offset(time: oldTarget, start: oldStart, cellWidth: thumbnailSize.width), accuracy: 2,
                "Changing Multiple mode preserves the instant under the playhead")
        }
        layout.controlsVisible = false
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(thumbnailSize, referenceSize, "Hidden labels cannot change the reference row")
        layout.controlsVisible = true
        for horizontal in [UIUserInterfaceSizeClass.regular, .compact] {
            host.traitOverrides.horizontalSizeClass = horizontal
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(thumbnailSize, referenceSize, "Width class does not resize the timeline")
        }
        // Changing safe areas (e.g. toolbars) must not change the reference size.
        let compactSize = thumbnailSize
        host.additionalSafeAreaInsets = UIEdgeInsets(top: 50, left: 24, bottom: 30, right: 12)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(thumbnailSize, compactSize)
        // Traits, not width>height, select the layout. Keep this wide window but
        // give it regular-height traits before switching to a narrow window.
        host.traitOverrides.verticalSizeClass = .regular
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(thumbnailSize, CameraTimelineSizing.standard)
        XCTAssertEqual(scroll.contentOffset.x + scroll.adjustedContentInset.left,
            CameraTimelineScale.offset(time: oldTarget, start: oldStart), accuracy: 2)
        let regularHeight = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let regularFrame = scroll.convert(scroll.bounds, to: host.view)
        XCTAssertEqual(regularFrame.minY, host.view.safeAreaLayoutGuide.layoutFrame.minY, accuracy: 1)
        XCTAssertEqual(regularFrame.minX, host.view.safeAreaLayoutGuide.layoutFrame.minX, accuracy: 1)
        XCTAssertEqual(regularFrame.maxX, host.view.safeAreaLayoutGuide.layoutFrame.maxX, accuracy: 1)
        try assertTimelineBottom(in: regularHeight, bottom: regularFrame.maxY,
            center: regularFrame.midX)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let portrait = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let portraitAttachment = XCTAttachment(image: portrait)
        portraitAttachment.name = "Timeline in Portrait — top safe area retained"
        portraitAttachment.lifetime = .keepAlways; add(portraitAttachment)
        let portraitFrame = scroll.convert(scroll.bounds, to: host.view)
        XCTAssertEqual(portraitFrame.minY, host.view.safeAreaLayoutGuide.layoutFrame.minY, accuracy: 1)
        XCTAssertEqual(portraitFrame.minX, host.view.safeAreaLayoutGuide.layoutFrame.minX, accuracy: 1)
        XCTAssertEqual(portraitFrame.maxX, host.view.safeAreaLayoutGuide.layoutFrame.maxX, accuracy: 1)
        try assertTimelineBottom(in: portrait, bottom: portraitFrame.maxY,
            center: portraitFrame.midX)
        XCTAssertEqual(thumbnailSize, CameraTimelineSizing.standard)
        XCTAssertEqual(scroll.contentOffset.x + scroll.adjustedContentInset.left,
            CameraTimelineScale.offset(time: oldTarget, start: oldStart), accuracy: 2,
            "Window and trait changes preserve the historical instant")
    }
    private func assertTimelineBottom(in image: UIImage, bottom: CGFloat, center: CGFloat? = nil, intervalCrossesPlayhead: Bool = false,
        file: StaticString = #filePath, line: UInt = #line) throws {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        func isYellow(x: Int, y: Int) -> Bool {
            let index = (y * width + x) * 4
            return pixels[index] > 180 && pixels[index + 1] > 140 && pixels[index + 2] < 100
        }
        let bottomRow = min(height - 1, Int((bottom * image.scale).rounded()) - 1)
        let centerColumn = Int(((center ?? image.size.width / 2) * image.scale).rounded())
        let previewIndex = ((bottomRow - Int(30 * image.scale)) * width + centerColumn + Int(10 * image.scale)) * 4
        let color = pixels[previewIndex..<previewIndex + 3].map(Int.init)
        XCTAssertGreaterThan(try XCTUnwrap(color.max()) - (try XCTUnwrap(color.min())), 25,
            "The cell under the playhead must show the fetched preview, not an unrelated lazy-layout placeholder after resizing",
            file: file, line: line)
        XCTAssertTrue(isYellow(x: centerColumn, y: bottomRow), "Yellow playhead reaches the last visible pixel", file: file, line: line)
        XCTAssertTrue(isYellow(x: centerColumn, y: bottomRow - Int(40 * image.scale)), "Yellow playhead remains above the scrolling thumbnails", file: file, line: line)
        if bottomRow + 2 < height {
            XCTAssertFalse(isYellow(x: centerColumn, y: bottomRow + 2), "Portrait playhead stops above the safe area", file: file, line: line)
        }
        // Ignore the center marker and check actual label ink, not the native
        // scroll viewport (which can extend beyond its rendered content).
        let lastLabelRow = (max(0, bottomRow - 20)...bottomRow).last { y in
            (20..<width / 2 - 10).contains { x in isYellow(x: x, y: y) }
        }
        let labelRow = try XCTUnwrap(lastLabelRow)
        XCTAssertLessThanOrEqual(bottomRow - labelRow, 2, "Time labels sit within two pixels of the bottom", file: file, line: line)
        let labelRows = max(0, bottomRow - Int(10 * image.scale))...bottomRow
        let currentTimeColumns = centerColumn + Int(6 * image.scale)..<min(width, centerColumn + Int(100 * image.scale))
        XCTAssertTrue(labelRows.contains { y in currentTimeColumns.contains { x in isYellow(x: x, y: y) } },
            "Current playback time is yellow alongside the interval labels", file: file, line: line)
        let trailingLabels = min(width, centerColumn + Int(120 * image.scale))..<width
        XCTAssertFalse(labelRows.contains { y in trailingLabels.contains { x in isYellow(x: x, y: y) } },
            "No interval labels remain to the right of the timestamp", file: file, line: line)
        if intervalCrossesPlayhead {
            let overlapColumns = centerColumn - Int(20 * image.scale)..<centerColumn - Int(2 * image.scale)
            XCTAssertFalse(labelRows.contains { y in overlapColumns.contains { x in isYellow(x: x, y: y) } },
                "A crossing label is fully hidden, including the part left of the playhead", file: file, line: line)
        }
    }
    private func findScroll(in view: UIView) -> UIScrollView? {
        (view as? UIScrollView) ?? view.subviews.lazy.compactMap { self.findScroll(in: $0) }.first
    }
#endif
    private func sampleJPEG(width: Int = 320, height: Int = 180) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.15, green: 0.4, blue: 0.65, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.85, green: 0.6, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 80, y: 30, width: 90, height: 120))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

private struct TimelineSizingProbe: View {
    @Environment(\.cameraTimelineThumbnailSize) private var size
    let changed: (CGSize) -> Void
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: size, initial: true) { _, size in changed(size) }
    }
}

#if os(iOS)
@MainActor private final class TimelineTestPanelState: ObservableObject {
    @Published var active = false
    @Published var presented = false
    nonisolated deinit {}
}

private struct TimelineTestPanel<Content: View>: View {
    @ObservedObject var state: TimelineTestPanelState
    @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack {
            Color.black
            CameraLiveGestureSurface(videoVisible: true, cameraControlsEnabled: true,
                onPan: { _, _, _ in }, onMagnify: nil, onSingleTap: {}, onTwoFingerTap: {})
        }
        .overlay(alignment: .bottom) {
            CameraTimelinePanel(
                isPresented: state.presented,
                isActive: state.active,
                content: content
            )
        }
    }
}

private struct TimelineTestPlacement<Content: View>: View {
    let edge: CameraTimelinePlacementEdge
    @ViewBuilder let content: () -> Content

    init(
        edge: CameraTimelinePlacementEdge = .bottom,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.edge = edge
        self.content = content
    }

    var body: some View {
        CameraTimelinePlacement(edge: edge, content: content)
    }
}

/// Mount the production canvas/label layouts without media sessions or cameras.
@MainActor private final class TimelineTestLayout: ObservableObject {
    @Published var count = 2
    @Published var multiple = true
    @Published var controlsVisible = true
    var labelFrames: [Int: CGRect] = [:]
    var paneFrames: [Int: CGRect] = [:]
    // Value-only fixture: no actor-bound teardown. Avoid the iOS simulator's
    // isolated-deinit runtime crash when UIKit releases the hosting view.
    nonisolated deinit {}
}

private struct TimelineTestCanvas: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ObservedObject var layout: TimelineTestLayout
    var body: some View {
        let ignoresSafeArea = CameraGroupLayout.ignoresSafeArea(
            horizontal: horizontalSizeClass, vertical: verticalSizeClass
        )
        CameraGroupCanvas(ignoresSafeArea: ignoresSafeArea) { size, safe in
            let arrangement = CameraGroupLayout.arrangement(count: layout.count, in: size)
            let cells = CameraGroupLayout.cells(count: layout.count, in: size, arrangement: arrangement)
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(cells.indices, id: \.self) { index in
                    let cell = cells[index]
                    let gravity = CameraGroupLayout.videoGravity(
                        index: index,
                        count: layout.count,
                        arrangement: arrangement
                    )
                    let labelAnchor = CameraGroupLayout.labelAnchor(
                        index: index,
                        arrangement: arrangement
                    )
                    let video = CameraGroupLayout.videoFrame(
                        in: CGRect(origin: .zero, size: cell.size),
                        aspectRatio: 16 / 9,
                        gravity: gravity
                    )
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(index.isMultiple(of: 2) ? Color.blue.opacity(0.4) : Color.teal.opacity(0.4))
                            .frame(width: video.width, height: video.height)
                            .position(x: video.midX, y: video.midY)
                        if layout.count > 1 && layout.controlsVisible {
                            CameraGroupLabelLayout(safeBounds: safe.offsetBy(dx: -cell.minX, dy: -cell.minY),
                                aspectRatio: 16 / 9,
                                belowVideo: CameraGroupLayout.labelsBelowVideo(count: layout.count, arrangement: arrangement),
                                gravity: gravity,
                                anchor: labelAnchor) {
                                CameraGroupCameraLabelContainer(
                                    name: "Camera \(index + 1)",
                                    anchor: labelAnchor
                                )
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { layout.labelFrames[index] = $0 }
                            }
                        }
                    }
                    .frame(width: cell.width, height: cell.height)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { layout.paneFrames[index] = $0 }
                    .position(x: cell.midX, y: cell.midY)
                }
            }
        }
    }
}
#endif

private actor TimelineFetcher: CameraThumbnailFetching {
    static let anchor = 1_700_000_100.0
    var requests: [HBNVRThumbnailRequest] = []
    var availability: [HBNVRMediaRequest] = []
    var closed = false
    var maximumActive = 0
    private var active = 0
    let unsupported: Bool, rejectLive: Bool, availabilityDelay: Duration, delay: Duration, jpeg: Data?
    let jpegWidth: Int
    init(unsupported: Bool = false, rejectLive: Bool = false, availabilityDelay: Duration = .zero,
         delay: Duration = .zero, jpeg: Data? = nil, jpegWidth: Int = 320) {
        self.unsupported = unsupported; self.rejectLive = rejectLive
        self.availabilityDelay = availabilityDelay; self.delay = delay; self.jpeg = jpeg
        self.jpegWidth = jpegWidth
    }
    func start() {}
    func close() { closed = true }
    func fetch(_ request: HBNVRMediaRequest, onBegin: CameraHistoryBeginHandler?) async throws -> CameraHistoryBatch {
        availability.append(request)
        if rejectLive, request.relativeTo == "live" { throw CameraHistoryError.remote(3, "No live frame") }
        if availabilityDelay != .zero { try await Task.sleep(for: availabilityDelay) }
        return CameraHistoryBatch(id: UUID(), range: .init(start: Self.anchor - 0.001, end: Self.anchor),
            anchor: Self.anchor, pieces: [], gaps: [])
    }
    func thumbnail(_ request: HBNVRThumbnailRequest) async throws -> CameraThumbnail? {
        requests.append(request); active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if unsupported { throw CameraThumbnailError.unsupported }
        // Deliberately survive cancellation to exercise generation rejection.
        try? await Task.sleep(for: delay)
        return jpeg.map { CameraThumbnail(data: $0, width: jpegWidth, height: 180, timestamp: request.timestamp) }
    }
}
