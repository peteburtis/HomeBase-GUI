import Foundation
import HomeBaseProtocol
import SwiftUI
import XCTest
#if os(iOS)
import UIKit
#endif
@testable import HomeBase_GUI

@MainActor
final class CameraHiddenNavigationTests: XCTestCase {
    private let camera = UUID().uuidString
    private let visible = CameraHistoryNeighbors(previous: .init(start: 100, end: 120), next: .init(start: 180, end: 200))

    func testVeiledAndMissingStretchesShareOneNavigationRegion() async throws {
        let history = CameraHistoryPlayback()
        defer { history.close() }
        let source = HiddenNavigationSource()
        history.configure(cameraID: camera, transport: source)
        history.enterGroup(time: 130, liveEdge: 1000, localHead: 0, paused: true)
        try await settle(history)
        XCTAssertEqual(history.state, .ready, "Hidden frames stay available to the decoder")
        XCTAssertTrue(history.hasNavigationRegion)
        XCTAssertEqual(history.navigation, .ready(visible))
        for time in [135.0, 145, 155] {
            history.followGroup(time: time, liveEdge: 1000, paused: true)
            try await settle(history)
            XCTAssertEqual(history.navigation, .ready(visible))
            XCTAssertEqual(history.adjacentRecording(previous: true), Date(timeIntervalSince1970: 100))
            XCTAssertEqual(history.adjacentRecording(previous: false), Date(timeIntervalSince1970: 180))
        }
        let filters = await source.filters
        XCTAssertEqual(filters, [true], "Crossing hidden → missing → hidden reuses the same unavailable region")
        XCTAssertEqual(history.position, 155)
        XCTAssertTrue(history.isPaused)
    }

    func testRevealInvalidatesFilteredNeighborsAndUsesOrdinaryNavigationInGaps() async throws {
        let history = CameraHistoryPlayback()
        defer { history.close() }
        let source = HiddenNavigationSource()
        history.configure(cameraID: camera, transport: source)
        history.enterGroup(time: 130, liveEdge: 1000, localHead: 0, paused: true)
        try await settle(history)
        history.setShowsHiddenVideo(true)
        XCTAssertFalse(history.hasNavigationRegion)
        XCTAssertEqual(history.navigation, .idle)
        XCTAssertNil(history.adjacentRecording(previous: false))
        history.followGroup(time: 145, liveEdge: 1000, paused: true)
        try await settle(history)
        XCTAssertEqual(history.navigation, .ready(.init(previous: .init(start: 100, end: 140), next: .init(start: 150, end: 200))))
        history.setShowsHiddenVideo(false)
        try await settle(history)
        XCTAssertEqual(history.navigation, .ready(visible))
        let filters = await source.filters
        XCTAssertEqual(filters, [true, false, true])
        XCTAssertEqual(history.position, 145)
    }

