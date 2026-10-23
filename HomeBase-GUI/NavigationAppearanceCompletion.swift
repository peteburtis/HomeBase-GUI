import SwiftUI

extension View {
    /// Unlike SwiftUI's onAppear, runs after the native appearance transition.
    func onNavigationAppearanceCompleted(_ action: @escaping @MainActor () -> Void) -> some View {
        background {
            NavigationAppearanceCompletion(action: action)
                .frame(width: 0, height: 0)
        }
    }
}

#if canImport(UIKit)
import UIKit

private struct NavigationAppearanceCompletion: UIViewControllerRepresentable {
    let action: @MainActor () -> Void

    func makeUIViewController(context: Context) -> AppearanceViewController {
        let controller = AppearanceViewController()
        controller.action = action
        return controller
    }

    func updateUIViewController(_ controller: AppearanceViewController, context: Context) {
        controller.action = action
    }

    final class AppearanceViewController: UIViewController {
        var action: @MainActor () -> Void = {}

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            action()
        }
    }
}
#elseif canImport(AppKit)
import AppKit

private struct NavigationAppearanceCompletion: NSViewControllerRepresentable {
    let action: @MainActor () -> Void

    func makeNSViewController(context: Context) -> AppearanceViewController {
        let controller = AppearanceViewController()
        controller.action = action
        return controller
    }

    func updateNSViewController(_ controller: AppearanceViewController, context: Context) {
        controller.action = action
    }

    final class AppearanceViewController: NSViewController {
        var action: @MainActor () -> Void = {}

        override func loadView() {
            view = NSView()
        }

        override func viewDidAppear() {
            super.viewDidAppear()
            action()
        }
    }
}
#endif
