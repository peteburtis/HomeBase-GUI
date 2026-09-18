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

/// The draft is local to this popover. Only Jump seeks; outside-tap dismissal does not.
struct CameraHistoryDatePicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDate: Date
    private let latestDate: Date
    let onJump: (Date) -> Void

    init(selection: CameraHistoryDateSelection, onJump: @escaping (Date) -> Void) {
        _selectedDate = State(initialValue: selection.date)
        latestDate = selection.latestDate
        self.onJump = onJump
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Jump to Date").font(.headline)
            DatePicker("Date and time", selection: $selectedDate,
                       in: ...latestDate, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
            HStack {
                Spacer()
                Button("Jump") {
                    onJump(selectedDate)
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
