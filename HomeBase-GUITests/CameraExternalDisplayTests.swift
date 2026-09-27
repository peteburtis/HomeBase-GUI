import AVFoundation
import HomeBaseProtocol
import SwiftUI
import XCTest
@testable import HomeBase_GUI

#if os(iOS)
@MainActor
final class CameraExternalDisplayTests: XCTestCase {
    func testPresentationSharesSelectionWithoutOwningPlaybackAndClearsOnDismissal() async throws {
        let group = try makeGroup()
        defer { group.deactivate() }
        let presentation = CameraExternalDisplayPresentation()
        let sessions = group.sessions.map(ObjectIdentifier.init)
        let renderers = group.sessions.map { ObjectIdentifier($0.playback.renderer) }
        let initialMode = group.isLive
        for visible in [true, false, true] {
            presentation.update(group: group, isVisible: visible)
            XCTAssertTrue(presentation.group === group)
            XCTAssertEqual(presentation.isVisible, visible)
            XCTAssertEqual(group.sessions.map(ObjectIdentifier.init), sessions)
            XCTAssertEqual(group.sessions.map { ObjectIdentifier($0.playback.renderer) }, renderers)
            XCTAssertEqual(group.isLive, initialMode)
            XCTAssertTrue(group.sessions.allSatisfy { $0.liveVideo.state == .idle })
        }
        presentation.clear()
        XCTAssertNil(presentation.group)
        XCTAssertFalse(presentation.isVisible)
        XCTAssertEqual(group.sessions.map(ObjectIdentifier.init), sessions)
    }

    func testLegacyDisplayUsesFrontmostViewerAndRestoresPreviousViewer() {
        let router = CameraExternalDisplayRouter()
        let first = CameraExternalDisplayPresentation(), second = CameraExternalDisplayPresentation()
        let a = UUID(), b = UUID()
        router.register(first, id: a)
        router.register(second, id: b)
        XCTAssertTrue(router.active === second)
        router.unregister(b)
        XCTAssertTrue(router.active === first)
        router.unregister(a)
        XCTAssertNil(router.active)
        router.unregister(a)
        XCTAssertNil(router.active)
    }

