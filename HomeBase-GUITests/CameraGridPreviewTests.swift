import CoreGraphics
import Foundation
import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraGridPreviewTests: XCTestCase {
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
        case .missing:
            return nil
        case .unsupported:
            throw CameraThumbnailError.unsupported
        case .failure:
            throw URLError(.networkConnectionLost)
        }
    }
}
