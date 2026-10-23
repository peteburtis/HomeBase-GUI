import XCTest
import SwiftUI
import Combine
import HomeBaseProtocol
#if os(iOS)
import UIKit
#endif
@testable import HomeBase_GUI

@MainActor
final class CameraPlayerPanelTests: XCTestCase {
    func testOffShowsHistoryThenPTZAndSelectionHidesOnlyTheAlternateButton() {
        let available = availability()
        XCTAssertEqual(available.buttons(for: .off), [.history, .ptz])
        XCTAssertEqual(available.toggling(.history, from: .off), .history)
        XCTAssertEqual(available.buttons(for: .history), [.history])
        XCTAssertEqual(available.toggling(.history, from: .history), .off)
        XCTAssertEqual(available.toggling(.ptz, from: .off), .ptz)
        XCTAssertEqual(available.buttons(for: .ptz), [.ptz])
        XCTAssertEqual(available.toggling(.ptz, from: .ptz), .off)
        XCTAssertEqual(available.toggling(.history, from: .ptz), .ptz, "The alternate button is absent, not tappable")
    }

    func testNonLiveSingleCameraHidesPTZAndClosesItsPanel() {
        let buffered = availability(live: false)
        XCTAssertFalse(buffered.showsPTZ)
        XCTAssertFalse(buffered.enablesPTZ)
        XCTAssertEqual(buffered.buttons(for: .off), [.history])
        XCTAssertEqual(buffered.buttons(for: .ptz), [.history])
        XCTAssertEqual(buffered.toggling(.ptz, from: .off), .off)
        XCTAssertEqual(buffered.validated(.ptz), .off)
        XCTAssertEqual(buffered.validated(.history), .history)
        XCTAssertEqual(availability(live: true).buttons(for: .off), [.history, .ptz],
            "Returning to Live makes PTZ available again without reopening its sliders")
    }

    func testMultipleAlwaysHidesPTZEvenWithOnlyOneSelectedCamera() {
        for live in [true, false] {
            let multiple = availability(live: live, multiple: true)
            XCTAssertFalse(multiple.showsPTZ)
            XCTAssertFalse(multiple.enablesPTZ)
            XCTAssertEqual(multiple.buttons(for: .off), [.history])
            XCTAssertEqual(multiple.validated(.ptz), .off)
            XCTAssertEqual(multiple.validated(.history), .history)
        }
    }

    func testCapabilityLossClosesOnlyTheAffectedPanelAndAbsentPTZIsHidden() {
        let noPTZ = availability(ptz: false)
        XCTAssertEqual(noPTZ.buttons(for: .off), [.history])
        XCTAssertEqual(noPTZ.validated(.ptz), .off)
        XCTAssertEqual(noPTZ.validated(.history), .history)
        let noHistory = availability(history: false)
        XCTAssertEqual(noHistory.buttons(for: .off), [.history, .ptz])
        XCTAssertEqual(noHistory.toggling(.history, from: .off), .off)
        XCTAssertEqual(noHistory.validated(.history), .off)
        XCTAssertEqual(noHistory.validated(.ptz), .ptz)
    }

    func testZoomOnlyAndPanOnlyCamerasBothSupportCombinedPTZPanel() {
        XCTAssertTrue(CameraDetailControlSet(controls: [axis("PTZ.Zoom.Position")]).hasPTZ)
        XCTAssertTrue(CameraDetailControlSet(controls: [axis("PTZ.Pan.Position")]).hasPTZ)
        XCTAssertTrue(CameraDetailControlSet(controls: [axis("PTZ.Tilt.Position")]).hasPTZ)
        XCTAssertFalse(CameraDetailControlSet(controls: []).hasPTZ)
    }

