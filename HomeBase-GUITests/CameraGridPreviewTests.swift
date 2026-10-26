import CoreGraphics
import Foundation
import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraGridPreviewTests: XCTestCase {
    func testHiddenThumbnailReplacesPublicImageSurvivesFailureAndClearsAtPublicFootage() async throws {
        let camera = try camera("Camera", playback: true)
        let id = try playbackID(camera)
        let fetcher = GridThumbnailFetcher(outcomes: [id: [.image(timestamp: 1), .hidden, .failure, .image(timestamp: 2)]])
        let model = makeModel(fetcher)
        _ = await model.refreshOnce(cameras: [camera], using: fetcher)
        guard case .thumbnail = model.preview(for: camera.id) else { return XCTFail("Expected public thumbnail") }
        for _ in 0..<2 {
            _ = await model.refreshOnce(cameras: [camera], using: fetcher)
            guard case .hidden = model.preview(for: camera.id) else { return XCTFail("Hidden footage must remain covered") }
        }
        _ = await model.refreshOnce(cameras: [camera], using: fetcher)
        guard case .thumbnail(_, let time) = model.preview(for: camera.id) else { return XCTFail("Expected public thumbnail again") }
        XCTAssertEqual(time, 2)
    }

    func testPollIntervalIsTenSeconds() {
        XCTAssertEqual(CameraGridPreviewModel.pollingIntervalSeconds, 10)
    }

    func testRecordedCameraUsesRelativeLiveThumbnailAndOtherCameraUsesLive() async throws {
        let recorded = try camera("Recorded", playback: true)
        let direct = try camera("Direct", playback: false)
        let recordedID = try playbackID(recorded)
        let fetcher = GridThumbnailFetcher(outcomes: [
            recordedID: [.image(timestamp: 123)],
        ])
        let model = makeModel(fetcher)

        let continues = await model.refreshOnce(
            cameras: [recorded, direct],
            using: fetcher
        )
        XCTAssertTrue(continues)

        guard case .thumbnail(_, let timestamp) = model.preview(for: recorded.id) else {
            return XCTFail("The recorded camera should use its thumbnail")
        }
        XCTAssertEqual(timestamp, 123)
        guard case .live = model.preview(for: direct.id) else {
            return XCTFail("A camera without HBNVR playback should use live video")
        }
        let requests = await fetcher.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].cameraID, recordedID)
        XCTAssertEqual(requests[0].timeline, "canonical")
        XCTAssertEqual(requests[0].timestamp, -0.3)
        XCTAssertEqual(requests[0].relativeTo, "live")
        XCTAssertEqual(requests[0].size, .init(width: 320, height: 180))
    }

    func testUnsupportedThumbnailCapabilityFallsBackAllRecordedCameras() async throws {
        let first = try camera("First", playback: true)
        let second = try camera("Second", playback: true)
        let firstID = try playbackID(first)
        let secondID = try playbackID(second)
        let fetcher = GridThumbnailFetcher(outcomes: [
            firstID: [.unsupported],
            secondID: [.image(timestamp: 200)],
        ])
        let model = makeModel(fetcher)

        let continues = await model.refreshOnce(
            cameras: [first, second],
            using: fetcher
        )
        XCTAssertFalse(continues)

        for camera in [first, second] {
            guard case .live = model.preview(for: camera.id) else {
                return XCTFail("Unsupported thumbnails should select live fallback")
            }
        }
        let requests = await fetcher.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testMissingCoverageUsesLiveUntilLaterThumbnailSucceeds() async throws {
        let camera = try camera("Camera", playback: true)
        let cameraID = try playbackID(camera)
        let fetcher = GridThumbnailFetcher(outcomes: [
            cameraID: [.missing, .image(timestamp: 300)],
        ])
        let model = makeModel(fetcher)

        let firstContinues = await model.refreshOnce(
            cameras: [camera],
            using: fetcher
        )
        XCTAssertTrue(firstContinues)
        guard case .live = model.preview(for: camera.id) else {
            return XCTFail("Missing current recording coverage should use live")
        }

        let secondContinues = await model.refreshOnce(
            cameras: [camera],
            using: fetcher
        )
        XCTAssertTrue(secondContinues)
        guard case .thumbnail(_, let timestamp) = model.preview(for: camera.id) else {
            return XCTFail("A later recorded keyframe should replace live fallback")
        }
        XCTAssertEqual(timestamp, 300)
    }

    func testTransientFailureRetainsLastSuccessfulThumbnail() async throws {
        let camera = try camera("Camera", playback: true)
        let cameraID = try playbackID(camera)
        let fetcher = GridThumbnailFetcher(outcomes: [
            cameraID: [.image(timestamp: 400), .failure],
        ])
        let model = makeModel(fetcher)

        let firstContinues = await model.refreshOnce(
            cameras: [camera],
            using: fetcher
        )
        let secondContinues = await model.refreshOnce(
            cameras: [camera],
            using: fetcher
        )
        XCTAssertTrue(firstContinues)
        XCTAssertTrue(secondContinues)

        guard case .thumbnail(_, let timestamp) = model.preview(for: camera.id) else {
            return XCTFail("A transient error must not discard the last image")
        }
        XCTAssertEqual(timestamp, 400)
    }

    func testLoadedGridImageHidesAndClearsOnMetadataWithoutPollingJPEGAgain() async throws {
        let camera = try camera("Camera", playback: true), id = try playbackID(camera)
        let raw = GridThumbnailFetcher(outcomes: [id: [.image(timestamp: 123)]])
        let authority = TagAuthority(instance: UUID().uuidString, hidden: false)
        let updates = AsyncStream<HBNVRTagChange>.makeStream()
        let source = CameraTaggedHistorySource(source: raw, updates: updates.stream) { try await authority.read($0) }
        await source.observe()
        let model = CameraGridPreviewModel(makeTransport: { source }, decode: { _ in try Self.image() },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let run = Task { await model.run(cameras: [camera]) }
        defer { run.cancel() }
        for _ in 0..<1000 {
            if case .thumbnail = model.preview(for: camera.id) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard case .thumbnail(let original, _) = model.preview(for: camera.id) else { return XCTFail("Thumbnail never loaded") }
        for hidden in [true, false] {
            await authority.setHidden(hidden)
            updates.continuation.yield(.init(instanceID: UUID().uuidString, revision: 1, reset: true, ranges: []))
            for _ in 0..<1000 {
                if case .hidden = model.preview(for: camera.id), hidden { break }
                if case .thumbnail = model.preview(for: camera.id), !hidden { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            if hidden { guard case .hidden = model.preview(for: camera.id) else { return XCTFail("Expected hidden cached image") } }
            else {
                guard case .thumbnail(let image, let timestamp) = model.preview(for: camera.id) else { return XCTFail("Expected cleared cached image") }
                XCTAssertTrue(image === original); XCTAssertEqual(timestamp, 123)
            }
        }
        let reads = await raw.requests.count
        XCTAssertEqual(reads, 1)
        run.cancel(); await run.value
    }

    private func makeModel(
        _ fetcher: GridThumbnailFetcher
    ) -> CameraGridPreviewModel {
        CameraGridPreviewModel(
            makeTransport: { fetcher },
            decode: { _ in try Self.image() }
        )
    }

    private func camera(
        _ name: String,
        playback: Bool
    ) throws -> CameraVideoDevice {
        var metadata: [String: HBJSONValue] = [
            CameraLiveVideoCapability.availableMetadataKey: .bool(true),
            CameraLiveVideoCapability.qualitiesMetadataKey: .array([
                .string("low"),
                .string("high"),
            ]),
        ]
        if playback {
            metadata[HBDeviceMetadataKeys.cameraPlayback] = try HBJSONValue(
                encoding: HBCameraPlaybackMetadata(
                    nvrInstanceID: "nvr",
                    cameraID: UUID().uuidString,
                    stores: [.init(id: "local", name: "Local")]
                )
            )
        }
        let device = HBTopologyDeviceDescriptor(
            identifier: name,
            addressableName: name,
            displayName: name,
            metadata: metadata
        )
        return try XCTUnwrap(CameraVideoCatalog.cameras(in: [device]).first)
    }

    private func playbackID(_ camera: CameraVideoDevice) throws -> String {
        try XCTUnwrap(CameraPlaybackHistoryAvailability.metadata(
            in: camera.device.metadata
        )).cameraID
    }

    nonisolated private static func image() throws -> CGImage {
        let bytes = Data([0, 0, 0, 255])
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        return try XCTUnwrap(CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }
}

private actor GridThumbnailFetcher: CameraThumbnailFetching {
    enum Outcome: Sendable {
        case image(timestamp: Double)
        case hidden
        case missing
        case unsupported
        case failure
    }

    private var outcomes: [String: [Outcome]]
    private(set) var requests: [HBNVRThumbnailRequest] = []

    init(outcomes: [String: [Outcome]]) {
        self.outcomes = outcomes
    }

    func start() {}
    func close() {}

    func fetch(
        _ request: HBNVRMediaRequest,
        onBegin: CameraHistoryBeginHandler?
    ) async throws -> CameraHistoryBatch {
        throw CameraHistoryError.unavailable
    }

    func thumbnail(
        _ request: HBNVRThumbnailRequest
    ) async throws -> CameraThumbnail? {
        requests.append(request)
        var queue = outcomes[request.cameraID] ?? []
        let outcome = queue.isEmpty ? Outcome.missing : queue.removeFirst()
        outcomes[request.cameraID] = queue
        switch outcome {
        case .image(let timestamp):
            return CameraThumbnail(
                data: Data([0]),
                width: 1,
                height: 1,
                timestamp: timestamp
            )
        case .hidden:
            return CameraThumbnail(data: Data(), width: 1, height: 1, timestamp: 1.5, isHidden: true)
        case .missing:
            return nil
        case .unsupported:
            throw CameraThumbnailError.unsupported
        case .failure:
            throw URLError(.networkConnectionLost)
        }
    }
}
