import Combine
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Extends the history timeline's horizontal drag into the otherwise empty
/// portion of the real navigation bar. The bar and all of its items remain
/// system-owned; this recognizer neither replaces nor restyles them.
enum CameraToolbarScrubEvent {
    case began
    case changed(translation: CGFloat)
    case ended(translation: CGFloat)
    case cancelled
}

@MainActor
final class CameraToolbarScrubRelay: ObservableObject {
    let events = PassthroughSubject<CameraToolbarScrubEvent, Never>()
}

#if os(iOS)
struct CameraToolbarScrubBridge: UIViewRepresentable {
    let isEnabled: Bool
    let relay: CameraToolbarScrubRelay

    func makeCoordinator() -> Coordinator {
        Coordinator(relay: relay)
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onWindowChanged = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            coordinator.update(from: view)
        }
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        context.coordinator.relay = relay
        context.coordinator.isEnabled = isEnabled
        // NavigationStack can attach its controller after this representable's
        // update. ProbeView also retries from didMoveToWindow.
        DispatchQueue.main.async { [weak uiView, weak coordinator = context.coordinator] in
            guard let uiView, let coordinator else { return }
            coordinator.update(from: uiView)
        }
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: Coordinator) {
        uiView.onWindowChanged = nil
        coordinator.uninstall()
    }

    final class ProbeView: UIView {
        var onWindowChanged: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChanged?()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var relay: CameraToolbarScrubRelay
        var isEnabled = false {
            didSet {
                guard isEnabled != oldValue else { return }
                if !isEnabled { uninstall() }
            }
        }

        private weak var navigationBar: UINavigationBar?
        private var recognizer: UIPanGestureRecognizer?

        init(relay: CameraToolbarScrubRelay) {
            self.relay = relay
        }

        func update(from view: UIView) {
            guard isEnabled, let bar = navigationController(from: view)?.navigationBar else {
                if !isEnabled { uninstall() }
                return
            }
            guard navigationBar !== bar else { return }
            uninstall()
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.name = "CameraToolbarScrubBridge"
            recognizer.delegate = self
            bar.addGestureRecognizer(recognizer)
            navigationBar = bar
            self.recognizer = recognizer
        }

        func uninstall() {
            if recognizer?.state == .began || recognizer?.state == .changed {
                relay.events.send(.cancelled)
            }
            if let recognizer { navigationBar?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            navigationBar = nil
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let bar = navigationBar else { return }
            let translation = recognizer.translation(in: bar).x
            switch recognizer.state {
            case .began:
                relay.events.send(.began)
            case .changed:
                relay.events.send(.changed(translation: translation))
            case .ended:
                relay.events.send(.ended(translation: translation))
            case .cancelled, .failed:
                relay.events.send(.cancelled)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard isEnabled, let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let bar = navigationBar else { return false }
            let velocity = pan.velocity(in: bar)
            return abs(velocity.x) > abs(velocity.y)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard isEnabled, let bar = navigationBar else { return false }
            return Self.isEmptyBarTouch(touch.view, inside: bar)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        /// UIKit's bar buttons currently descend from UIControl, but checking
        /// the accessibility trait also protects system-hosted button wrappers.
        static func isEmptyBarTouch(_ touchedView: UIView?, inside bar: UINavigationBar) -> Bool {
            var candidate = touchedView
            while let view = candidate, view !== bar {
                if view is UIControl || view.accessibilityTraits.contains(.button) {
                    return false
                }
                candidate = view.superview
            }
            return candidate === bar
        }

        private func navigationController(from view: UIView) -> UINavigationController? {
            var responder: UIResponder? = view
            while let current = responder {
                if let navigation = current as? UINavigationController { return navigation }
                if let controller = current as? UIViewController,
                   let navigation = controller.navigationController { return navigation }
                responder = current.next
            }
            return nil
        }
    }
}
#endif
