import SwiftUI

/// History tools stay available whenever shuttles are open or playback is not live.
struct CameraPlaybackControlsPresentation {
    let isLive: Bool
    let timelineVisible: Bool
    var cameraControlsEnabled: Bool { isLive }
    var showsPlaybackSpeed: Bool { !isLive }
}

struct CameraHistoryDateSelection: Identifiable {
    let id = UUID()
    let date: Date
    let latestDate: Date

    init(date: Date, latestDate: Date = .now) {
        self.latestDate = latestDate
        self.date = min(date, latestDate)
    }
}

/// The draft is local to this popover. Only Play seeks; outside-tap dismissal does not.
struct CameraHistoryDatePicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDate: Date
    private let latestDate: Date
    let onPlay: (Date) -> Void

    init(selection: CameraHistoryDateSelection, onPlay: @escaping (Date) -> Void) {
        _selectedDate = State(initialValue: selection.date)
        latestDate = selection.latestDate
        self.onPlay = onPlay
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            DatePicker("Date and time", selection: $selectedDate,
                       in: ...latestDate, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
                .labelsHidden()
            HStack {
                Spacer()
                Button("Play") {
                    onPlay(selectedDate)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 340)
#if os(iOS)
        .presentationCompactAdaptation(.popover)
#endif
    }
}

/// A floating glass control, deliberately not a navigation/toolbar item. Its
/// parent overlays it on the scrubber without changing the scrollable width.
struct CameraHistoryCalendarButton: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var dateSelection: CameraHistoryDateSelection?
    let selection: () -> CameraHistoryDateSelection?
    let timeZone: TimeZone
    let isEnabled: Bool
    let onPlay: (Date) -> Void

    var body: some View {
        Button {
            dateSelection = selection()
        } label: {
            Image(systemName: "calendar")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.primary)
                .frame(width: CameraPTZOverlayMetrics.buttonSize, height: CameraPTZOverlayMetrics.buttonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .cameraGlassBacker(in: Circle(), interactive: true)
        // Own the whole floating control, including the glass, above the scroll view.
        .contentShape(Circle())
        .disabled(!isEnabled)
        .accessibilityLabel("Choose playback date and time")
        .accessibilityHint("Choose a date, then Play to move the playhead. Dismiss to keep the current playback.")
        .accessibilityIdentifier("camera.history.calendar")
        .popover(item: $dateSelection, attachmentAnchor: .rect(.bounds)) { selection in
            CameraHistoryDatePicker(selection: selection) { date in
                guard isEnabled, scenePhase != .background else { return }
                onPlay(date)
            }
            .environment(\.timeZone, timeZone)
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { dateSelection = nil }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { dateSelection = nil }
        }
        .onDisappear { dateSelection = nil }
    }
}
