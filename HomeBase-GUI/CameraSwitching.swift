import Combine
import Foundation
import HomeBaseProtocol
import SwiftUI

/// A frozen departure cursor, not a running playback clock. Resolving a local
/// buffer uses the source NVR camera's clock and never the phone's wall clock.
nonisolated enum CameraSwitchPosition: Equatable, Sendable {
    case live
    case canonical(Double, paused: Bool)
    case relative(cameraID: String, offset: Double, capturedAt: Double, paused: Bool)

    /// A history bookmark is a frozen cursor even when playback was running
    /// when the viewer returned to Live.
    var paused: Self {
        switch self {
        case .live:
            return .live
        case .canonical(let time, _):
            return .canonical(time, paused: true)
        case .relative(let cameraID, let offset, let capturedAt, _):
            return .relative(
                cameraID: cameraID,
                offset: offset,
                capturedAt: capturedAt,
                paused: true
            )
        }
    }

    func resolve(using transport: any CameraHistoryFetching,
                 clock: @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) async throws -> Self {
        guard case .relative(let cameraID, let offset, let capturedAt, let paused) = self else { return self }
        let request = HBNVRMediaRequest(requestID: UUID().uuidString, operation: "availability", cameraID: cameraID,
            timeline: "canonical", range: .init(start: -1, end: 0), relativeTo: "live")
        let resolved: CameraHistoryBatch
        do { resolved = try await transport.fetch(request) }
        catch CameraHistoryError.remote(3, _) {
            var fallback = request; fallback.relativeTo = "now"
            resolved = try await transport.fetch(fallback)
        }
        try Task.checkCancellation()
        guard let anchor = resolved.anchor, anchor.isFinite else { throw CameraHistoryError.invalidResponse }
        // The first live/NVR handoff is approximate (separate camera feeds), but
        // time spent preparing the switch must not advance a frozen departure.
        return .canonical(anchor + offset - max(0, clock() - capturedAt), paused: paused)
    }
}

@MainActor
final class CameraScreenSelection: ObservableObject {
    struct Session {
        let id: UUID
        let device: HBTopologyDeviceDescriptor
        let quality: CameraLiveQualitySelection
        let position: CameraSwitchPosition
        init(id: UUID = UUID(), device: HBTopologyDeviceDescriptor, quality: CameraLiveQualitySelection, position: CameraSwitchPosition) {
            self.id = id; self.device = device; self.quality = quality; self.position = position
        }
    }
    @Published private(set) var session: Session
    init(device: HBTopologyDeviceDescriptor, quality: CameraLiveQualitySelection) {
        session = Session(device: device, quality: quality, position: .live)
    }
    func select(_ camera: CameraVideoDevice, position: CameraSwitchPosition) {
        guard camera.id != session.device.identifier else { return }
        session = Session(device: camera.device, quality: camera.capability.fullScreenQuality,
            position: CameraPlaybackHistoryAvailability.isAvailable(in: camera.device.metadata) ? position : .live)
    }

    func retain(_ camera: CameraVideoDevice, quality: CameraLiveQualitySelection) {
        guard camera.id != session.device.identifier || quality != session.quality else { return }
        session = Session(id: session.id, device: camera.device, quality: quality, position: session.position)
    }
}

@MainActor
final class CameraPickerModel: ObservableObject {
    @Published private(set) var cameras: [CameraVideoDevice] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var generation = UUID()
    private let load: () async throws -> [HBTopologyDeviceDescriptor]

    init(load: @escaping () async throws -> [HBTopologyDeviceDescriptor]) { self.load = load }

    func refresh() async {
        let id = UUID(); generation = id
        isLoading = true; error = nil
        defer { if generation == id { isLoading = false } }
        do {
            let devices = try await load()
            try Task.checkCancellation()
            guard generation == id else { return }
            cameras = CameraVideoCatalog.cameras(in: devices).sorted {
                if ($0.artificialFeed == nil) != ($1.artificialFeed == nil) {
                    return $0.artificialFeed == nil
                }
                let order = $0.device.displayName.localizedStandardCompare($1.device.displayName)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
        } catch is CancellationError {} catch {
            if generation == id { self.error = error.localizedDescription }
        }
    }
}

struct CameraPickerPopover: View {
    @ObservedObject var model: CameraPickerModel
    let selectedIDs: Set<String>
    let multiple: Bool
    let toggleMultiple: (Bool) -> Void
    let canSelect: (CameraVideoDevice) -> Bool
    let select: (CameraVideoDevice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isLoading { ProgressView().frame(maxWidth: .infinity) }
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.secondary)
                Button("Try Again", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
            }
            if !model.isLoading, model.error == nil, model.cameras.isEmpty {
                Text("No cameras available").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.cameras) { camera in
                        Button { select(camera) } label: {
                            HStack(spacing: 12) {
                                Text(camera.device.displayName).multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                if multiple {
                                    Image(systemName: selectedIDs.contains(camera.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedIDs.contains(camera.id) ? Color.accentColor : .secondary)
                                        .font(.title3)
                                } else if selectedIDs.contains(camera.id) { Image(systemName: "checkmark").fontWeight(.semibold) }
                            }
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSelect(camera))
                        .accessibilityAddTraits(selectedIDs.contains(camera.id) ? .isSelected : [])
                    }
                }
            }
            .frame(maxHeight: CGFloat(min(max(model.cameras.count, 1), 5)) * 48)
            HStack {
                Spacer()
                Toggle("Multiple", isOn: Binding(get: { multiple }, set: toggleMultiple))
                    .toggleStyle(.button)
            }
        }
        .padding(20)
        .frame(width: 320)
#if os(iOS)
        .presentationCompactAdaptation(.popover)
#endif
        .task { await model.refresh() }
    }
}
