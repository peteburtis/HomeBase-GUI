import SwiftUI

struct CameraHistoryExportPopover: View {
    @ObservedObject var export: CameraHistoryExportController
    let timeZone: TimeZone
    let start: () -> Void
    let cancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Export History").font(.headline)
                if export.isBusy {
                    if export.isPreparing { ProgressView(export.status) }
                    else {
                        ProgressView(value: export.progress) { Text(export.status) }
                        Text(export.progress, format: .percent.precision(.fractionLength(0)))
                            .font(.caption).monospacedDigit()
                    }
                } else if let draft = export.draft {
                    rangeEditor(draft)
                }
                if let error = export.error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                HStack {
                    Button("Cancel", action: cancel).buttonStyle(.bordered)
                    Spacer()
                    if !export.isBusy, let draft = export.draft {
                        Button("Export", systemImage: "square.and.arrow.up", action: start)
                            .buttonStyle(.borderedProminent)
                            .disabled(draft.validationMessage != nil)
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 350)
        .frame(idealHeight: export.isBusy || export.draft == nil ? 200 : 540, maxHeight: 600)
        .environment(\.timeZone, timeZone)
    }

    private func rangeEditor(_ draft: CameraHistoryExportDraft) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            DatePicker("Start", selection: binding(\.start, fallback: draft.start),
                       displayedComponents: [.date, .hourAndMinute])
            Text(CameraHistoryTimestamp.string(for: draft.start, timeZone: timeZone))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .accessibilityLabel("Exact start time")
            Picker("Export length", selection: binding(\.endSelection, fallback: draft.endSelection)) {
                ForEach(CameraHistoryExportDraft.EndSelection.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            if draft.endSelection == .date {
                DatePicker("End", selection: binding(\.end, fallback: draft.end),
                           displayedComponents: [.date, .hourAndMinute])
            } else {
                Stepper("Hours: \(draft.hours)", value: binding(\.hours, fallback: draft.hours), in: 0...24)
                Stepper("Minutes: \(draft.minutes)", value: binding(\.minutes, fallback: draft.minutes), in: 0...59)
            }
            if let message = draft.validationMessage {
                Text(message).font(.callout).foregroundStyle(.red)
            } else {
                Text("Ends \(CameraHistoryTimestamp.string(for: Date(timeIntervalSince1970: draft.range.end), timeZone: timeZone))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Text("Starts at the preceding keyframe, which may be a little earlier. Each camera exports separately; recording gaps are skipped. Format changes may require separate clips. Up to 24 hours per export.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Times in \(timeZone.identifier). Only existing recordings are exported. Keep the viewer open until the export finishes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .datePickerStyle(.compact)
    }

    private func binding<Value>(_ key: WritableKeyPath<CameraHistoryExportDraft, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { export.draft?[keyPath: key] ?? fallback }, set: { export.draft?[keyPath: key] = $0 })
    }
}