    func testRevealCancelsAnObsoleteFilteredReplyWithoutMovingPlayback() async throws {
        let history = CameraHistoryPlayback()
        defer { history.close() }
        let source = HiddenNavigationSource(neighborDelay: .milliseconds(50))
        history.configure(cameraID: camera, transport: source)
        history.enter(canonicalTime: 145, localHead: 0, paused: true)
        for _ in 0..<100 {
            if history.navigation == .loading { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(history.navigation, .loading)
        history.setShowsHiddenVideo(true)
        try await settle(history)
        let filters = await source.filters
        XCTAssertEqual(filters, [true, false])
        XCTAssertEqual(history.navigation, .ready(.init(previous: .init(start: 100, end: 140), next: .init(start: 150, end: 200))))
        XCTAssertEqual(history.position, 145)
        XCTAssertTrue(history.isPaused)
    }

    func testLiveAndBufferedVeilProbesDoNotActivateHistoryOrFetchVideo() async throws {
        for position in [70.0, 100] {
            let history = CameraHistoryPlayback()
            let source = HiddenNavigationSource()
            history.configure(cameraID: camera, transport: source)
            history.updateBufferNavigation(position: position, head: 100)
            try await settle(history)
            XCTAssertFalse(history.isActive)
            XCTAssertNil(history.position)
            XCTAssertEqual(history.state, .idle)
            XCTAssertEqual(history.navigation, .ready(visible))
            XCTAssertEqual(history.adjacentRecording(previous: true), Date(timeIntervalSince1970: 100))
            let requests = await source.requests
            XCTAssertEqual(requests.map(\.operation), ["neighbors"])
            XCTAssertEqual(requests.first?.relativeTo, "live")
            history.updateBufferNavigation(position: nil, head: 100)
            XCTAssertEqual(history.navigation, .idle)
            XCTAssertNil(history.adjacentRecording(previous: true))
            history.close()
        }
    }

    func testNavigationFailureAndUnsupportedServersDoNotBecomeArchiveEnds() async throws {
        for error in [CameraHistoryError.unavailable, .hiddenNeighborsUnsupported] {
            let history = CameraHistoryPlayback()
            let source = HiddenNavigationSource(neighborError: error)
            history.configure(cameraID: camera, transport: source)
            history.enter(canonicalTime: 130, localHead: 0, paused: true)
            try await settle(history)
            if error == .hiddenNeighborsUnsupported { XCTAssertEqual(history.navigation, .hiddenUnsupported) }
            else if case .failed = history.navigation {} else { XCTFail("Search failure is not confirmed absence") }
            XCTAssertEqual(history.state, .ready)
            XCTAssertNil(history.adjacentRecording(previous: false))
            history.close()
        }
    }

    func testFailedLiveProbeCanLearnAnAnchorWithoutCreatingAPlaybackCursor() async throws {
        let history = CameraHistoryPlayback()
        defer { history.close() }
        let source = HiddenNavigationSource(neighborError: .unavailable)
        history.configure(cameraID: camera, transport: source)
        history.updateBufferNavigation(position: 100, head: 100)
        try await settle(history)
        XCTAssertEqual(history.canonicalOffset, 50)
        XCTAssertFalse(history.isActive)
        XCTAssertNil(history.position)
        XCTAssertEqual(history.state, .idle)
        guard case .failed = history.navigation else { return XCTFail("A failed search cannot confirm absence") }
        for _ in 0..<10 { history.updateBufferNavigation(position: 100, head: 100) }
        let requests = await source.requests
        XCTAssertEqual(requests.count, 1, "A failed live probe must respect its retry interval after resolving its range")
    }

    func testFilteredFallbackQueriesBothSourcesWithTheHiddenFilter() async throws {
        let local = HiddenNavigationSource(), cloud = HiddenNavigationSource()
        let fallback = CameraHistoryFallback(local: local, remote: cloud)
        let request = HBNVRMediaRequest(requestID: "local-only", operation: "neighbors", cameraID: camera,
            range: .init(start: 145, end: 145.001))
        let filtered = try await fallback.neighbors(request, excludingHidden: true)
        XCTAssertEqual(filtered.neighbors, visible)
        XCTAssertNil(filtered.sourceWarning)
        let cloudRequests = await cloud.requests
        XCTAssertEqual(cloudRequests.map(\.operation), ["neighbors"])
        let filters = await cloud.filters
        XCTAssertEqual(filters, [true], "Cloud searches use the same hidden filter as local searches")
        let ordinary = try await fallback.neighbors(request, excludingHidden: false)
        XCTAssertEqual(ordinary.neighbors, .init(previous: .init(start: 100, end: 140), next: .init(start: 150, end: 200)))
        XCTAssertNil(ordinary.sourceWarning)
        await fallback.close()
    }

    func testCloudSearchFailureKeepsLocalNavigationUsableWithoutBecomingAMediaFailure() async throws {
        let history = CameraHistoryPlayback()
        defer { history.close() }
        let fallback = CameraHistoryFallback(local: HiddenNavigationSource(), remote: HiddenNavigationSource(neighborError: .unavailable))
        history.configure(cameraID: camera, transport: fallback)
        history.enterGroup(time: 130, liveEdge: 1000, localHead: 0, paused: true)
        try await settle(history)
        guard case .partial(let neighbors, _) = history.navigation else { return XCTFail("S3 coverage must stay explicitly unknown") }
        XCTAssertEqual(neighbors, visible)
        XCTAssertEqual(history.adjacentRecording(previous: false), Date(timeIntervalSince1970: 180))
        history.followGroup(time: 170, liveEdge: 1000, paused: true)
        XCTAssertEqual(history.state, .loading, "The navigation scope note must not become a media error")
    }

    func testJumpFromVeiledHistoryPreservesPauseAndSpeed() async throws {
        for paused in [false, true] {
            for previous in [false, true] {
                let controller = CameraLivePlaybackController(clock: { 0 })
                controller.setNVRHistoryAvailable(true)
                controller.history.configure(cameraID: camera, transport: HiddenNavigationSource())
                controller.seek(to: Date(timeIntervalSince1970: 130), paused: paused)
                try await settle(controller.history)
                XCTAssertTrue(controller.isVeiled)
                controller.setPlaybackSpeed(.double)
                controller.seekToAdjacentRecording(previous: previous)
                XCTAssertEqual(controller.playbackDate, Date(timeIntervalSince1970: previous ? 100 : 180))
                XCTAssertEqual(controller.isPaused, paused)
                XCTAssertEqual(controller.playbackSpeed, .double)
                XCTAssertTrue(controller.isUsingHistory)
                controller.close()
            }
        }
    }

#if os(iOS)
    func testVeiledNavigationRendersInPortraitAndLandscape() async throws {
        let controller = CameraLivePlaybackController(clock: { 0 })
        defer { controller.close() }
        controller.setNVRHistoryAvailable(true)
        controller.history.configure(cameraID: camera, transport: HiddenNavigationSource())
        controller.seek(to: Date(timeIntervalSince1970: 130), paused: true)
        try await settle(controller.history)
        XCTAssertTrue(controller.isVeiled)
        XCTAssertEqual(controller.historyNavigation, .ready(visible))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for size in [CGSize(width: 393, height: 700), CGSize(width: 852, height: 320)] {
            let view = CameraVeilCover(showsLabel: false).overlay {
                CameraHistoryStatus(playback: controller, timeZone: TimeZone(secondsFromGMT: 0)!) { previous in
                    controller.seekToAdjacentRecording(previous: previous)
                }
            }.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark)
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: view)
            host.safeAreaRegions = []
            window.rootViewController = host
            window.frame = CGRect(origin: .zero, size: size)
            window.makeKeyAndVisible()
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
            }
            window.isHidden = true; window.rootViewController = nil
            let attachment = XCTAttachment(image: image)
            attachment.name = "Hidden-navigation-\(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
#endif

    private func settle(_ history: CameraHistoryPlayback) async throws {
        for _ in 0..<300 {
            if !history.fetching { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Navigation did not settle")
    }
}

private actor HiddenNavigationSource: CameraHistoryFetching {
    private(set) var requests: [HBNVRMediaRequest] = []
    private(set) var filters: [Bool] = []
    let neighborDelay: Duration
    let neighborError: CameraHistoryError?
    init(neighborDelay: Duration = .zero, neighborError: CameraHistoryError? = nil) {
        self.neighborDelay = neighborDelay; self.neighborError = neighborError
    }
    func start() {}
    func close() {}
    func neighbors(_ request: HBNVRMediaRequest, excludingHidden: Bool) async throws -> CameraHistoryBatch {
        requests.append(request); filters.append(excludingHidden)
        // Deliberately complete even after cancellation to exercise generation guards.
        try? await Task.sleep(for: neighborDelay)
        let offset = request.relativeTo == nil ? 0.0 : 150.0
        if let neighborError {
            if request.relativeTo != nil {
                throw CameraHistoryFetchFailure(underlying: neighborError,
                    range: .init(start: request.range.start + offset, end: request.range.end + offset), anchor: offset)
            }
            throw neighborError
        }
        return .init(id: UUID(), range: .init(start: request.range.start + offset, end: request.range.end + offset),
            anchor: request.relativeTo == nil ? nil : 150, pieces: [], gaps: [],
            neighbors: excludingHidden
                ? .init(previous: .init(start: 100, end: 120), next: .init(start: 180, end: 200))
                : .init(previous: .init(start: 100, end: 140), next: .init(start: 150, end: 200)))
    }
    func fetch(_ request: HBNVRMediaRequest, onBegin: CameraHistoryBeginHandler?) async throws -> CameraHistoryBatch {
        if request.operation == "neighbors" { return try await neighbors(request, excludingHidden: false) }
        requests.append(request)
        let offset = request.relativeTo == nil ? 0.0 : 1000.0
        let range = CameraHistoryRange(start: request.range.start + offset, end: request.range.end + offset)
        if request.operation == "availability" {
            return .init(id: UUID(), range: range, anchor: 1000, pieces: [], gaps: [range])
        }
        let segment = CameraHistorySegment(number: 0, range: .init(start: 100, end: 200),
            time: .init(canonicalUTC: 100, receivedUTC: 100, cameraUTC: nil, canonicalSource: "received", epochID: "hidden"),
            timescale: 1, codec: "H264", parameterSets: [Data([7]), Data([8])], nalUnitLengthBytes: 4)
        let samples: [CameraHistorySample] = (0..<100).map { index in
            .init(frame: .init(segment: 0, presentationTicks: Int64(index), decodeTicks: nil, durationTicks: 1,
                keyFrame: true, preroll: false, byteCount: 5), data: Data([0, 0, 0, 1, 0x65]),
                isHidden: (20..<80).contains(index))
        }
        return .init(id: UUID(), range: range, anchor: request.relativeTo == nil ? nil : 1000,
            pieces: [.init(id: UUID(), segment: segment, samples: samples)],
            gaps: [CameraHistoryRange(start: 140, end: 150)].compactMap { $0.intersection(range) })
    }
}
