#if os(iOS)
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
                    ToolbarItem(placement: .topBarTrailing) {
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

    func testCompactWidthMovesSecondaryActionsToSystemOverflow() async throws {
        XCTAssertNotNil(UIImage(systemName: "rectangle.grid.3x3.fill"))
        for live in [true, false] {
            for width: CGFloat in [375, 393, 430] {
                try await assertToolbarOverflow(live: live, width: width, compact: true)
            }
            // A wide window with compact traits must still use the same policy.
            try await assertToolbarOverflow(live: live, width: 852, compact: true)
            try await assertToolbarOverflow(live: live, width: 852, compact: false)
        }
    }

    private func assertToolbarOverflow(live: Bool, width: CGFloat, compact: Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: NavigationStack {
            Color.black.ignoresSafeArea().toolbar {
                CameraPlaybackToolbar(isLive: live, playbackEnabled: true,
                    close: {}, goLive: {},
                    back: Button("Back 30 seconds", systemImage: "gobackward.30", action: {}),
                    pause: Button("Pause", systemImage: "pause.fill", action: {}).labelStyle(.iconOnly),
                    forward: Button("Forward 30 seconds", systemImage: "goforward.30", action: {}).disabled(live),
                    speed: CameraPlaybackSpeedMenu(speed: .constant(.double)))
                if !compact || live {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Record", systemImage: "record.circle", action: {}).disabled(!live)
                    }
                }
                if live {
                    if !compact { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
                    ToolbarItemGroup(placement: compact ? .secondaryAction : .topBarTrailing) {
                        Menu { Button("High", action: {}) } label: {
                            Label("Video quality", systemImage: "slider.horizontal.3")
                        }
                        Menu { Button("Day", action: {}) } label: {
                            Label("Day and night mode", systemImage: "sun.max")
                        }
                        Button("Privacy mode", systemImage: "eye", action: {})
                    }
                }
                if !compact { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Choose camera", systemImage: "rectangle.grid.3x3.fill", action: {}).labelStyle(.iconOnly)
                }
            }
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        }.environment(\.horizontalSizeClass, compact ? .compact : .regular)
            .preferredColorScheme(.dark))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: width > 500 ? 393 : 852)
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let screenshot = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "Native toolbar overflow, compact=\(compact), live=\(live), width=\(width)"
        attachment.lifetime = .keepAlways; add(attachment)
        let shapes = try toolbarShapeBounds(in: screenshot)
        XCTAssertFalse(shapes.isEmpty)
        XCTAssertTrue(shapes.allSatisfy { $0.minX >= 0 && $0.maxX <= width })
        let navigation = try XCTUnwrap(navigationController(in: host))
        let item = try XCTUnwrap(navigation.navigationBar.topItem)
        // In the navigator toolbar role, UIKit puts center groups into its
        // system overflow. The generated overflow button is not itself in
        // rightBarButtonItems; inspect the secondary groups, not that button.
        let secondaryItems = item.centerItemGroups.flatMap(\.barButtonItems)
        let titles = itemTitles(secondaryItems)
        let leadingTitles = itemTitles(item.leadingItemGroups.flatMap(\.barButtonItems))
        let trailingTitles = itemTitles(item.trailingItemGroups.flatMap(\.barButtonItems))
        // UIKit exposes this menu's current-rate title, not the SwiftUI
        // accessibility label, on its bar item.
        let speedTitle = CameraPlaybackSpeed.double.label
        if live {
            XCTAssertFalse(leadingTitles.contains(speedTitle))
            XCTAssertFalse(trailingTitles.contains(speedTitle))
            XCTAssertTrue(trailingTitles.contains("Record"))
        } else if compact {
            XCTAssertFalse(leadingTitles.contains(speedTitle))
            XCTAssertTrue(trailingTitles.contains(speedTitle))
            XCTAssertFalse(trailingTitles.contains("Record"))
        } else {
            XCTAssertTrue(leadingTitles.contains(speedTitle))
            XCTAssertFalse(trailingTitles.contains(speedTitle))
            XCTAssertTrue(trailingTitles.contains("Record"))
        }
        XCTAssertTrue(trailingTitles.contains("Choose camera"))
        XCTAssertFalse(titles.contains(speedTitle))
        XCTAssertFalse(titles.contains("Record"))
        XCTAssertFalse(titles.contains("Choose camera"))
        let menuAttachment = XCTAttachment(string: titles.joined(separator: "\n"))
        menuAttachment.name = "Overflow titles, compact=\(compact), live=\(live), width=\(width)"
        menuAttachment.lifetime = .keepAlways; add(menuAttachment)
        if compact {
            XCTAssertTrue(titles.contains("Back 30 seconds"))
            XCTAssertTrue(titles.contains("Forward 30 seconds"))
            if live {
                XCTAssertTrue(titles.contains("Video quality"))
                XCTAssertTrue(titles.contains("Day and night mode"))
                XCTAssertTrue(titles.contains("Privacy mode"))
            }
        } else {
            XCTAssertFalse(titles.contains("Back 30 seconds"))
            XCTAssertFalse(titles.contains("Forward 30 seconds"))
        }
    }

    private func navigationController(in controller: UIViewController) -> UINavigationController? {
        (controller as? UINavigationController) ?? controller.children.lazy.compactMap { self.navigationController(in: $0) }.first
    }

    private func itemTitles(_ items: [UIBarButtonItem]) -> [String] {
        items.flatMap { button in
            [button.title ?? "", button.accessibilityLabel ?? "", button.primaryAction?.title ?? ""]
                + (button.menu.map(menuTitles) ?? [])
        }
    }

    private func menuTitles(_ menu: UIMenu) -> [String] {
        [menu.title] + menu.children.flatMap { element -> [String] in
            if let menu = element as? UIMenu { return menuTitles(menu) }
            return [element.title]
        }
    }

    func testRegularWidthShowsShuttlesAndLiveButSpeedOnlyWhenNotLive() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for live in [true, false] {
            let host = UIHostingController(rootView: NavigationStack {
                Color.black.ignoresSafeArea().toolbar {
                    CameraPlaybackToolbar(isLive: live, playbackEnabled: true,
                        close: {}, goLive: {},
                        back: Button("Back 30 seconds", systemImage: "gobackward.30", action: {}).labelStyle(.iconOnly),
                        pause: Button("Pause", systemImage: "pause.fill", action: {}).labelStyle(.iconOnly),
                        forward: Button("Forward 30 seconds", systemImage: "goforward.30", action: {}).labelStyle(.iconOnly),
                        speed: CameraPlaybackSpeedMenu(speed: .constant(.normal)))
                }
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            }.environment(\.horizontalSizeClass, .regular).preferredColorScheme(.dark))
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
            attachment.name = "Regular-width playback toolbar (live=\(live))"
            attachment.lifetime = .keepAlways; add(attachment)
            let shapes = try toolbarShapeBounds(in: screenshot)
            XCTAssertEqual(shapes.count, live ? 3 : 4, "Close, shuttles, Live, and optional speed use separate native groups")
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

    func testStatusScreenDisablesAllNativeVideoRecognizersAndHitTesting() async throws {
        let surface = CameraLiveGestureUIView()
        surface.onMagnify = { _, _ in }
        surface.videoVisible = false
        let recognizers = try XCTUnwrap(surface.gestureRecognizers)
        XCTAssertEqual(recognizers.count, 4)
        XCTAssertTrue(recognizers.allSatisfy { !$0.isEnabled })
        XCTAssertFalse(surface.isUserInteractionEnabled)
        // Camera capability/callback refreshes must not reactivate the background.
        surface.cameraControlsEnabled = true
        surface.onMagnify = { _, _ in }
        XCTAssertTrue(recognizers.allSatisfy { !$0.isEnabled })
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

    func testLiveButtonNeverUsesHistorySymbolAndIsNoOpWhileLive() {
        for (live, symbol) in [
            (true, "dot.radiowaves.left.and.right"),
            (false, "chevron.forward.dotted.chevron.forward"),
        ] {
            var returnToLiveCount = 0
            let button = CameraLiveModeButton(isLive: live) { returnToLiveCount += 1 }
            XCTAssertEqual(button.systemImage, symbol)
            XCTAssertNotNil(UIImage(systemName: symbol))
            button.returnToLive()
            XCTAssertEqual(returnToLiveCount, live ? 0 : 1)
        }
        XCTAssertNotNil(UIImage(systemName: CameraPlayerPanelPicker.historySymbol))
    }

    func testLiveButtonUsesNativeSizingWithTitleOnlyInRegularWidth() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let cases: [(Bool, UserInterfaceSizeClass)] = [(true, .compact), (false, .compact), (true, .regular), (false, .regular)]
        for (live, sizeClass) in cases {
            let host = UIHostingController(rootView: NavigationStack {
                Color.black.ignoresSafeArea().toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        CameraPlayerCloseButton(action: {})
                    }
                    ToolbarSpacer(.fixed, placement: .topBarLeading)
                    ToolbarItem(placement: .topBarLeading) {
                        CameraLiveModeButton(isLive: live, action: {})
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
                XCTAssertEqual(button.width, close.width, accuracy: 1, "Compact Live uses native icon-only toolbar sizing")
            } else {
                XCTAssertGreaterThan(button.width, close.width + 20, "Regular-width Live retains its title")
            }
        }
    }

    func testCloseUsesSystemToolbarSizing() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for width: CGFloat in [375, 393, 430, 852] {
            let host = UIHostingController(rootView: NavigationStack {
                Color.black.ignoresSafeArea().toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        CameraPlayerCloseButton(action: {})
                    }
                    ToolbarItem(placement: .confirmationAction) {
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

#endif