    func testViewerRegistrationIsScopedToAppearanceAndCanReappear() async throws {
        let group = try makeGroup()
        defer { group.deactivate() }
        let controller = CameraExternalDisplayViewController()
        controller.update(group: group, isVisible: true)
        XCTAssertNil(controller.presentation.group)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; controller.stopPresenting() }
        for _ in 0..<2 {
            window.rootViewController = controller; window.isHidden = false
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(controller.presentation.group === group)
            XCTAssertTrue(controller.presentation.isVisible)
            if #unavailable(iOS 27.0) {
                XCTAssertTrue(CameraExternalDisplayRouter.shared.active === controller.presentation)
            }
            window.isHidden = true; window.rootViewController = nil
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNil(controller.presentation.group)
            XCTAssertFalse(controller.presentation.isVisible)
        }
    }

    func testExternalMatrixDoesNotChangePhonesGestureStateOrCameraSessions() async throws {
        let group = try makeGroup(count: 4)
        defer { group.deactivate() }
        let sessions = group.sessions.map(ObjectIdentifier.init)
        group.sessions.forEach { $0.gestures.update(enabled: true) }
        let presentation = CameraExternalDisplayPresentation()
        presentation.update(group: group, isVisible: true)
        let host = UIHostingController(rootView: CameraExternalDisplayView(presentation: presentation))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func hasGestureSurface(_ view: UIView) -> Bool {
            view is CameraLiveGestureUIView || view.subviews.contains(where: hasGestureSurface)
        }
        XCTAssertFalse(hasGestureSurface(host.view))
        XCTAssertTrue(group.sessions.allSatisfy { $0.gestures.enabled })
        presentation.clear()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(group.sessions.allSatisfy { $0.gestures.enabled },
            "External pane disappearance must not stop the phone's gestures")
        XCTAssertEqual(group.sessions.map(ObjectIdentifier.init), sessions)
        XCTAssertTrue(group.sessions.allSatisfy { $0.liveVideo.state == .idle })
    }

    func testExternalMatrixUsesItsOwnDimensionsEvenWithPhoneSizeClasses() async throws {
        let group = try makeGroup(count: 4)
        group.activateResources(access: nil)
        defer { group.deactivate() }
        let presentation = CameraExternalDisplayPresentation()
        presentation.update(group: group, isVisible: true)
        let host = UIHostingController(rootView: CameraExternalDisplayView(presentation: presentation)
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.verticalSizeClass, .regular))
        let container = UIViewController()
        container.addChild(host)
        container.view.addSubview(host.view)
        host.didMove(toParent: container)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = container; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        for (size, arrangement) in [(CGSize(width: 360, height: 800), CameraGroupLayout.Arrangement.column),
                                    (CGSize(width: 960, height: 540), .grid)] {
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let snapshot = UIGraphicsImageRenderer(size: size).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: snapshot)
            attachment.name = "External matrix \(Int(size.width)) × \(Int(size.height))"
            attachment.lifetime = .keepAlways; add(attachment)
            let image = try XCTUnwrap(snapshot.cgImage)
            let cells = CameraGroupLayout.cells(count: 4, in: size, arrangement: arrangement)
            for (index, cell) in cells.enumerated() {
                let frame = CameraGroupLayout.videoFrame(in: cell, aspectRatio: 16 / 9,
                    gravity: CameraGroupLayout.videoGravity(index: index, count: 4, arrangement: arrangement))
                let pixel = try XCTUnwrap(image.cropping(to: CGRect(
                    x: (frame.minX + frame.width * 0.25) * snapshot.scale,
                    y: frame.midY * snapshot.scale, width: 1, height: 1)))
                var actual = [UInt8](repeating: 0, count: 4)
                try actual.withUnsafeMutableBytes { bytes in
                    let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                        bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                }
                let color = UIColor(try XCTUnwrap(group.sessions[index].camera.artificialFeed).color)
                    .resolvedColor(with: host.traitCollection)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
                for (actual, expected) in zip(actual.prefix(3), [r, g, b]) {
                    XCTAssertEqual(CGFloat(actual) / 255, expected, accuracy: 0.04,
                        "Camera \(index) must occupy its external-canvas cell")
                }
            }
        }
        presentation.clear()
        try await Task.sleep(for: .milliseconds(100))
        withExtendedLifetime(group) {}
    }

    func testSecondSurfaceNeverReparentsPhonesVideoLayer() async throws {
        let group = try makeGroup()
        defer { group.deactivate() }
        let model = try XCTUnwrap(group.sessions.first?.liveVideo)
        let phone = UIHostingController(rootView: AnyView(CameraLiveVideoSurface(model: model,
            allowsRetry: false, usesHistory: true, retry: {})))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let phoneWindow = UIWindow(windowScene: scene)
        phoneWindow.rootViewController = phone
        phoneWindow.isHidden = false
        phone.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let phoneParent = try XCTUnwrap(model.renderer.layer.superlayer)

        let tv = UIHostingController(rootView: AnyView(CameraLiveVideoSurface(model: model,
            allowsRetry: false, usesHistory: true, isSecondaryOutput: true, retry: {})))
        let tvWindow = UIWindow(windowScene: scene)
        tvWindow.rootViewController = tv
        tvWindow.isHidden = false
        defer {
            phone.rootView = AnyView(Color.clear)
            tv.rootView = AnyView(Color.clear)
            phoneWindow.isHidden = true; phoneWindow.rootViewController = nil
            tvWindow.isHidden = true; tvWindow.rootViewController = nil
        }
        tv.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.renderer.layer.superlayer === phoneParent)
        func videoLayers(_ layer: CALayer) -> [AVSampleBufferDisplayLayer] {
            (layer as? AVSampleBufferDisplayLayer).map { [$0] }
                ?? (layer.sublayers ?? []).flatMap(videoLayers)
        }
        let tvLayer = try XCTUnwrap(videoLayers(tv.view.layer).first)
        XCTAssertFalse(tvLayer === model.renderer.layer)
        XCTAssertEqual(videoLayers(tv.view.layer).count, 1)
        tv.rootView = AnyView(Color.clear)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.renderer.layer.superlayer === phoneParent)
        XCTAssertEqual(model.state, .idle, "Presentation must never start a camera stream")
        phone.rootView = AnyView(Color.clear)
        phoneWindow.isHidden = true; phoneWindow.rootViewController = nil
        tvWindow.isHidden = true; tvWindow.rootViewController = nil
        // Let SwiftUI release its video surfaces while their model is still
        // owned by this async test, not a later XCTest run-loop callback.
        try await Task.sleep(for: .milliseconds(100))
        withExtendedLifetime(group) {}
    }

    private func makeGroup(count: Int = 1) throws -> CameraGroupPlayback {
        let endpoint = try XCTUnwrap(HomeBasePairingCode.endpoint(from: "homebasews://127.0.0.1:1"))
        let client = HomeBaseWebSocketClient(endpoint: endpoint)
        let cameras = CameraVideoCatalog.cameras(in: [], includesArtificial: true)
        let first = CameraGroupSession(camera: try XCTUnwrap(cameras.first), client: client)
        let group = CameraGroupPlayback(client: client, initialSession: first)
        for camera in cameras.dropFirst().prefix(count - 1) { group.toggle(camera) }
        return group
    }
}
#endif

@MainActor
final class CameraDisplayOutputSpy: CameraVideoDisplayOutput {
    var needsRecovery = false
    var samples: [CMSampleBuffer] = []
    var flushes: [Bool] = []

    nonisolated deinit {}

    func enqueue(_ sample: CMSampleBuffer) { samples.append(sample) }
    func flush(removingDisplayedImage: Bool) { flushes.append(removingDisplayedImage) }
    func isHidden(at index: Int) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(samples[index], createIfNecessary: false)
            as? [[String: Any]]
        return attachments?.first?[kCMSampleAttachmentKey_DoNotDisplay as String] as? Bool == true
    }
}
