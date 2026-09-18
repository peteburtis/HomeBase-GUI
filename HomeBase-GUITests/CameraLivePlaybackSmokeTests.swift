import AVFoundation
import HomeBaseProtocol
import XCTest
@testable import HomeBase_GUI

/// Explicit opt-in: consumes live camera video but never changes camera controls,
/// recording intent, pairing, or server configuration, and never saves footage.
@MainActor
final class CameraLivePlaybackSmokeTests: XCTestCase {
    func testLiveCameraPauseSeekAndReturnToLive() async throws {
        guard let url = ProcessInfo.processInfo.environment["HB_LIVE_PLAYBACK_SMOKE_URL"],
              let endpoint = HomeBasePairingCode.endpoint(from: url) else {
            throw XCTSkip("Supply HB_LIVE_PLAYBACK_SMOKE_URL to access live cameras explicitly.")
        }
        let client = HomeBaseWebSocketClient(endpoint: endpoint)
        do {
            try await client.connect()
            let topology = try await client.listTopology()
            let cameras = CameraVideoCatalog.cameras(in: topology.devices)
            XCTAssertFalse(cameras.isEmpty)
            for camera in cameras {
                let playback = CameraLivePlaybackController()
                let model = CameraLiveVideoModel(
                    deviceIdentifier: camera.device.addressableName,
                    quality: camera.capability.previewQuality,
                    client: client, playbackController: playback
                )
                let stream = Task { await model.run() }
                do {
                    try await eventually("\(camera.device.displayName): receive live video") { playback.canControlPlayback }
                    try await eventually("\(camera.device.displayName): collect buffer while Live") {
                        playback.timeline.entries.count > 10
                    }
                    XCTAssertTrue(playback.isLive)
                    playback.togglePause()
                    let pausedPosition = playback.timeline.position
                    try await eventually("\(camera.device.displayName): fill paused buffer") {
                        (playback.timeline.head ?? 0) - (pausedPosition ?? 0) >= 5
                            && playback.timeline.entries.count > 10
                    }
                    XCTAssertTrue(playback.isPaused)
                    XCTAssertEqual(playback.timeline.position, pausedPosition)
                    XCTAssertGreaterThan(playback.timeline.retainedBytes, 0)
                    let middle = (playback.timeline.tail! + playback.timeline.head!) / 2
                    playback.seek(by: middle - playback.timeline.position!)
                    XCTAssertTrue(playback.isPaused)
                    XCTAssertEqual(playback.timeline.position!, middle, accuracy: 0.001)
                    try await eventually("\(camera.device.displayName): display buffered seek") { playback.renderer.layer.isReadyForDisplay }
                    XCTAssertNil(playback.errorMessage)
                    XCTAssertNotEqual(playback.renderer.layer.sampleBufferRenderer.status, .failed)
                    // Exercise standalone buffering even on a server with an
                    // NVR; this does not change the server or request history.
                    playback.seek(by: -30)
                    try await Task.sleep(for: .milliseconds(100))
                    XCTAssertEqual(playback.timeline.position, playback.timeline.tail)
                    XCTAssertFalse(playback.canSeekBackward)
                    playback.seek(by: 30)
                    XCTAssertTrue(playback.isPaused)
                    let pausedAtHead = playback.timeline.position
                    try await eventually("\(camera.device.displayName): stay paused at former live head") {
                        playback.timeline.head! > pausedAtHead! + 0.2
                    }
                    XCTAssertEqual(playback.timeline.position, pausedAtHead)
                    playback.seek(by: -30)
                    playback.togglePause()
                    let playingPosition = playback.timeline.position!
                    try await eventually("\(camera.device.displayName): advance playback") { playback.timeline.position! > playingPosition + 0.2 }
                    XCTAssertTrue(playback.canSeekBackward)
                    XCTAssertFalse(playback.isLive)
                    playback.seek(by: 30)
                    XCTAssertTrue(playback.isLive)
                    let retainedCount = playback.timeline.entries.count
                    XCTAssertGreaterThan(retainedCount, 10)
                    try await eventually("\(camera.device.displayName): keep collecting after returning Live") {
                        playback.timeline.entries.count > retainedCount + 5
                    }
                    try await eventually("\(camera.device.displayName): resynchronize live") { playback.renderer.layer.isReadyForDisplay }
                    playback.seek(by: -3)
                    XCTAssertFalse(playback.isLive)
                    try await eventually("\(camera.device.displayName): rewind directly from Live") { playback.renderer.layer.isReadyForDisplay }
                    playback.goLive()
                    XCTAssertGreaterThan(playback.timeline.retainedBytes, 0)
                    XCTAssertNil(playback.errorMessage)
                    print("Live buffer smoke passed: \(camera.device.displayName)")
                } catch {
                    print("Smoke diagnostics: model=\(model.state), mode=\(playback.mode), head=\(String(describing: playback.timeline.head)), position=\(String(describing: playback.timeline.position)), frames=\(playback.timeline.entries.count), renderer=\(playback.renderer.layer.sampleBufferRenderer.status.rawValue), ready=\(playback.renderer.isReadyForMoreMediaData), error=\(playback.errorMessage ?? "none")")
                    stream.cancel()
                    await model.stop()
                    await stream.value
                    playback.close()
                    throw error
                }
                stream.cancel()
                await model.stop()
                await stream.value
                XCTAssertGreaterThan(playback.timeline.retainedBytes, 0)
                playback.close()
                XCTAssertFalse(playback.canControlPlayback)
                XCTAssertEqual(playback.timeline.retainedBytes, 0)
            }
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
    }

    private func eventually(_ phase: String, _ condition: () -> Bool) async throws {
        print("Live smoke: \(phase)")
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !condition() {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                XCTFail("\(phase) did not reach the expected state within 15 seconds")
                throw SmokeFailure.timeout
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private enum SmokeFailure: Error { case timeout }
}
