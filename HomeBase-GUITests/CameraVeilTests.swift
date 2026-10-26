import XCTest
import Foundation
import HomeBaseProtocol
import LocalAuthentication
import SwiftUI
#if os(iOS)
import UIKit
#endif
@testable import HomeBase_GUI

@MainActor final class CameraVeilTests: XCTestCase {
    #if os(iOS)
    func testVeilCoverAndAdjacentControlsRenderInPortraitAndLandscape() async throws {
        for size in [CGSize(width: 393, height: 700), CGSize(width: 852, height: 320)] {
            let veil = CameraVeilSession()
            let view = CameraVeilCover()
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 12) {
                        CameraVeilButton(veil: veil)
                        CameraS3PadlockButton {}
                    }.foregroundStyle(.white).padding(16)
                }
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
            // Exercise native presentation; ImageRenderer can omit text on
            // the first offscreen render before SwiftUI has committed layout.
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: view)
            host.safeAreaRegions = []
            host.view.backgroundColor = .black
            window.rootViewController = host
            window.frame = CGRect(origin: .zero, size: size)
            window.makeKeyAndVisible()
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
            }
            veil.hide()
            window.isHidden = true
            window.rootViewController = nil
            XCTAssertEqual(image.size, size)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Veil-\(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
    #endif

    func testBiometryPreflightNeverRequestsUnknownFaceIDConsent() {
        XCTAssertFalse(CameraVeilBiometrics.shouldEvaluate(available: true, type: .faceID, knownConsent: false))
        XCTAssertTrue(CameraVeilBiometrics.shouldEvaluate(available: true, type: .faceID, knownConsent: true))
        XCTAssertTrue(CameraVeilBiometrics.shouldEvaluate(available: true, type: .touchID, knownConsent: false))
        XCTAssertFalse(CameraVeilBiometrics.shouldEvaluate(available: false, type: .touchID, knownConsent: true))
        XCTAssertFalse(CameraVeilBiometrics.shouldEvaluate(available: false, type: .none, knownConsent: false))
    }
    func testRevealFailureRetryHideAndStaleAuthentication() async {
        let auth = VeilAuthenticationStub(), veil = CameraVeilSession(authenticator: auth)
        XCTAssertFalse(veil.showsHidden)
        veil.toggle(); await Task.yield()
        XCTAssertTrue(veil.isAuthenticating); XCTAssertFalse(veil.showsHidden)
        auth.finish(false); await settle()
        XCTAssertFalse(veil.showsHidden); XCTAssertTrue(veil.authenticationFailed)
        veil.toggle(); await Task.yield(); auth.finish(true); await settle()
        XCTAssertTrue(veil.showsHidden)
        veil.toggle(); XCTAssertFalse(veil.showsHidden)
        veil.toggle(); await Task.yield()
        veil.hide() // background/dismissal must win over a delayed OS completion
        auth.finish(true); await settle()
        XCTAssertFalse(veil.showsHidden); XCTAssertFalse(veil.isAuthenticating)
    }
    private func settle() async { for _ in 0..<10 { await Task.yield() } }

    func testPresenceAndExactFrameRangesIncludingPreroll() throws {
        XCTAssertTrue(CameraVideoTags.hidden(["homebase.hidden": "false"]))
        XCTAssertFalse(CameraVideoTags.hidden([:]))
        let map = Data(#"{"homebase.hidden":[{"startFrame":0,"endFrame":2,"value":"true"},{"startFrame":3,"endFrame":4,"value":""}]}"#.utf8)
        let hidden = try CameraVideoTags.hiddenFrames(map, count: 4)
        XCTAssertEqual(Array(hidden), [0, 1, 3])
        XCTAssertThrowsError(try CameraVideoTags.hiddenFrames(map, count: 3))
        let overlap = Data(#"{"homebase.hidden":[{"startFrame":0,"endFrame":3,"value":"true"},{"startFrame":2,"endFrame":4,"value":"true"}]}"#.utf8)
        XCTAssertThrowsError(try CameraVideoTags.hiddenFrames(overlap, count: 4))
    }

    func testHistoryParserConsumesTagChunksBeforeSamplesAndChecksFrameCount() throws {
        let camera = UUID().uuidString
        let request = HBNVRMediaRequest(requestID: "veil", operation: "frames", cameraID: camera, range: .init(start: 100, end: 104), includeTags: true)
        let tags = Data(#"{"homebase.hidden":[{"startFrame":1,"endFrame":3,"value":"true"}]}"#.utf8)
        var segment = CameraHistorySegment(number: 0, range: .init(start: 100, end: 104),
            time: .init(canonicalUTC: 100, receivedUTC: 100, cameraUTC: nil, canonicalSource: "received", epochID: "e"),
            timescale: 1, codec: "H264", parameterSets: [Data([7]), Data([8])], nalUnitLengthBytes: 4)
        segment.tagRangesVersion = 1; segment.tagByteCount = tags.count; segment.tagFrameCount = 4
        func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
        var parser = CameraHistoryResponseParser(request: request)
        try parser.text(json(["type": "begin", "requestID": "veil", "cameraID": camera, "timeline": "canonical", "range": ["start": 100, "end": 104]]))
        try parser.text(json(["type": "segment", "requestID": "veil", "segment": object(segment)]))
        let end = try json(["type": "end", "requestID": "veil", "outcome": "complete", "frames": 4])
        XCTAssertThrowsError(try parser.text(end))
        try parser.bytes(Data(tags.prefix(11))); try parser.bytes(Data(tags.dropFirst(11)))
        for i in 0..<4 {
            let bytes = Data([0, 0, 0, 1, 0x65])
            let frame = CameraHistoryFrame(segment: 0, presentationTicks: Int64(i), decodeTicks: nil, durationTicks: 1,
                keyFrame: i == 0, preroll: false, byteCount: bytes.count)
            try parser.text(json(["type": "frame", "requestID": "veil", "frame": object(frame)]))
            try parser.bytes(bytes)
            if i < 3 { XCTAssertThrowsError(try parser.text(end)) }
        }
        try parser.text(end)
        XCTAssertEqual(parser.result?.pieces.first?.samples.map(\.isHidden), [false, true, true, false])
    }

    func testS3ProspectiveFramesHistoricalOverridesAndUnknownTail() throws {
        var tags = CameraVideoTagTimeline(version: 2, changes: [
            .init(ticks: 0, frame: 0, tags: [:]),
            .init(ticks: 6001, frame: 1, tags: ["homebase.hidden": "true"])
        ], unknownFromTicks: 18001, unknownFromFrame: 3, overrides: [
            .init(start: 12000, end: 18000, key: "homebase.hidden", value: nil),
            .init(start: 24000, end: 30000, key: "homebase.hidden", value: "true")
        ])
        try tags.validate()
        XCTAssertFalse(tags.hidden(ticks: 0, frame: 0))
        XCTAssertTrue(tags.hidden(ticks: 6000, frame: 1), "Original sample ordinal wins over rounded MP4 ticks")
        XCTAssertFalse(tags.hidden(ticks: 12000, frame: 2), "Explicit removal wins over original hidden metadata")
        XCTAssertFalse(tags.hidden(ticks: 18000, frame: 3), "Unknown tail has no known hidden value")
        XCTAssertTrue(tags.hidden(ticks: 24000, frame: 4), "Historical set works over unknown state")
        tags.overrides = [.init(start: 0, end: 0, key: "homebase.hidden", value: nil)]
        XCTAssertThrowsError(try tags.validate())
    }

    func testApproximateNavigationRangesHonorChangesOverrideOrderRemovalAndUnknownTail() throws {
        let tags = CameraVideoTagTimeline(version: 2, changes: [
            .init(ticks: 0, frame: 0, tags: [:]),
            .init(ticks: 10, frame: 1, tags: ["homebase.hidden": "false"]),
            .init(ticks: 20, frame: 2, tags: [:]),
            .init(ticks: 30, frame: 3, tags: ["homebase.hidden": ""]),
            .init(ticks: 40, frame: 4, tags: [:]),
        ], unknownFromTicks: 50, unknownFromFrame: 5, overrides: [
            .init(start: 5, end: 8, key: "homebase.hidden", value: "true"),
            .init(start: 6, end: 7, key: "homebase.hidden", value: nil),
            .init(start: 45, end: 80, key: "homebase.hidden", value: "true"),
            .init(start: 52, end: 55, key: "homebase.hidden", value: nil),
            .init(start: 0, end: 60, key: "unrelated", value: "true"),
        ])
        try tags.validate()
        let spans = tags.approximateVisibleRanges(endTicks: 60)
        XCTAssertEqual(spans, [0..<5, 6..<7, 8..<10, 20..<30, 40..<45, 52..<55])
        for tick in Int64(0)..<60 {
            XCTAssertEqual(spans.contains { $0.contains(tick) }, !tags.hidden(ticks: tick, frame: nil))
        }
        XCTAssertTrue(tags.approximateVisibleRanges(endTicks: 0).isEmpty)
    }

    func testApproximateNavigationDoesNotInventHiddenTagsInLegacyUnknownMetadata() throws {
        let tags = CameraVideoTagTimeline(version: 2, changes: [], unknownFromTicks: 0, unknownFromFrame: 0,
            overrides: [.init(start: 5, end: 10, key: "homebase.hidden", value: "false")])
        try tags.validate()
        XCTAssertEqual(tags.approximateVisibleRanges(endTicks: 20), [0..<5, 10..<20])
    }
}

@MainActor private final class VeilAuthenticationStub: CameraVeilAuthenticating {
    private var continuation: CheckedContinuation<Bool, Never>?
    nonisolated deinit {}
    func authenticateIfAvailable() async -> Bool {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ value: Bool) { continuation?.resume(returning: value); continuation = nil }
    func cancel() {} // Deliberately lets the OS finish after cancellation.
}
