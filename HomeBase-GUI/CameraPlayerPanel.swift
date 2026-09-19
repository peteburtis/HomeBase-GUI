import SwiftUI

/// One selection owns both panels. Two panels cannot
/// accidentally remain expanded because separate booleans disagree.
nonisolated enum CameraPlayerPanel: Hashable, Sendable {
    case off, history, ptz
}

struct CameraPlayerPanelAvailability: Equatable {
    let historyAvailable: Bool
    let ptzSupported: Bool
    let isLive: Bool
    let isMultiple: Bool

    var showsPTZ: Bool { ptzSupported && !isMultiple && isLive }
    var enablesPTZ: Bool { showsPTZ }

    func validated(_ panel: CameraPlayerPanel) -> CameraPlayerPanel {
        switch panel {
        case .history: historyAvailable ? .history : .off
        case .ptz: enablesPTZ ? .ptz : .off
        case .off: .off
        }
    }

    func buttons(for panel: CameraPlayerPanel) -> [CameraPlayerPanel] {
        switch validated(panel) {
        case .history: [.history]
        case .ptz: [.ptz]
        case .off: showsPTZ ? [.history, .ptz] : [.history]
        }
    }

    func toggling(_ button: CameraPlayerPanel, from panel: CameraPlayerPanel) -> CameraPlayerPanel {
        let current = validated(panel)
        guard buttons(for: current).contains(button) else { return current }
        return current == button ? .off : validated(button)
    }
}

struct CameraPlayerPanelPicker: View {
    static var historySymbol: String { "clock.arrow.trianglehead.counterclockwise.rotate.90" }
    static var ptzSymbol: String { "arrow.up.and.down.and.arrow.left.and.right" }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassNamespace
    @Binding var selection: CameraPlayerPanel
    let availability: CameraPlayerPanelAvailability

    var body: some View {
#if os(visionOS)
        buttons.cameraGlassBacker(in: Capsule(), interactive: true)
#else
        GlassEffectContainer(spacing: 8) { buttons }
#endif
    }

    private var buttons: some View {
        HStack(spacing: 0) {
            ForEach(availability.buttons(for: selection), id: \.self) { panel in
                panelButton(panel)
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: selection)
        .animation(reduceMotion ? nil : .snappy, value: availability)
    }

    private func panelButton(_ panel: CameraPlayerPanel) -> some View {
        let selected = selection == panel
        let enabled = panel == .history ? availability.historyAvailable : availability.enablesPTZ
        return Button {
            selection = availability.toggling(panel, from: selection)
        } label: {
            Image(systemName: panel == .history ? Self.historySymbol : Self.ptzSymbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .frame(width: CameraPTZOverlayMetrics.buttonSize, height: CameraPTZOverlayMetrics.buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
#if !os(visionOS)
        .glassEffect(.regular.interactive(), in: Capsule())
        .glassEffectUnion(id: "camera-panels", namespace: glassNamespace)
        .glassEffectID(panel, in: glassNamespace)
#endif
        .accessibilityLabel(panel == .history ? "History timeline" : "Pan, tilt, and zoom")
        .accessibilityValue(selected ? "Shown" : "Hidden")
        .accessibilityHint(selected ? "Hides this panel" : "Shows this panel")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Keep the horizontal anchor inside the protected layout. History centers on
/// the actual timeline; the other states return above the bottom safe inset.
/// A stable canvas and animatable padding move the existing glass capsule in
/// the same panel transition that adds/removes its buttons and the PTZ sliders.
struct CameraPlayerPanelPlacement<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let panel: CameraPlayerPanel
    let timelineBounds: Anchor<CGRect>?
    var leading = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { safe in
            GeometryReader { full in
                let origin = full.frame(in: .global).origin
                let safeBounds = safe.frame(in: .global).offsetBy(dx: -origin.x, dy: -origin.y)
                let restingBottom = max(0, full.size.height - safeBounds.maxY) + CameraPTZOverlayMetrics.inset
                let bottom = panel == .history ? timelineBounds.map {
                    full.size.height - full[$0].midY - CameraPTZOverlayMetrics.buttonSize / 2
                } ?? restingBottom : restingBottom
                content()
                    .padding(leading ? .leading : .trailing, CameraPTZOverlayMetrics.inset)
                    .padding(.bottom, bottom)
                    .frame(width: safeBounds.width, height: full.size.height, alignment: leading ? .bottomLeading : .bottomTrailing)
                    .position(x: safeBounds.midX, y: full.size.height / 2)
                    .animation(reduceMotion ? nil : .snappy, value: bottom)
            }
            .ignoresSafeArea(.container)
        }
        .animation(reduceMotion ? nil : .snappy, value: panel)
    }
}

enum CameraPTZOverlayMetrics {
    static let buttonSize: CGFloat = 44
    static let spacing: CGFloat = 8
    static let inset: CGFloat = 12
    static let sliderPadding: CGFloat = 5
    static var buttonClearance: CGFloat { buttonSize + spacing }

    static func zoomLength(axisLength: CGFloat) -> CGFloat {
        axisLength + buttonClearance
    }
}
