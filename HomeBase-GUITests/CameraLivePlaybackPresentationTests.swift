#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraLivePlaybackPresentationTests: XCTestCase {
    func testLiveButtonKeepsSameUnclippedGeometryInBothStates() async {
        let host = UIHostingController(rootView: CameraLiveModeButton(
            isLive: true, shuttleControlsVisible: true, action: {}
        ))
        let proposal = CGSize(width: 1_000, height: 100)
        let liveSize = host.sizeThatFits(in: proposal)
        host.rootView = CameraLiveModeButton(
            isLive: false, shuttleControlsVisible: true, action: {}
        )
        let bufferedSize = host.sizeThatFits(in: proposal)
        XCTAssertEqual(liveSize.width, bufferedSize.width, accuracy: 0.5)
        XCTAssertEqual(liveSize.height, bufferedSize.height, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(bufferedSize.width, 64)
        XCTAssertGreaterThanOrEqual(bufferedSize.height, 44)

        // Even a toolbar proposing an icon-sized slot cannot compress the label.
        let narrowSize = host.sizeThatFits(in: CGSize(width: 44, height: 44))
        XCTAssertEqual(narrowSize.width, bufferedSize.width, accuracy: 0.5)
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

        surface.cameraControlsEnabled = false
        XCTAssertFalse(pan.isEnabled)
        XCTAssertFalse(pinch.isEnabled)
        XCTAssertFalse(recenter.isEnabled)
        XCTAssertTrue(singleTap.isEnabled)
        // A callback update must not accidentally re-enable zoom while buffered.
        surface.onMagnify = { _, _ in }
        XCTAssertFalse(pinch.isEnabled)

        surface.cameraControlsEnabled = true
        XCTAssertTrue(pan.isEnabled)
        XCTAssertTrue(pinch.isEnabled)
        XCTAssertTrue(recenter.isEnabled)
        XCTAssertTrue(singleTap.isEnabled)
    }
}
#endif
