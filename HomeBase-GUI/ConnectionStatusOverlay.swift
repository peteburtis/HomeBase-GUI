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

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if let presentation {
                ConnectionStatusOverlay(
                    presentation: presentation,
                    retry: retry
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
                .zIndex(100)
            }
        }
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