    func testZoomExtendsToButtonBaselineAndMatchesTopOfTiltSlider() {
        for size in [CGSize(width: 852, height: 310), CGSize(width: 393, height: 756), CGSize(width: 1024, height: 768)] {
            let axis = CameraDetailControlsOverlay.axisLength(for: size)
            let zoom = CameraPTZOverlayMetrics.zoomLength(axisLength: axis)
            XCTAssertEqual(zoom, axis + CameraPTZOverlayMetrics.buttonSize + CameraPTZOverlayMetrics.spacing)
            // Both sliders add the same five-point padding at each end.
            XCTAssertEqual(zoom + 10, axis + 10 + CameraPTZOverlayMetrics.buttonClearance)
            XCTAssertLessThan(zoom + 10 + 2 * CameraPTZOverlayMetrics.inset, size.height)
        }
    }

#if os(iOS)
    func testMountedCapsuleMorphsAndOpeningSlidersDoesNotWriteCameraControls() async throws {
        let client = HomeBaseWebSocketClient(endpoint: try XCTUnwrap(HomeBasePairingCode.endpoint(from: "homebasews://127.0.0.1:1")))
        let model = LiveDeviceControlsModel(device: nil, client: client)
        var writes = 0
        model.installWriteRouting(value: { _, _, _ in writes += 1 }, canonical: { _, _ in writes += 1 })
        model.installAggregatePresentation([axis("PTZ.Pan.Position"), axis("PTZ.Tilt.Position"), axis("PTZ.Zoom.Position")])
        let state = PanelFixtureState()
        let host = UIHostingController(rootView: AnyView(PanelFixture(state: state, model: model).preferredColorScheme(.dark)))
        // This resized window is not a true device rotation: supply protected
        // side/bottom areas explicitly rather than trusting its scene's traits.
        host.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 60, bottom: 21, right: 60)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        for compact in [true, false] {
            host.traitOverrides.verticalSizeClass = compact ? .compact : .regular
            window.frame = compact ? CGRect(x: 0, y: 0, width: 852, height: 393) : CGRect(x: 0, y: 0, width: 393, height: 852)
            host.view.frame = window.bounds; host.view.layoutIfNeeded()
            state.timelineHeight = compact ? 50 : 96
            for (panel, live, multiple) in [(CameraPlayerPanel.off, true, false), (.ptz, true, false),
                                           (.history, true, false), (.off, true, false), (.off, false, false),
                                           (.history, false, false), (.off, true, true), (.history, true, true), (.off, true, true)] {
                state.availability = availability(live: live, multiple: multiple)
                state.panel = panel
                try await Task.sleep(for: .milliseconds(600))
                let frame = state.pickerFrame
                XCTAssertEqual(frame.height, 44, accuracy: 1)
                XCTAssertEqual(frame.width, panel == .off && !multiple && live ? 88 : 44, accuracy: 1)
                let safe = host.view.safeAreaLayoutGuide.layoutFrame
                XCTAssertGreaterThan(host.view.safeAreaInsets.right, 0)
                XCTAssertGreaterThan(host.view.safeAreaInsets.bottom, 0)
                XCTAssertEqual(frame.maxX, safe.maxX - CameraPTZOverlayMetrics.inset, accuracy: 1)
                if panel == .history {
                    XCTAssertGreaterThan(state.timelineFrame.height, 0)
                    XCTAssertEqual(frame.midY, state.timelineFrame.midY, accuracy: 1,
                        "History centers on the actual timeline in both compact and regular height")
                    XCTAssertEqual(state.timelineFrame.maxY, compact ? host.view.bounds.maxY : safe.maxY, accuracy: 1)
                } else {
                    XCTAssertEqual(frame.maxY, safe.maxY - CameraPTZOverlayMetrics.inset, accuracy: 1,
                        "Closing History restores the safe-area anchor")
                }
                XCTAssertFalse(host.view.hitTest(CGPoint(x: frame.midX + 8, y: frame.midY), with: nil) is CameraLiveGestureUIView,
                    "The capsule must own its touch area, not the camera pan/tap recognizers underneath")
                XCTAssertFalse(host.view.hitTest(CGPoint(x: frame.midX, y: frame.maxY - 4), with: nil) is CameraLiveGestureUIView,
                    "The moved button stays interactive, including outside the bottom safe-area inset")
                XCTAssertTrue(host.view.hitTest(CGPoint(x: safe.midX, y: safe.midY), with: nil) is CameraLiveGestureUIView,
                    "The expanded placement canvas must not steal touches from the video")
                let screenshot = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: screenshot)
                attachment.name = "Panel capsule \(panel), live=\(live), multiple=\(multiple), compact=\(compact)"
                attachment.lifetime = .keepAlways; add(attachment)
                XCTAssertEqual(writes, 0, "Merely showing/hiding sliders must not move the camera")
            }
        }
        // Release SwiftUI's mounted/cached model references while this test
        // still owns the model on its actor. UIKit's deferred view destruction
        // otherwise hits the existing iOS 26.1 isolated-deinit runtime crash.
        host.rootView = AnyView(Color.clear)
        window.isHidden = true
        window.rootViewController = nil
        try await Task.sleep(for: .milliseconds(200))
        withExtendedLifetime(model) { XCTAssertEqual(writes, 0) }
    }
#endif

    private func availability(history: Bool = true, ptz: Bool = true, live: Bool = true, multiple: Bool = false) -> CameraPlayerPanelAvailability {
        .init(historyAvailable: history, ptzSupported: ptz, isLive: live, isMultiple: multiple)
    }

    private func axis(_ name: String) -> LiveDeviceControl {
        let metadata: [String: HBJSONValue] = ["readable": true, "writable": true, "structured": false,
                                             "minimum": -1, "maximum": 1]
        return LiveDeviceControl(descriptor: .init(control: "Camera:\(name)", deviceIdentifier: "Camera",
            controlIdentifier: name, displayName: name, kind: name, metadata: metadata),
            details: .init(identifier: name, name: name, kind: name, value: .number(0.25), metadata: metadata),
            value: .number(0.25), valid: true)
    }
}

#if os(iOS)
@MainActor private final class PanelFixtureState: ObservableObject {
    @Published var panel = CameraPlayerPanel.off
    @Published var availability = CameraPlayerPanelAvailability(historyAvailable: true, ptzSupported: true, isLive: true, isMultiple: false)
    @Published var timelineHeight: CGFloat = 75
    var pickerFrame = CGRect.zero
    var timelineFrame = CGRect.zero
    nonisolated deinit {}
}

private struct PanelFixture: View {
    @ObservedObject var state: PanelFixtureState
    let model: LiveDeviceControlsModel
    var body: some View {
        ZStack {
            Color.gray.opacity(0.3)
            CameraLiveGestureSurface(videoVisible: true, cameraControlsEnabled: state.availability.isLive,
                onPan: { _, _, _ in }, onMagnify: nil, onSingleTap: {}, onTwoFingerTap: {})
            if state.panel == .ptz { CameraDetailControlsOverlay(model: model) }
        }
        .overlay(alignment: .bottom) {
            CameraTimelinePlacement {
                CameraTimelinePanel(isPresented: state.panel == .history) {
                    Color.yellow.opacity(0.2).frame(height: state.timelineHeight).allowsHitTesting(false)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.timelineFrame = $0 }
                }
            }
        }
        .overlayPreferenceValue(CameraTimelineBoundsPreference.self) { bounds in
            CameraPlayerPanelPlacement(panel: state.panel, timelineBounds: bounds) {
                CameraPlayerPanelPicker(selection: $state.panel, availability: state.availability)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.pickerFrame = $0 }
            }
        }
    }
}
#endif
