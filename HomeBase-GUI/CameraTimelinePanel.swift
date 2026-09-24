import SwiftUI

struct CameraTimelineBoundsPreference: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let bounds = nextValue() { value = bounds }
    }
}

/// Removing the timeline also releases its thumbnail connection; no hidden
/// view remains to intercept video gestures.
struct CameraTimelinePanel<Content: View>: View {
    let isPresented: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if isPresented {
            content()
                .fixedSize(horizontal: false, vertical: true)
                .anchorPreference(key: CameraTimelineBoundsPreference.self, value: .bounds) { $0 }
                .transition(.opacity)
        }
    }
}
