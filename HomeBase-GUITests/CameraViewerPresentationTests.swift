#if os(iOS)
import Combine
import SwiftUI
import UIKit
import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraViewerPresentationTests: XCTestCase {
    func testOnlyTheCurrentViewerWithActiveExternalVideoCanMinimize() async throws {
        let viewer = CameraViewerPresentation()
        let id = UUID()
        XCTAssertFalse(viewer.minimize(viewerID: id, externalOutputActive: true))
        let (client, camera) = try fixture()
        viewer.open(device: camera.device, quality: .high, client: client, viewerID: id)
        XCTAssertTrue(viewer.isPresented)
        XCTAssertFalse(viewer.minimize(viewerID: UUID(), externalOutputActive: true))
        XCTAssertFalse(viewer.minimize(viewerID: id, externalOutputActive: false))
        XCTAssertTrue(viewer.minimize(viewerID: id, externalOutputActive: true))
        XCTAssertTrue(viewer.isMinimized)
        XCTAssertFalse(viewer.isPresented)
        XCTAssertEqual(viewer.request?.id, id)
        XCTAssertFalse(viewer.minimize(viewerID: id, externalOutputActive: true))
        viewer.restore()
        XCTAssertTrue(viewer.isPresented)
        XCTAssertEqual(viewer.request?.id, id)
        viewer.close()
        viewer.restore()
        XCTAssertNil(viewer.request)
        XCTAssertFalse(viewer.isPresented)
        XCTAssertFalse(viewer.isMinimized)
    }

    func testRegistrationWithoutAConnectedVisibleOutputCannotEnableMinimize() async throws {
        let (client, camera) = try fixture()
        let group = CameraGroupPlayback(client: client,
            initialSession: CameraGroupSession(camera: camera, client: client))
        let output = CameraExternalDisplayPresentation()
        defer { output.clear(); group.deactivate() }
        output.update(group: group, isVisible: true)
        XCTAssertFalse(output.isOutputActive)
        let connection = UUID()
        output.outputConnected(connection)
        XCTAssertTrue(output.isOutputActive)
        output.update(group: group, isVisible: false)
        XCTAssertFalse(output.isOutputActive)
        output.update(group: group, isVisible: true)
        XCTAssertTrue(output.isOutputActive)
        output.outputDisconnected(connection)
        XCTAssertFalse(output.isOutputActive)
        output.outputConnected(connection)
        output.clear()
        XCTAssertFalse(output.isOutputActive)
    }

    func testNativeTabBadgeCountsOnlyMinimizedExternalVideoAndIgnoresOldViewers() async throws {
        let (client, camera) = try fixture()
        let viewer = CameraViewerPresentation()
        viewer.open(device: camera.device, quality: .high, client: client)
        let id = try XCTUnwrap(viewer.request?.id)
        viewer.updateExternalOutput(viewerID: id, cameraCount: 4)
        XCTAssertEqual(viewer.camerasBadgeCount, 0, "Both screens visible: no badge")
        viewer.minimize(viewerID: id, externalOutputActive: true)
        XCTAssertEqual(viewer.camerasBadgeCount, 4)
        viewer.updateExternalOutput(viewerID: id, cameraCount: 3)
        XCTAssertEqual(viewer.camerasBadgeCount, 3)
        viewer.updateExternalOutput(viewerID: id, cameraCount: 0)
        XCTAssertEqual(viewer.camerasBadgeCount, 0, "Disconnected/hidden output: no badge")
        viewer.updateExternalOutput(viewerID: id, cameraCount: 4)
        viewer.restore()
        XCTAssertEqual(viewer.camerasBadgeCount, 0)
        viewer.minimize(viewerID: id, externalOutputActive: true)
        XCTAssertEqual(viewer.camerasBadgeCount, 4)
        viewer.close()
        XCTAssertEqual(viewer.camerasBadgeCount, 0)
        viewer.open(device: camera.device, quality: .high, client: client)
        viewer.minimize(viewerID: try XCTUnwrap(viewer.request?.id), externalOutputActive: true)
        viewer.updateExternalOutput(viewerID: id, cameraCount: 4)
        XCTAssertEqual(viewer.camerasBadgeCount, 0, "A late update cannot badge a different viewer")
    }

    func testMinimizingKeepsViewStateTasksAndExternalBridgeMountedUntilClose() async throws {
        let (client, camera) = try fixture()
        let viewer = CameraViewerPresentation()
        viewer.open(device: camera.device, quality: .high, client: client)
        let requestID = try XCTUnwrap(viewer.request?.id)
        let group = CameraGroupPlayback(client: client,
            initialSession: CameraGroupSession(camera: camera, client: client))
        group.activateResources(access: nil)
        let output = CameraExternalDisplayPresentation()
        let probe = RetainedViewerProbe()
        let host = UIHostingController(rootView: AnyView(CameraRetainedViewerLayer(presentation: viewer) {
            Color.orange
        } viewer: { _ in
            RetainedViewerProbeView(probe: probe)
                .background(CameraExternalDisplayBridge(group: group, isVisible: true, presentation: output))
        }))
        let window = try makeWindow(host)
        defer { window.isHidden = true; window.rootViewController = nil; output.clear(); group.deactivate() }
        try await Task.sleep(for: .milliseconds(200))
        output.outputConnected(UUID())
        let stateID = try XCTUnwrap(probe.appearances.first)
        let session = try XCTUnwrap(group.sessions.first)
        XCTAssertTrue(output.group === group)
        XCTAssertEqual(probe.taskStarts, 1)
        for _ in 0..<3 {
            XCTAssertTrue(viewer.minimize(viewerID: requestID, externalOutputActive: output.isOutputActive))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(output.isOutputActive)
            XCTAssertTrue(output.group === group)
            XCTAssertTrue(group.sessions.first === session)
            XCTAssertEqual(probe.disappearances, 0)
            XCTAssertEqual(probe.taskCancellations, 0)
            viewer.restore()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(probe.appearances, [stateID])
            XCTAssertEqual(probe.taskStarts, 1)
        }
        viewer.close()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(output.group)
        XCTAssertFalse(output.isOutputActive)
        XCTAssertEqual(probe.disappearances, 1)
        XCTAssertEqual(probe.taskCancellations, 1)
        host.rootView = AnyView(Color.clear)
        try await Task.sleep(for: .milliseconds(100))
    }

    func testRealViewerPreservesCameraMatrixQualityAndOutputAcrossMinimizeRestore() async throws {
        if #unavailable(iOS 27.0) {
            throw XCTSkip("The current compiler/iOS 26 XCTest runtime crashes in CameraScreenSelection isolated-deinit during SwiftUI teardown. State and retained-host tests still run on iOS 26.")
        }
        let (client, camera) = try fixture()
        let viewer = CameraViewerPresentation()
        let access = try XCTUnwrap(CameraPiPTestFixture.makeAccessSession(environment: [CameraPiPTestFixture.environmentVariable: "1"]))
        let lifecycle = CameraAccessLifecycle(session: access)
        viewer.open(device: camera.device, quality: .high, client: client)
        let requestID = try XCTUnwrap(viewer.request?.id)
        let host = UIHostingController(rootView: AnyView(RetainedViewerTestTabs()
            .modifier(CameraViewerHost(presentation: viewer))
            .cameraAccessLifecycle(lifecycle)
            .environment(\.scenePhase, .active)))
        let window = try makeWindow(host)
        defer { window.isHidden = true; window.rootViewController = nil; lifecycle.reset() }
        try await Task.sleep(for: .milliseconds(350))
        func externalController(in controller: UIViewController) -> CameraExternalDisplayViewController? {
            if let result = controller as? CameraExternalDisplayViewController { return result }
            return controller.children.compactMap { externalController(in: $0) }.first
        }
        let bridge = try XCTUnwrap(externalController(in: host))
        let output = bridge.presentation
        let group = try XCTUnwrap(output.group)
        defer { output.clear(); group.deactivate() }
        let connection = UUID()
        output.outputConnected(connection)
        for camera in CameraVideoCatalog.cameras(in: [], includesArtificial: true).dropFirst() { group.toggle(camera) }
        group.setQuality(.low)
        try await Task.sleep(for: .milliseconds(650))
        // Keep actor-owned session objects until SwiftUI has drained teardown.
        // The iOS 26 runtime shipped before this compiler's isolated-deinit
        // support and crashes if XCTest's non-task run loop releases that graph.
        let retainedSessions = group.sessions
        let sessions = retainedSessions.map(ObjectIdentifier.init)
        let renderers = group.sessions.map { ObjectIdentifier($0.playback.renderer) }
        func tabBars(in view: UIView) -> [UITabBar] {
            (view as? UITabBar).map { [$0] } ?? view.subviews.flatMap { tabBars(in: $0) }
        }
        let camerasTab = try XCTUnwrap(tabBars(in: host.view).flatMap { $0.items ?? [] }.first { $0.title == "Cameras" })
        func capture(_ name: String) {
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertEqual(sessions.count, 4)
        XCTAssertTrue(group.sessions.allSatisfy { $0.liveVideo.state == .playing })
        XCTAssertEqual(viewer.externalCameraCount, 4)
        XCTAssertEqual(viewer.camerasBadgeCount, 0)
        XCTAssertNil(camerasTab.badgeValue)
        capture("External viewer — close and minimize controls")
        XCTAssertTrue(viewer.minimize(viewerID: requestID, externalOutputActive: output.isOutputActive))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(access.isUnlocked, "External video retains its existing grant while other tabs are used")
        XCTAssertTrue(output.isOutputActive)
        XCTAssertTrue(group.hasActiveExternalDisplay)
        XCTAssertEqual(viewer.camerasBadgeCount, 4)
        XCTAssertEqual(camerasTab.badgeValue, "4")
        capture("Minimized external viewer — native Cameras badge")
        XCTAssertTrue(group.sessions.allSatisfy { $0.resourcesActive && $0.liveVideo.state == .playing })
        XCTAssertTrue(group.sessions.allSatisfy { !$0.gestures.enabled })
        XCTAssertEqual(group.sessions.map(ObjectIdentifier.init), sessions)
        // Other app screens can present their own full-screen UI. Covering the
        // phone must not dismantle the minimized viewer's external accessory.
        let otherScreen = UIHostingController(rootView: Color.white)
        otherScreen.modalPresentationStyle = .fullScreen
        host.present(otherScreen, animated: false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(output.group === group)
        XCTAssertTrue(output.isOutputActive)
        XCTAssertEqual(group.sessions.map(ObjectIdentifier.init), sessions)
        host.dismiss(animated: false)
        try await Task.sleep(for: .milliseconds(150))
        viewer.restore()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(externalController(in: host) === bridge)
        XCTAssertEqual(group.quality, .low)
        XCTAssertTrue(group.isLive)
        XCTAssertEqual(viewer.camerasBadgeCount, 0)
        XCTAssertNil(camerasTab.badgeValue)
        XCTAssertEqual(group.sessions.map(ObjectIdentifier.init), sessions)
        XCTAssertEqual(group.sessions.map { ObjectIdentifier($0.playback.renderer) }, renderers)
        XCTAssertTrue(group.sessions.allSatisfy { $0.resourcesActive && $0.liveVideo.state == .playing })
        viewer.minimize(viewerID: requestID, externalOutputActive: output.isOutputActive)
        try await Task.sleep(for: .milliseconds(100))
        output.outputDisconnected(connection)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(viewer.camerasBadgeCount, 0)
        XCTAssertFalse(output.isOutputActive)
        XCTAssertFalse(group.hasActiveExternalDisplay)
        XCTAssertTrue(group.sessions.allSatisfy { !$0.resourcesActive })
        XCTAssertTrue(viewer.isMinimized)
        XCTAssertEqual(viewer.request?.id, requestID)
        viewer.restore()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(group.sessions.map(ObjectIdentifier.init), sessions)
        XCTAssertEqual(group.quality, .low)
        viewer.close()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(output.group)
        XCTAssertTrue(group.sessions.isEmpty)
        host.rootView = AnyView(Color.clear)
        try await Task.sleep(for: .milliseconds(100))
        withExtendedLifetime(retainedSessions) {}
    }

    private func fixture() throws -> (HomeBaseWebSocketClient, CameraVideoDevice) {
        let endpoint = try XCTUnwrap(HomeBasePairingCode.endpoint(from: "homebasews://127.0.0.1:1"))
        return (HomeBaseWebSocketClient(endpoint: endpoint),
                try XCTUnwrap(CameraVideoCatalog.cameras(in: [], includesArtificial: true).first))
    }

    private func makeWindow(_ host: UIViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        return window
    }
}

@MainActor
private final class RetainedViewerProbe {
    var appearances: [UUID] = []
    var disappearances = 0
    var taskStarts = 0
    var taskCancellations = 0
    nonisolated deinit {}
}

private struct RetainedViewerProbeView: View {
    let probe: RetainedViewerProbe
    @State private var identity = UUID()
    var body: some View {
        Color.black
            .onAppear { probe.appearances.append(identity) }
            .onDisappear { probe.disappearances += 1 }
            .task {
                probe.taskStarts += 1
                do { try await Task.sleep(for: .seconds(60)) }
                catch { probe.taskCancellations += 1 }
            }
    }
}

private struct RetainedViewerTestTabs: View {
    @Environment(\.cameraExternalStreamingCount) private var cameraCount
    var body: some View {
        TabView {
            NavigationStack {
                Text("The rest of the app remains available.")
                    .navigationTitle("Home")
            }
            .tabItem { Label("Home", systemImage: "house") }
            Color.black
                .tabItem { Label("Cameras", systemImage: "video") }
                .badge(cameraCount)
        }
    }
}
#endif
