#if os(iOS)
import SwiftUI
import UIKit

/// Reads only the public tab bar in this hosting controller's hierarchy. Its
/// actual frame handles rotation, safe areas, and the floating iOS tab bar.
struct ConnectionStatusTabBarReader: UIViewControllerRepresentable {
    var changed: (CGRect?) -> Void
    func makeUIViewController(context: Context) -> Observer {
        let observer = Observer()
        observer.changed = changed
        return observer
    }
    func updateUIViewController(_ observer: Observer, context: Context) {
        observer.changed = changed
        observer.scheduleMeasurement()
    }

    final class Observer: UIViewController {
        var changed: ((CGRect?) -> Void)?
        private var scheduled = false
        private var previous: CGRect?
        nonisolated deinit {}
        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            scheduleMeasurement()
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            scheduleMeasurement()
        }
        override func viewSafeAreaInsetsDidChange() {
            super.viewSafeAreaInsetsDidChange()
            scheduleMeasurement()
        }
        func scheduleMeasurement() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.measure()
            }
        }
        private func measure() {
            guard view.window != nil else { return }
            var ancestor: UIViewController? = parent
            var tab: UITabBarController?
            while let candidate = ancestor, tab == nil {
                tab = findTab(in: candidate)
                ancestor = candidate.parent
            }
            let bar = tab?.tabBar
            let frame = bar.flatMap { bar -> CGRect? in
                guard !bar.isHidden, bar.alpha > 0, bar.window === view.window,
                      !bar.bounds.isEmpty else { return nil }
                return bar.convert(bar.bounds, to: nil)
            }
            guard frame != previous else { return }
            previous = frame
            changed?(frame)
        }
        private func findTab(in controller: UIViewController) -> UITabBarController? {
            if let tab = controller as? UITabBarController { return tab }
            for child in controller.children where child !== self {
                if let tab = findTab(in: child) { return tab }
            }
            return nil
        }
    }
}

/// A noninteractive geometry marker also makes the native/SwiftUI layout
/// boundary observable to layout regression tests without private UIKit APIs.
struct ConnectionStatusBoundsMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityIdentifier = "connection-status-bounds"
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
}
#endif
