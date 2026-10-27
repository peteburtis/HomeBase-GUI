import HomeBaseProtocol
import SwiftUI
import XCTest
#if os(macOS)
import AppKit
#endif
@testable import HomeBase_GUI

final class CameraWindowTests: XCTestCase {
#if os(macOS)
    @MainActor
    func testConnectionRecoveryKeepsHistoryPlayerAndCursorMounted() async throws {
        let probe = CameraWindowPlaybackProbe()
        let camera = camera(identifier: "camera-a")
        func content(_ state: ServerConnectionModel.State, camera: CameraVideoDevice?) -> some View {
            CameraWindowContent(camera: camera, state: state, cameraName: "Camera", retry: {}) { _ in
                CameraWindowPlaybackFixture(probe: probe)
            }
        }
        let host = NSHostingView(rootView: content(.connecting, camera: nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; probe.players.forEach { $0.close() } }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(probe.players.isEmpty, "Do not create a player before discovering its camera")
        host.rootView = content(.connected, camera: camera)
        try await Task.sleep(for: .milliseconds(100))
        let playback = try XCTUnwrap(probe.players.first)
        playback.setNVRHistoryAvailable(true)
        playback.seek(to: Date(timeIntervalSince1970: 940), paused: true)
        playback.setPlaybackSpeed(.double)

        for state: ServerConnectionModel.State in [.failed("A metadata request timed out"), .connecting,
                                                   .connected, .disconnected, .connecting, .connected] {
            host.rootView = content(state, camera: camera)
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(probe.players.count, 1, "Reconnection must reuse the existing player")
            XCTAssertEqual(probe.disappearances, 0)
            XCTAssertTrue(playback.isUsingHistory)
            XCTAssertTrue(playback.isPaused)
            XCTAssertEqual(playback.playbackDate, Date(timeIntervalSince1970: 940))
            XCTAssertEqual(playback.playbackSpeed, .double)
        }
        host.rootView = content(.connected, camera: nil)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(probe.disappearances, 1, "An authoritative camera removal still closes the player")
        XCTAssertFalse(playback.isUsingHistory)
    }
#endif
    func testRequestIdentityIsStableAcrossTopologyPresentationChanges() throws {
        let server = PairedServer(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            endpoint: try XCTUnwrap(HomeBaseEndpoint(host: "homebase.local", port: 10_503))
        )
        let original = CameraWindowRequest(
            server: server,
            camera: camera(identifier: "camera-a", displayName: "Front Door")
        )
        let renamed = CameraWindowRequest(
            server: server,
            camera: camera(identifier: "camera-a", displayName: "Porch")
        )

        XCTAssertEqual(original, renamed)
        XCTAssertEqual(Set([original, renamed]).count, 1)
    }

    func testDifferentCamerasHaveIndependentWindowIdentities() throws {
        let server = PairedServer(
            endpoint: try XCTUnwrap(HomeBaseEndpoint(host: "homebase.local", port: 10_503))
        )

        XCTAssertNotEqual(
            CameraWindowRequest(server: server, camera: camera(identifier: "camera-a")),
            CameraWindowRequest(server: server, camera: camera(identifier: "camera-b"))
        )
    }

    private func camera(
        identifier: String,
        displayName: String = "Camera"
    ) -> CameraVideoDevice {
        CameraVideoDevice(
            device: HBTopologyDeviceDescriptor(
                identifier: identifier,
                addressableName: identifier,
                displayName: displayName
            ),
            capability: CameraLiveVideoCapability(qualities: [.high])
        )
    }
}

#if os(macOS)
@MainActor
private final class CameraWindowPlaybackProbe {
    var players: [CameraLivePlaybackController] = []
    var disappearances = 0
}

private struct CameraWindowPlaybackFixture: View {
    let probe: CameraWindowPlaybackProbe
    @StateObject private var playback = CameraLivePlaybackController()
    var body: some View {
        Color.black
            .onAppear { probe.players.append(playback) }
            .onDisappear { probe.disappearances += 1; playback.close() }
    }
}
#endif
