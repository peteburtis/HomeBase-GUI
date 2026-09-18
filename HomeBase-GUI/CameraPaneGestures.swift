import Foundation

/// A pane owns its gesture targets, initial recenter position, and pending writes.
/// This never routes through the group's shared toolbar controls.
@MainActor
final class CameraPaneGestures {
    private let model: LiveDeviceControlsModel
    private let panTilt: CameraPanTiltGestureController
    private let zoom: CameraZoomGestureController
    private(set) var enabled = false

    init(model: LiveDeviceControlsModel) {
        self.model = model
        panTilt = CameraPanTiltGestureController(model: model)
        zoom = CameraZoomGestureController(model: model)
    }

    var panTiltTarget: CameraPanTiltGestureTarget? {
        guard enabled, model.state == .live else { return nil }
        return CameraPanTiltGestureTarget(controls: model.controls)
    }

    var zoomTarget: CameraZoomGestureTarget? {
        guard enabled, model.state == .live else { return nil }
        return CameraZoomGestureTarget(controls: model.controls)
    }

    func update(enabled: Bool) {
        self.enabled = enabled
        if let target = panTiltTarget { panTilt.captureInitialPosition(from: target) }
        else { panTilt.stop() }
        if zoomTarget == nil { zoom.stop() }
    }

    func pan(_ phase: CameraPanGesturePhase, translation: CGSize, viewport: CGSize) {
        guard let target = panTiltTarget else { panTilt.stop(); return }
        switch phase {
        case .began: panTilt.captureInitialPosition(from: target); panTilt.beginDrag(using: target)
        case .changed: panTilt.updateDrag(translation: translation, viewport: viewport)
        case .ended: panTilt.endDrag(translation: translation, viewport: viewport)
        case .cancelled: panTilt.cancelDrag()
        }
    }

    func magnify(_ phase: CameraMagnifyGesturePhase, scale: CGFloat) {
        guard let target = zoomTarget else { zoom.stop(); return }
        switch phase {
        case .began: zoom.beginMagnification(using: target)
        case .changed: zoom.updateMagnification(scale)
        case .ended: zoom.endMagnification(scale)
        case .cancelled: zoom.cancelMagnification()
        }
    }

    func recenter() {
        guard let target = panTiltTarget else { return }
        panTilt.recenter(using: target)
    }

    func stop() { panTilt.stop(); zoom.stop() }
}
