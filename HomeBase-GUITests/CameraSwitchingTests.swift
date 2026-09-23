import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraSwitchingTests: XCTestCase {
    func testRetainingGroupSurvivorDoesNotReplacePresentationButAllowsSwitchBackToOriginal() async throws {
        let first = try camera("First"), second = try camera("Second")
        let selection = CameraScreenSelection(device: first.device, quality: .high)
        let id = selection.session.id
        selection.retain(second, quality: .medium)
        XCTAssertEqual(selection.session.id, id)
        XCTAssertEqual(selection.session.device.identifier, second.id)
        selection.select(first, position: .live)
        XCTAssertNotEqual(selection.session.id, id)
        XCTAssertEqual(selection.session.device.identifier, first.id)
    }
    // Keep actor-owned model teardown inside a Swift task, as in the existing
    // playback tests. iOS 26.1's isolated-deinit runtime crashes when nested
    // model deinits are invoked through XCTest's synchronous ObjC entry point.
    func testSameCameraKeepsSessionAndDifferentCameraStartsFreshLiveAtDefaultQuality() async throws {
        let first = try camera("First")
        let second = try camera("Second", qualities: ["low", "medium"])
        let selection = CameraScreenSelection(device: first.device, quality: .low)
        let original = selection.session.id
        selection.select(first, position: .canonical(500, paused: true))
        XCTAssertEqual(selection.session.id, original)
        XCTAssertEqual(selection.session.quality, .low)
        selection.select(second, position: .live)
        XCTAssertNotEqual(selection.session.id, original)
        XCTAssertEqual(selection.session.device.identifier, second.id)
        XCTAssertEqual(selection.session.quality, .automatic)
        XCTAssertEqual(selection.session.position, .live)
    }

    func testHistorySwitchPreservesTimestampAndPauseButUnavailableNVRFallsBackLive() async throws {
        let first = try camera("First")
        for paused in [true, false] {
            for history in [true, false] {
                let second = try camera("Second", history: history)
                let selection = CameraScreenSelection(device: first.device, quality: .high)
                let departure = CameraSwitchPosition.canonical(500, paused: paused)
                selection.select(second, position: departure)
                XCTAssertEqual(selection.session.position, history ? departure : .live)
            }
        }
    }

    func testRelativeSwitchUsesSourceCameraAnchorAndFreezesDepartureDuringLookup() async throws {
        let transport = SwitchAnchorTransport()
        let departure = CameraSwitchPosition.relative(cameraID: "source", offset: -30, capturedAt: 100, paused: true)
        let result = try await departure.resolve(using: transport, clock: { 102 })
        XCTAssertEqual(result, .canonical(968, paused: true))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].cameraID, "source")
        XCTAssertEqual(requests[0].operation, "availability")
        XCTAssertEqual(requests[0].relativeTo, "live")
    }

    func testMissingLiveAnchorFallsBackToNVRNow() async throws {
        let transport = SwitchAnchorTransport(rejectLive: true)
        let departure = CameraSwitchPosition.relative(cameraID: "source", offset: -60, capturedAt: 100, paused: false)
        let result = try await departure.resolve(using: transport, clock: { 103 })
        XCTAssertEqual(result, .canonical(937, paused: false))
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.relativeTo), ["live", "now"])
    }

    func testAbsoluteAndLiveSwitchDoNotQueryAnchor() async throws {
        let transport = SwitchAnchorTransport()
        for departure in [CameraSwitchPosition.live, .canonical(500, paused: false)] {
            let result = try await departure.resolve(using: transport)
            XCTAssertEqual(result, departure)
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testFailedClockLookupDoesNotSilentlyLoseHistoryPosition() async throws {
        let departure = CameraSwitchPosition.relative(cameraID: "source", offset: -30, capturedAt: 100, paused: true)
        do {
            _ = try await departure.resolve(using: SwitchAnchorTransport(anchor: nil))
            XCTFail("An unresolved clock must not silently switch to Live")
        } catch { XCTAssertEqual(error as? CameraHistoryError, .invalidResponse) }
        let task = Task {
            try await departure.resolve(using: SwitchAnchorTransport())
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled selection must not commit") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testSwitchDuringInitialHistoryConnectionKeepsRelativeSeek() async {
        let history = CameraHistoryPlayback(clock: { 100 })
        history.enter(localPosition: -45, localHead: 0, paused: true)
        XCTAssertEqual(history.switchPosition(cameraID: "source"),
            .relative(cameraID: "source", offset: -45, capturedAt: 100, paused: true))
        history.close()
        XCTAssertNil(history.switchPosition(cameraID: "source"))
    }

    func testFreshCameraAppliesCanonicalPauseStateBeforeFirstLiveFrame() async {
        for paused in [true, false] {
            let playback = CameraLivePlaybackController()
            playback.setNVRHistoryAvailable(true)
            playback.applyCameraSwitch(.canonical(500, paused: paused))
            XCTAssertTrue(playback.isUsingHistory)
            XCTAssertEqual(playback.isPaused, paused)
            XCTAssertEqual(playback.playbackDate?.timeIntervalSince1970, 500)
            XCTAssertEqual(playback.timeline.retainedBytes, 0)
            XCTAssertEqual(playback.positionForCameraSwitch(metadata: [:]), .canonical(500, paused: paused))
            playback.close()
        }
    }

    func testPickerRefreshIsSortedFiltersNonCamerasAndRetainsListOnFailure() async throws {
        let bedroom = try camera("Bedroom").device
        let living = try camera("Living Room").device
        let light = HBTopologyDeviceDescriptor(identifier: "light", addressableName: "Light", displayName: "Light")
        var shouldFail = false
        let picker = CameraPickerModel {
            if shouldFail { throw CameraHistoryError.unavailable }
            return [living, light, bedroom]
        }
        await picker.refresh()
        XCTAssertEqual(picker.cameras.map(\.device.displayName), ["Bedroom", "Living Room"])
        XCTAssertFalse(picker.isLoading)
        XCTAssertNil(picker.error)
        shouldFail = true
        await picker.refresh()
        XCTAssertEqual(picker.cameras.map(\.device.identifier), [bedroom.identifier, living.identifier])
        XCTAssertNotNil(picker.error)
        XCTAssertFalse(picker.isLoading)
    }

    private func camera(_ name: String, history: Bool = true, qualities: [String] = ["low", "high"]) throws -> CameraVideoDevice {
        var metadata: [String: HBJSONValue] = [CameraLiveVideoCapability.availableMetadataKey: .bool(true),
            CameraLiveVideoCapability.qualitiesMetadataKey: .array(qualities.map(HBJSONValue.string)),
            CameraLiveVideoCapability.streamPolicyMetadataKey: .object(["version": .integer(1)])]
        if history {
            metadata[HBDeviceMetadataKeys.cameraPlayback] = try HBJSONValue(encoding:
                HBCameraPlaybackMetadata(nvrInstanceID: "nvr", cameraID: UUID().uuidString,
                    stores: [.init(id: "local", name: "Local")]))
        }
        let device = HBTopologyDeviceDescriptor(identifier: name, addressableName: name, displayName: name, metadata: metadata)
        return try XCTUnwrap(CameraVideoCatalog.cameras(in: [device]).first)
    }
}

private actor SwitchAnchorTransport: CameraHistoryFetching {
    private(set) var requests: [HBNVRMediaRequest] = []
    let anchor: Double?
    let rejectLive: Bool
    init(anchor: Double? = 1000, rejectLive: Bool = false) { self.anchor = anchor; self.rejectLive = rejectLive }
    func start() async {}
    func close() async {}
    func fetch(_ request: HBNVRMediaRequest, onBegin: CameraHistoryBeginHandler?) async throws -> CameraHistoryBatch {
        requests.append(request)
        if rejectLive, request.relativeTo == "live" { throw CameraHistoryError.remote(3, "No live anchor") }
        return CameraHistoryBatch(id: UUID(), range: .init(start: 999, end: 1000), anchor: anchor, pieces: [], gaps: [])
    }
}
