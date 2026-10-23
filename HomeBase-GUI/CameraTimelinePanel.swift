import SwiftUI

struct CameraTimelineBoundsPreference: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let bounds = nextValue() { value = bounds }
    }
}

/// History can keep its timeline connection alive while the controls slide
/// offscreen. Leaving history still removes the content and releases it.
struct CameraTimelinePanel<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isPresented: Bool
    let isActive: Bool
    @ViewBuilder let content: () -> Content

    init(
        isPresented: Bool,
        isActive: Bool? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isPresented = isPresented
        self.isActive = isActive ?? isPresented
        self.content = content
    }

    var body: some View {
        if isActive {
            content()
                .fixedSize(horizontal: false, vertical: true)
                .anchorPreference(key: CameraTimelineBoundsPreference.self, value: .bounds) { $0 }
                .visualEffect { content, geometry in
                    content.offset(y: isPresented ? 0 : -geometry.frame(in: .global).maxY)
                }
                .allowsHitTesting(isPresented)
                .accessibilityHidden(!isPresented)
                .transition(.move(edge: .top))
                .animation(reduceMotion ? nil : .snappy, value: isPresented)
        }
    }
}
