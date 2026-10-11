import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct ReturnToGroupAction {
    let perform: @MainActor () -> Void

    @MainActor func callAsFunction() {
        perform()
    }
}

private struct ReturnToGroupActionKey: EnvironmentKey {
    static let defaultValue = ReturnToGroupAction(perform: {})
}

extension EnvironmentValues {
    var returnToGroup: ReturnToGroupAction {
        get { self[ReturnToGroupActionKey.self] }
        set { self[ReturnToGroupActionKey.self] = newValue }
    }
}

extension View {
    /// Installs the action at the detail-column boundary, outside its stack.
    func ownsReturnToGroupAction() -> some View {
        modifier(ReturnToGroupActionOwner())
    }
}

private struct ReturnToGroupActionOwner: ViewModifier {
#if canImport(UIKit)
    @State private var controller = SplitDetailReturnController()

    func body(content: Content) -> some View {
        content
            .background {
                SplitDetailNavigationAnchor(controller: controller)
                    .frame(width: 0, height: 0)
            }
            .environment(\.returnToGroup, ReturnToGroupAction {
                controller.returnToGroup()
            })
    }
#else
    func body(content: Content) -> some View { content }
#endif
}

#if canImport(UIKit)
private struct SplitDetailNavigationAnchor: UIViewControllerRepresentable {
    let controller: SplitDetailReturnController

    func makeUIViewController(context: Context) -> SplitDetailReturnController {
        controller
    }

    func updateUIViewController(_ controller: SplitDetailReturnController, context: Context) {}
}

/// Uses the existing collapsed split's stack; never creates a navigation controller.
private final class SplitDetailReturnController: UIViewController {
    func returnToGroup() {
        guard let split = splitViewController, split.isCollapsed else { return }

        var child: UIViewController = self
        while let parent = child.parent, parent !== split {
            if let navigation = parent as? UINavigationController,
               navigation.topViewController === child,
               navigation.viewControllers.count > 1 {
                navigation.popViewController(animated: false)
                return
            }
            child = parent
        }
    }
}
#endif
