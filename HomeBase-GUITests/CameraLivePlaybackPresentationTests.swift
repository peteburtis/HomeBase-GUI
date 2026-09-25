#if os(iOS)
import Combine
import SwiftUI
import UIKit
import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraLivePlaybackPresentationTests: XCTestCase {
    func testNativePlaybackSpeedMenuSupportsAllRates() async throws {
        XCTAssertEqual(CameraPlaybackSpeed.allCases.map(\.label), ["1×", "2×", "4×"])
        for speed in CameraPlaybackSpeed.allCases {
            let host = UIHostingController(rootView: NavigationStack {
                Color.black.ignoresSafeArea().toolbar {
                    ToolbarItem(placement: .bottomBar) {
                        CameraPlaybackSpeedMenu(speed: .constant(speed))
                    }
                }
            })
            host.loadViewIfNeeded()
            host.view.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
            host.view.layoutIfNeeded()
            let menu = UIHostingController(rootView: CameraPlaybackSpeedMenu(speed: .constant(speed)))
            let size = menu.sizeThatFits(in: CGSize(width: 200, height: 100))
            XCTAssertGreaterThan(size.width, 0)
            XCTAssertGreaterThan(size.height, 0)
        }
    }

    func testGroupCanvasExpandsVideoButRetainsSafeLabelBounds() async throws {
        var measuredSize: CGSize?
        var measuredSafeBounds: CGRect?
        let host = UIHostingController(rootView: CameraGroupCanvas { size, safeBounds in
            Color.black.onAppear { measuredSize = size; measuredSafeBounds = safeBounds }
        })
        host.additionalSafeAreaInsets = UIEdgeInsets(top: 20, left: 50, bottom: 25, right: 40)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let size = try XCTUnwrap(measuredSize)
        let safe = try XCTUnwrap(measuredSafeBounds)
        XCTAssertEqual(size.width, host.view.bounds.width, accuracy: 0.5)
        XCTAssertEqual(size.height, host.view.bounds.height, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(safe.minX, 50)
        XCTAssertLessThanOrEqual(safe.maxX, size.width - 40)
        XCTAssertLessThanOrEqual(safe.maxY, size.height - 25)
        for cell in CameraGroupLayout.cells(count: 4, in: size) {
            XCTAssertTrue(safe.contains(CameraGroupLayout.labelFrame(in: cell, safeBounds: safe, aspectRatio: 16 / 9,
                labelSize: CGSize(width: 120, height: 24), belowVideo: false)))
        }
    }

    func testGroupCanvasTraitChangePreservesContentLifecycleAndStateObjectIdentity() async throws {
        let state = CameraGroupCanvasRotationState()
        let host = UIHostingController(rootView: CameraGroupCanvasRotationHarness(state: state))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))

        state.traits = .landscape
        window.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))

        state.traits = .portrait
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(state.appearances, 1)
        XCTAssertEqual(state.disappearances, 0)
        XCTAssertEqual(state.identitySamples.count, 3)
        XCTAssertEqual(Set(state.identitySamples).count, 1)
    }

    func testStatusScreenKeepsSingleTapButDisablesCameraGestures() async throws {
        let surface = CameraLiveGestureUIView()
        surface.onMagnify = { _, _ in }
        surface.videoVisible = false
        let recognizers = try XCTUnwrap(surface.gestureRecognizers)
        XCTAssertEqual(recognizers.count, 4)
        let pan = try XCTUnwrap(recognizers.compactMap { $0 as? UIPanGestureRecognizer }.first)
        let pinch = try XCTUnwrap(recognizers.compactMap { $0 as? UIPinchGestureRecognizer }.first)
        let taps = recognizers.compactMap { $0 as? UITapGestureRecognizer }
        let singleTap = try XCTUnwrap(taps.first { $0.numberOfTouchesRequired == 1 })
        let recenter = try XCTUnwrap(taps.first { $0.numberOfTouchesRequired == 2 })
        XCTAssertTrue(surface.isUserInteractionEnabled)
        XCTAssertTrue(singleTap.isEnabled)
        XCTAssertFalse(pan.isEnabled)
        XCTAssertFalse(pinch.isEnabled)
        XCTAssertFalse(recenter.isEnabled)
        // Camera capability/callback refreshes must not reactivate the background.
        surface.cameraControlsEnabled = true
        surface.onMagnify = { _, _ in }
        XCTAssertTrue(singleTap.isEnabled)
        XCTAssertFalse(pan.isEnabled)
        XCTAssertFalse(pinch.isEnabled)
        XCTAssertFalse(recenter.isEnabled)
        surface.videoVisible = true
        XCTAssertTrue(surface.isUserInteractionEnabled)
        XCTAssertTrue(recognizers.allSatisfy(\.isEnabled))
    }

    func testArrowTouchAreaDoesNotFallThroughToVideoGestureSurface() async throws {
        let interval = CameraHistoryRange(start: 100, end: 160)
        let controls = CameraHistoryNavigationControls(neighbors: .init(previous: interval, next: interval), jump: { _ in })
        let size = UIHostingController(rootView: controls).sizeThatFits(in: CGSize(width: 600, height: 240))
        let host = UIHostingController(rootView: ZStack {
            CameraLiveGestureSurface(videoVisible: true, cameraControlsEnabled: true,
                onPan: { _, _, _ in }, onMagnify: nil, onSingleTap: {}, onTwoFingerTap: {})
            controls
        }.ignoresSafeArea())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 600, height: 240)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let bounds = host.view.bounds
        let background = try XCTUnwrap(host.view.hitTest(CGPoint(x: 10, y: bounds.midY), with: nil))
        XCTAssertTrue(background is CameraLiveGestureUIView, "The uncovered video, not a screen-level recognizer, owns video taps")
        for x in [bounds.midX - size.width / 2 + 5, bounds.midX + size.width / 2 - 5] {
            // Inside each 44-point circle but outside the small chevron glyph.
            let hit = try XCTUnwrap(host.view.hitTest(CGPoint(x: x, y: bounds.midY), with: nil))
            XCTAssertFalse(hit is CameraLiveGestureUIView, "The button's visible circle must own this touch")
        }
    }

    func testHistoryNavigationRemovesMissingDirectionsAndUsesRoundTouchTargets() {
        let interval = CameraHistoryRange(start: 100, end: 160)
        let host = UIHostingController(rootView: CameraHistoryNavigationControls(
            neighbors: .init(previous: interval, next: interval), jump: { _ in }
        ))
        let proposal = CGSize(width: 1_000, height: 100)
        let both = host.sizeThatFits(in: proposal)
        XCTAssertEqual(both.height, 44, accuracy: 0.5)
        for previous in [true, false] {
            host.rootView = CameraHistoryNavigationControls(
                neighbors: .init(previous: previous ? interval : nil, next: previous ? nil : interval), jump: { _ in }
            )
            let single = host.sizeThatFits(in: proposal)
            XCTAssertEqual(single.height, 44, accuracy: 0.5)
            XCTAssertEqual(both.width - single.width, 64, accuracy: 0.5,
                "An unavailable direction removes its entire 44-point button and 20-point spacing")
        }
        host.rootView = CameraHistoryNavigationControls(neighbors: .init(previous: nil, next: nil), jump: { _ in })
        let neither = host.sizeThatFits(in: proposal)
        let label = UIHostingController(rootView: Text("No other video available").font(.callout))
            .sizeThatFits(in: proposal)
        XCTAssertEqual(neither.width, label.width, accuracy: 0.5)
        XCTAssertEqual(neither.height, label.height, accuracy: 0.5)
    }

    func testLiveHistoryButtonUsesBothModeSymbolsAndAlwaysToggles() {
        for (live, symbol) in [
            (true, "dot.radiowaves.left.and.right"),
            (false, CameraPlayerPanelPicker.historySymbol),
        ] {
            var toggleCount = 0
            let button = CameraLiveModeButton(isLive: live) { toggleCount += 1 }
            XCTAssertEqual(button.systemImage, symbol)
            XCTAssertEqual(button.title, live ? "Live" : "History")
            XCTAssertNotNil(UIImage(systemName: symbol))
            button.toggleMode()
            XCTAssertEqual(toggleCount, 1)
        }
    }

    func testToolbarArrangementAcrossPlaybackAndSizeClasses() {
        let liveCompactWidth = CameraToolbarArrangement(
            isLive: true,
            compactWidth: true,
            compactHeight: false
        )
        XCTAssertTrue(liveCompactWidth.configurationControlsInBottomTrailing)
        XCTAssertFalse(liveCompactWidth.pauseInBottomTrailing)
        XCTAssertFalse(liveCompactWidth.navigationItemsInBottomToolbar)
        XCTAssertTrue(liveCompactWidth.recordInTrailingNavigationBar)
        XCTAssertFalse(liveCompactWidth.recordInBottomTrailing)

        let historyCompactWidth = CameraToolbarArrangement(
            isLive: false,
            compactWidth: true,
            compactHeight: false
        )
        XCTAssertFalse(historyCompactWidth.configurationControlsInBottomTrailing)
        XCTAssertTrue(historyCompactWidth.pauseInBottomTrailing)
        XCTAssertFalse(historyCompactWidth.navigationItemsInBottomToolbar)
        XCTAssertFalse(historyCompactWidth.compactTransportInBottomLeading)
        XCTAssertFalse(historyCompactWidth.recordInTrailingNavigationBar)
        XCTAssertFalse(historyCompactWidth.recordInBottomTrailing)

        let liveCompactHeight = CameraToolbarArrangement(
            isLive: true,
            compactWidth: false,
            compactHeight: true
        )
        XCTAssertTrue(liveCompactHeight.navigationItemsInBottomToolbar)
        XCTAssertFalse(liveCompactHeight.compactTransportInBottomLeading)
        XCTAssertFalse(liveCompactHeight.recordInTrailingNavigationBar)
        XCTAssertTrue(liveCompactHeight.recordInBottomTrailing)

        let fullyCompactLive = CameraToolbarArrangement(
            isLive: true,
            compactWidth: true,
            compactHeight: true
        )
        XCTAssertTrue(fullyCompactLive.navigationItemsInBottomToolbar)
        XCTAssertTrue(fullyCompactLive.compactTransportInBottomLeading)
        XCTAssertFalse(fullyCompactLive.recordInTrailingNavigationBar)
        XCTAssertTrue(fullyCompactLive.recordInBottomTrailing)

        let historyCompactHeight = CameraToolbarArrangement(
            isLive: false,
            compactWidth: false,
            compactHeight: true
        )
        XCTAssertTrue(historyCompactHeight.navigationItemsInBottomToolbar)
        XCTAssertFalse(historyCompactHeight.compactTransportInBottomLeading)

        let fullyCompactHistory = CameraToolbarArrangement(
            isLive: false,
            compactWidth: true,
            compactHeight: true
        )
        XCTAssertTrue(fullyCompactHistory.pauseInBottomTrailing)
        XCTAssertTrue(fullyCompactHistory.navigationItemsInBottomToolbar)
        XCTAssertTrue(fullyCompactHistory.compactTransportInBottomLeading)
    }

    func testToolbarScrubBridgeUsesRealNavigationBarAndExcludesToolbarControls() async throws {
        let relay = CameraToolbarScrubRelay()
        let host = UIHostingController(rootView: NavigationStack {
            Color.black
                .background {
                    CameraToolbarScrubBridge(isEnabled: true, relay: relay)
                        .frame(width: 0, height: 0)
                }
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        CameraPlayerCloseButton(action: {})
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Choose camera", systemImage: "video.fill", action: {})
                            .labelStyle(.iconOnly)
                    }
                }
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))

        let bar = try XCTUnwrap(findNavigationBar(in: host.view))
        XCTAssertEqual(
            bar.gestureRecognizers?.filter { $0.name == "CameraToolbarScrubBridge" }.count,
            1,
            "The bridge augments the NavigationStack's real bar"
        )

        let backing = UIView(frame: bar.bounds)
        bar.addSubview(backing)
        let button = UIButton(type: .system)
        button.frame = CGRect(x: 10, y: 0, width: 44, height: 44)
        backing.addSubview(button)
        let buttonLabel = UILabel(frame: button.bounds)
        button.addSubview(buttonLabel)

        XCTAssertTrue(CameraToolbarScrubBridge.Coordinator.isEmptyBarTouch(backing, inside: bar))
        XCTAssertFalse(CameraToolbarScrubBridge.Coordinator.isEmptyBarTouch(button, inside: bar))
        XCTAssertFalse(CameraToolbarScrubBridge.Coordinator.isEmptyBarTouch(buttonLabel, inside: bar))
        XCTAssertFalse(CameraToolbarScrubBridge.Coordinator.isEmptyBarTouch(UIView(), inside: bar))
    }

    func testLiveButtonUsesTitleOnlyForRegularToolbarVariant() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let cases: [(Bool, UserInterfaceSizeClass)] = [(true, .compact), (false, .compact), (true, .regular), (false, .regular)]
        for (live, sizeClass) in cases {
            let host = UIHostingController(rootView: NavigationStack {
                Color.black.ignoresSafeArea().toolbar {
                    ToolbarItem(placement: .bottomBar) {
                        CameraPlayerCloseButton(action: {})
                    }
                    ToolbarSpacer(.fixed, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        CameraLiveModeButton(
                            isLive: live,
                            showsTitle: sizeClass == .regular,
                            action: {}
                        )
                    }
                }
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            }.environment(\.horizontalSizeClass, sizeClass).preferredColorScheme(.dark))
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
            window.rootViewController = host; window.isHidden = false
            defer { window.isHidden = true }
            host.view.frame = window.bounds; host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let screenshot = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "Native Live button (live=\(live), compact=\(sizeClass == .compact))"
            attachment.lifetime = .keepAlways; add(attachment)
            let shapes = try toolbarShapeBounds(in: screenshot)
            XCTAssertEqual(shapes.count, 2)
            guard shapes.count == 2 else { continue }
            let close = shapes[0], button = shapes[1]
            XCTAssertEqual(button.height, close.height, accuracy: 1)
            if sizeClass == .compact {
                XCTAssertEqual(button.width, close.width, accuracy: 1)
            } else {
                XCTAssertGreaterThan(button.width, close.width + 20)
            }
        }
    }

    func testCloseUsesSystemToolbarSizing() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for width: CGFloat in [375, 393, 430, 852] {
            let host = UIHostingController(rootView: NavigationStack {
                Color.black.ignoresSafeArea().toolbar {
                    ToolbarItem(placement: .navigation) {
                        CameraPlayerCloseButton(action: {})
                    }
                    ToolbarItem(placement: .primaryAction) {
                        // Compare with an unmodified system button, not a point constant.
                        Button(role: .close, action: {})
                    }
                }
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            }.preferredColorScheme(.dark))
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 852)
            window.rootViewController = host; window.isHidden = false
            defer { window.isHidden = true }
            host.view.frame = window.bounds; host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let screenshot = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let shapes = try toolbarShapeBounds(in: screenshot)
            XCTAssertEqual(shapes.count, 2)
            guard shapes.count == 2 else { continue }
            XCTAssertEqual(shapes[0].width, shapes[1].width, accuracy: 1)
            XCTAssertEqual(shapes[0].height, shapes[1].height, accuracy: 1)
        }
    }

    private func toolbarShapeBounds(in screenshot: UIImage) throws -> [CGRect] {
        let image = try XCTUnwrap(screenshot.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var shapes: [CGRect] = [], current: CGRect?
        for x in 0...image.width {
            var column: CGRect?
            if x < image.width {
                for y in 0..<image.height {
                    let index = (y * image.width + x) * 4
                    if pixels[index + 3] > 128 && pixels[index...index + 2].contains(where: { $0 > 12 }) {
                        let pixel = CGRect(x: x, y: y, width: 1, height: 1)
                        column = column.map { $0.union(pixel) } ?? pixel
                    }
                }
            }
            if let column {
                current = current.map { $0.union(column) } ?? column
            } else if let shape = current {
                shapes.append(shape.applying(CGAffineTransform(scaleX: 1 / screenshot.scale, y: 1 / screenshot.scale)))
                current = nil
            }
        }
        return shapes
    }

    private func findNavigationBar(in view: UIView) -> UINavigationBar? {
        if let bar = view as? UINavigationBar { return bar }
        for child in view.subviews {
            if let bar = findNavigationBar(in: child) { return bar }
        }
        return nil
    }

    func testBufferedModeDisablesCameraGesturesButKeepsSingleTap() async throws {
        let surface = CameraLiveGestureUIView()
        surface.onMagnify = { _, _ in }
        let recognizers = try XCTUnwrap(surface.gestureRecognizers)
        let pan = try XCTUnwrap(recognizers.compactMap { $0 as? UIPanGestureRecognizer }.first)
        let pinch = try XCTUnwrap(recognizers.compactMap { $0 as? UIPinchGestureRecognizer }.first)
        let taps = recognizers.compactMap { $0 as? UITapGestureRecognizer }
        let singleTap = try XCTUnwrap(taps.first { $0.numberOfTouchesRequired == 1 })
        let recenter = try XCTUnwrap(taps.first { $0.numberOfTouchesRequired == 2 })
        XCTAssertTrue(pan.isEnabled)
        XCTAssertTrue(pinch.isEnabled)
        XCTAssertTrue(recenter.isEnabled)

        surface.cameraControlsEnabled = CameraPlaybackControlsPresentation(
            isLive: false, timelineVisible: true
        ).cameraControlsEnabled
        XCTAssertFalse(pan.isEnabled)
        XCTAssertFalse(pinch.isEnabled)
        XCTAssertFalse(recenter.isEnabled)
        XCTAssertTrue(singleTap.isEnabled)
        // A callback update must not accidentally re-enable zoom while buffered.
        surface.onMagnify = { _, _ in }
        XCTAssertFalse(pinch.isEnabled)

        surface.cameraControlsEnabled = CameraPlaybackControlsPresentation(
            isLive: true, timelineVisible: true
        ).cameraControlsEnabled
        XCTAssertTrue(pan.isEnabled)
        XCTAssertTrue(pinch.isEnabled)
        XCTAssertTrue(recenter.isEnabled)
        XCTAssertTrue(singleTap.isEnabled)
    }

    func testPresentingAndDismissingDatePickerDoesNotJump() async throws {
        var selections: [Date] = []
        let selection = CameraHistoryDateSelection(date: Date(timeIntervalSince1970: 1_700_000_000))
        let host = UIHostingController(rootView: CameraHistoryDatePicker(selection: selection) { selections.append($0) })
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 700, height: 320)
        host.view.layoutIfNeeded()
        XCTAssertTrue(selections.isEmpty)
        host.dismiss(animated: false)
        XCTAssertTrue(selections.isEmpty)
    }
}

