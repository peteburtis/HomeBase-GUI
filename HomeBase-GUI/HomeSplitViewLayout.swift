import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

enum HomeSplitViewLayout: Equatable {
    case none, expanded, collapsed
}

extension EnvironmentValues {
    /// Read inside a split column, not above NavigationSplitView. A column's
    /// own horizontal size class can be compact even when the split is expanded.
    var homeSplitViewLayout: HomeSplitViewLayout {
        get { self[HomeSplitViewLayoutKey.self] }
        set { self[HomeSplitViewLayoutKey.self] = newValue }
    }
}

#if canImport(UIKit)
private struct HomeSplitViewLayoutKey: UITraitBridgedEnvironmentKey {
    static let defaultValue = HomeSplitViewLayout.none

    static func read(from traits: UITraitCollection) -> HomeSplitViewLayout {
        switch traits.splitViewControllerLayoutEnvironment {
        case .expanded: .expanded
        case .collapsed: .collapsed
        default: .none
        }
    }

    static func write(to traits: inout any UIMutableTraits, value: HomeSplitViewLayout) {
        traits.splitViewControllerLayoutEnvironment = switch value {
        case .none: .none
        case .expanded: .expanded
        case .collapsed: .collapsed
        }
    }
}
#else
private struct HomeSplitViewLayoutKey: EnvironmentKey {
    // macOS split views don't collapse their columns into a navigation stack.
    static let defaultValue = HomeSplitViewLayout.expanded
}
#endif
