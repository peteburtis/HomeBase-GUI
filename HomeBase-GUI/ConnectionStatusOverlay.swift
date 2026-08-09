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
    let retry: (() -> Void)?

    var body: some View {
        statusContent
            .font(.footnote)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: backgroundShape)
            .overlay {
                backgroundShape
                    .strokeBorder(.white.opacity(0.32), lineWidth: 0.5)
            }
            .shadow(
                color: .black.opacity(0.38),
                radius: 24,
                x: 0,
                y: 12
            )
            .shadow(
                color: .black.opacity(0.20),
                radius: 5,
                x: 0,
                y: 2
            )
    }

    private var backgroundShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    @ViewBuilder
    private var statusContent: some View {
        switch presentation {
        case .disconnected(let text, let systemImage):
            Label(text, systemImage: systemImage)
                .foregroundStyle(.secondary)

        case .pending(let text):
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.mini)
                Text(text)
            }
            .foregroundStyle(.secondary)

        case .connected:
            Label(
                "Connected",
                systemImage: "dot.radiowaves.left.and.right"
            )
            .foregroundStyle(.green)

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

private struct ConnectionStatusOverlayModifier: ViewModifier {
    let presentation: ConnectionStatusPresentation?
    let retry: (() -> Void)?
    @State private var insetHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: -insetHeight) {
                if let presentation {
                    ConnectionStatusOverlay(
                        presentation: presentation,
                        retry: retry
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ConnectionStatusOverlayHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    }
                    .zIndex(100)
                }
            }
            .onPreferenceChange(ConnectionStatusOverlayHeightKey.self) {
                insetHeight = presentation == nil ? 0 : $0
            }
            .onChange(of: presentation) { _, presentation in
                if presentation == nil {
                    insetHeight = 0
                }
            }
    }
}

private struct ConnectionStatusOverlayHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    func connectionStatusOverlay(
        _ presentation: ConnectionStatusPresentation?,
        retry: (() -> Void)? = nil
    ) -> some View {
        modifier(
            ConnectionStatusOverlayModifier(
                presentation: presentation,
                retry: retry
            )
        )
    }
}