@MainActor
private final class CameraGroupCanvasRotationState: ObservableObject {
    struct Traits {
        let horizontal: UserInterfaceSizeClass?
        let vertical: UserInterfaceSizeClass?
        let sample: Int

        static let portrait = Traits(horizontal: .compact, vertical: .regular, sample: 0)
        static let landscape = Traits(horizontal: .regular, vertical: .compact, sample: 1)
    }

    @Published var traits = Traits.portrait
    var appearances = 0
    var disappearances = 0
    var identitySamples: [ObjectIdentifier] = []

    nonisolated deinit {}
}

@MainActor
private final class CameraGroupCanvasOwnedState: ObservableObject {
    nonisolated deinit {}
}

private struct CameraGroupCanvasRotationHarness: View {
    @ObservedObject var state: CameraGroupCanvasRotationState

    var body: some View {
        CameraGroupCanvasEnvironmentHarness(state: state)
            .environment(\.horizontalSizeClass, state.traits.horizontal)
            .environment(\.verticalSizeClass, state.traits.vertical)
    }
}

private struct CameraGroupCanvasEnvironmentHarness: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ObservedObject var state: CameraGroupCanvasRotationState

    var body: some View {
        CameraGroupCanvas(ignoresSafeArea: CameraGroupLayout.ignoresSafeArea(
            horizontal: horizontalSizeClass,
            vertical: verticalSizeClass
        )) { _, _ in
            CameraGroupCanvasIdentityProbe(state: state, sample: state.traits.sample)
        }
    }
}

private struct CameraGroupCanvasIdentityProbe: View {
    @ObservedObject var state: CameraGroupCanvasRotationState
    @StateObject private var ownedState = CameraGroupCanvasOwnedState()
    let sample: Int

    var body: some View {
        Color.black
            .onAppear { state.appearances += 1 }
            .onDisappear { state.disappearances += 1 }
            .onChange(of: sample, initial: true) { _, _ in
                state.identitySamples.append(ObjectIdentifier(ownedState))
            }
    }
}

#endif
