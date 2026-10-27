import SwiftUI

/// Keeps server switching visually separate from the current screen's actions.
struct ServerToolbar: ToolbarContent {
    let showServers: () -> Void

    var body: some ToolbarContent {
#if os(macOS)
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) { serverButton }
#elseif os(iOS)
        if #available(iOS 27.0, *) {
            // Pinned placement still shares neighboring toolbar backgrounds.
            // Give this item its own native glass button instead.
            ToolbarItem(placement: .topBarPinnedTrailing) {
                serverButton
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) { serverButton }
        }
#else
        ToolbarItem(placement: .primaryAction) { serverButton }
#endif
    }

    private var serverButton: some View {
        Button("Servers", systemImage: "externaldrive.connected.to.line.below", action: showServers)
    }
}
