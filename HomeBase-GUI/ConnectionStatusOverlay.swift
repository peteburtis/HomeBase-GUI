//
//  ConnectionStatusOverlay.swift
//  HomeBase-GUI
//

import SwiftUI

enum ConnectionStatusPresentation: Equatable {
    case disconnected(String, systemImage: String)
    case pending(String)
    case connected
    case failed(title: String, message: String)
}

struct ConnectionStatusOverlay: View {
    let presentation: ConnectionStatusPresentation
    var route: HomeBaseControlRoute? = nil
    let retry: (() -> Void)?

    var body: some View {
        surfacedStatus
            .shadow(
                color: .black.opacity(0.14),
                radius: 12,
                x: 0,
                y: 6
            )
    }

    private var paddedStatus: some View {
        statusContent
            .font(.footnote)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
    }

    @ViewBuilder
    private var surfacedStatus: some View {
#if os(visionOS)
        paddedStatus
            .background(.regularMaterial, in: backgroundShape)
            .overlay {
                backgroundShape
                    .strokeBorder(.white.opacity(0.32), lineWidth: 0.5)
            }
#else
        paddedStatus
            .glassEffect(.regular, in: backgroundShape)
#endif
    }

    private var backgroundShape: Capsule {
        Capsule(style: .continuous)
    }

    @ViewBuilder
    private var statusContent: some View {
        switch presentation {
        case .disconnected(let text, let systemImage):
            Label(text, systemImage: systemImage)
                .foregroundStyle(.secondary)

        case .pending(let text):
            HStack(spacing: 7) {
                if route == .bluetooth { BluetoothConnectionIcon() }
                ProgressView()
                    .controlSize(.mini)
                Text(text)
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(route == .bluetooth ? "\(text) over Bluetooth" : text)

        case .connected:
            HStack(spacing: 7) {
                if route == .bluetooth {
                    BluetoothConnectionIcon()
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right")
                }
                Text("Connected")
            }
            .foregroundStyle(route == .bluetooth ? Color.blue : Color.green)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(route == .bluetooth ? "Connected over Bluetooth" : "Connected over network")

        case .failed(let title, let message):
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(
                        title,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .fontWeight(.medium)

                    Text(message)
                        .font(.caption)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let retry {
                    Button("Try Again", action: retry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: 420)
            .foregroundStyle(.red)
        }
    }
}

/// The Bluetooth rune is drawn as a vector so it remains crisp at every text
/// size and does not depend on an unavailable platform-specific symbol.
private struct BluetoothConnectionIcon: View {
    @ScaledMetric(relativeTo: .footnote) private var height = 16
    var body: some View {
        BluetoothRune()
            .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .frame(width: height * 0.55, height: height)
            .accessibilityHidden(true)
    }
}

private struct BluetoothRune: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.height * 0.23))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.75))
        path.addLine(to: CGPoint(x: rect.width * 0.45, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.width * 0.45, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.25))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.height * 0.77))
        return path
    }
}

private struct ConnectionStatusControllerKey: EnvironmentKey {
    static let defaultValue: ConnectionStatusController? = nil
}
private struct ConnectionStatusClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}
private struct ConnectionStatusActiveKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    var connectionStatusController: ConnectionStatusController? {
        get { self[ConnectionStatusControllerKey.self] }
        set { self[ConnectionStatusControllerKey.self] = newValue }
    }
    var connectionStatusBottomClearance: CGFloat {
        get { self[ConnectionStatusClearanceKey.self] }
        set { self[ConnectionStatusClearanceKey.self] = newValue }
    }
    var connectionStatusReportingActive: Bool {
        get { self[ConnectionStatusActiveKey.self] }
        set { self[ConnectionStatusActiveKey.self] = newValue }
    }
}

private struct ConnectionStatusHost: ViewModifier {
    @ObservedObject var controller: ConnectionStatusController
    @State private var badgeHeight: CGFloat = 36
    @State private var tabBarFrame: CGRect?
    private let gap: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .environment(\.connectionStatusController, controller)
            .environment(\.connectionStatusBottomClearance,
                         controller.presentation == nil ? 0 : badgeHeight + gap * 2)
#if os(iOS)
            .background(ConnectionStatusTabBarReader { tabBarFrame = $0 })
#endif
            .overlay {
                GeometryReader { geometry in
                    if let presentation = controller.presentation {
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            ConnectionStatusOverlay(presentation: presentation, route: controller.route,
                                retry: controller.canRetry ? { controller.retry() } : nil)
                                .accessibilityIdentifier("connection-status")
#if os(iOS)
                                .background(ConnectionStatusBoundsMarker())
#endif
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { badgeHeight = $0 }
                                .padding(.horizontal, 20)
                                .padding(.bottom, bottomPadding(in: geometry.frame(in: .global)))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
    }

    private func bottomPadding(in bounds: CGRect) -> CGFloat {
        guard let tabBarFrame, tabBarFrame.midY > bounds.midY else { return gap }
        return max(gap, bounds.maxY - tabBarFrame.minY + gap)
    }
}

private struct ConnectionStatusReportModifier: ViewModifier {
    @Environment(\.connectionStatusController) private var controller
    @Environment(\.connectionStatusReportingActive) private var active
    @State private var identifier = UUID()
    @State private var visible = false
    let presentation: ConnectionStatusPresentation?
    let retry: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .connectionStatusClearance()
            .onAppear { visible = true; report() }
            .onChange(of: presentation) { _, _ in report() }
            .onChange(of: active) { _, _ in report() }
            .onDisappear { visible = false; controller?.remove(identifier) }
    }

    private func report() {
        if visible && active { controller?.update(identifier, presentation: presentation, retry: retry) }
        else { controller?.remove(identifier) }
    }
}

/// Footer controls that sit outside a scroll view reserve the same measured
/// space explicitly, so their own feedback cannot overlap the shared badge.
struct ConnectionStatusSpacer: View {
    @Environment(\.connectionStatusBottomClearance) private var clearance
    var body: some View {
        Color.clear.frame(height: clearance)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

private struct ConnectionStatusClearanceModifier: ViewModifier {
    @Environment(\.connectionStatusController) private var controller
    @Environment(\.connectionStatusBottomClearance) private var clearance
    func body(content: Content) -> some View {
        if controller != nil {
            // Reserve scroll-end room, while still allowing content to move
            // underneath the floating indicator in either split-view column.
            content.contentMargins(.bottom, clearance, for: .scrollContent)
        } else { content }
    }
}

extension View {
    func connectionStatusHost(_ controller: ConnectionStatusController) -> some View {
        modifier(ConnectionStatusHost(controller: controller))
    }
    func connectionStatusReport(_ presentation: ConnectionStatusPresentation?,
                                retry: (() -> Void)? = nil) -> some View {
        modifier(ConnectionStatusReportModifier(presentation: presentation, retry: retry))
    }
    func connectionStatusClearance() -> some View {
        modifier(ConnectionStatusClearanceModifier())
    }
    func connectionStatusScope(isActive: Bool) -> some View {
        environment(\.connectionStatusReportingActive, isActive)
    }
    func connectionStatusScopeDisabled() -> some View {
        environment(\.connectionStatusController, nil)
            .environment(\.connectionStatusBottomClearance, 0)
            .environment(\.connectionStatusReportingActive, false)
    }
}
