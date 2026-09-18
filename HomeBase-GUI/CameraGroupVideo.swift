import SwiftUI
import HomeBaseProtocol

enum CameraGroupLayout {
    enum Arrangement: Equatable { case grid, column }

    static func arrangement(horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?) -> Arrangement {
        horizontal == .compact && vertical != .compact ? .column : .grid
    }

    static func labelsBelowVideo(count: Int, arrangement: Arrangement) -> Bool {
        count == 2 && arrangement == .grid
    }

    static func cells(count: Int, in size: CGSize, arrangement: Arrangement = .grid) -> [CGRect] {
        guard (1...4).contains(count), size.width > 0, size.height > 0 else { return [] }
        if arrangement == .column && count > 1 {
            // Fit the entire contiguous 16:9 column as a unit. If full-width
            // panes would exceed the canvas height, reduce their common width
            // instead of cropping or scrolling. Actual media still aspect-fits.
            let height = min(size.width * 9 / 16, size.height / CGFloat(count))
            let width = height * 16 / 9
            let x = (size.width - width) / 2
            let y = (size.height - height * CGFloat(count)) / 2
            return (0..<count).map { index in
                CGRect(x: x, y: y + CGFloat(index) * height, width: width, height: height)
            }
        }
        let columns = count == 1 ? 1 : 2, rows = count <= 2 ? 1 : 2
        let width = size.width / CGFloat(columns), height = size.height / CGFloat(rows)
        return (0..<count).map { index in
            CGRect(x: CGFloat(index % columns) * width, y: CGFloat(index / columns) * height, width: width, height: height)
        }
    }

    static func videoFrame(in cell: CGRect, aspectRatio: CGFloat) -> CGRect {
        let ratio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16 / 9
        let width = min(cell.width, cell.height * ratio), height = min(cell.height, cell.width / ratio)
        return CGRect(x: cell.midX - width / 2, y: cell.midY - height / 2, width: width, height: height)
    }

    static func labelArea(in cell: CGRect, safeBounds: CGRect, aspectRatio: CGFloat) -> CGRect {
        let video = videoFrame(in: cell, aspectRatio: aspectRatio)
        let intersection = CGRect(x: video.minX, y: cell.minY, width: video.width, height: cell.height).intersection(safeBounds)
        return intersection.isNull ? .zero : intersection
    }

    static func labelFrame(in cell: CGRect, safeBounds: CGRect, aspectRatio: CGFloat,
                           labelSize: CGSize, belowVideo: Bool) -> CGRect {
        let area = labelArea(in: cell, safeBounds: safeBounds, aspectRatio: aspectRatio)
        let video = videoFrame(in: cell, aspectRatio: aspectRatio)
        let height = min(labelSize.height, area.height)
        let desiredY = belowVideo ? video.maxY : video.maxY - height
        // If there is insufficient letterboxing, overlap the video rather than
        // putting text behind a screen corner or the home indicator.
        return CGRect(x: area.minX, y: max(area.minY, min(desiredY, area.maxY - height)),
                      width: min(labelSize.width, area.width), height: height)
    }
}

/// Shared with the timeline's hypothetical two-up label-row measurement.
struct CameraGroupCameraLabel: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption).foregroundStyle(.white).lineLimit(1)
            .padding(5).background(.black.opacity(0.5))
    }
}

struct CameraGroupLabelLayout: Layout {
    let safeBounds: CGRect
    let aspectRatio: CGFloat
    let belowVideo: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let label = subviews.first else { return }
        let cell = CGRect(origin: .zero, size: bounds.size)
        let area = CameraGroupLayout.labelArea(in: cell, safeBounds: safeBounds, aspectRatio: aspectRatio)
        let size = label.sizeThatFits(ProposedViewSize(width: area.width, height: nil))
        let frame = CameraGroupLayout.labelFrame(in: cell, safeBounds: safeBounds, aspectRatio: aspectRatio,
                                                labelSize: size, belowVideo: belowVideo)
        label.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                    anchor: .topLeading, proposal: ProposedViewSize(frame.size))
    }
}

/// Only the media canvas extends outside the safe area. Capture the protected
/// layout before expanding, then translate it into the full canvas coordinates.
/// This also follows rotation and toolbar visibility without hard-coded insets.
struct CameraGroupCanvas<Content: View>: View {
    let content: (CGSize, CGRect) -> Content

    init(@ViewBuilder content: @escaping (CGSize, CGRect) -> Content) { self.content = content }

    var body: some View {
        GeometryReader { safe in
            GeometryReader { full in
                let origin = full.frame(in: .global).origin
                content(full.size, safe.frame(in: .global).offsetBy(dx: -origin.x, dy: -origin.y))
            }
            .ignoresSafeArea(.container)
        }
    }
}

struct CameraGroupVideo: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ObservedObject var group: CameraGroupPlayback
    let cameraControlsEnabled: Bool
    let controlsVisible: Bool
    let onSingleTap: () -> Void

    var body: some View {
        CameraGroupCanvas { size, safeBounds in
            let arrangement = CameraGroupLayout.arrangement(horizontal: horizontalSizeClass, vertical: verticalSizeClass)
            let cells = CameraGroupLayout.cells(count: group.sessions.count, in: size, arrangement: arrangement)
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                    if cells.indices.contains(index) {
                        CameraGroupPane(session: session, group: group, cameraControlsEnabled: cameraControlsEnabled,
                            controlsVisible: controlsVisible,
                            safeBounds: safeBounds.offsetBy(dx: -cells[index].minX, dy: -cells[index].minY),
                            labelBelowVideo: CameraGroupLayout.labelsBelowVideo(count: group.sessions.count, arrangement: arrangement),
                            onSingleTap: onSingleTap)
                            .frame(width: cells[index].width, height: cells[index].height)
                            .clipped()
                            .position(x: cells[index].midX, y: cells[index].midY)
                    }
                }
            }
        }
        .animation(.snappy, value: group.sessions.map(\.id))
    }
}

private struct CameraGroupPane: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var session: CameraGroupSession
    @ObservedObject var group: CameraGroupPlayback
    @ObservedObject private var playback: CameraLivePlaybackController
    @ObservedObject private var controls: LiveDeviceControlsModel
    @State private var restartRequest = 0
    @State private var aspectRatio: CGFloat = 16 / 9
    let cameraControlsEnabled: Bool
    let controlsVisible: Bool
    let safeBounds: CGRect
    let labelBelowVideo: Bool
    let onSingleTap: () -> Void

    init(session: CameraGroupSession, group: CameraGroupPlayback, cameraControlsEnabled: Bool,
         controlsVisible: Bool,
         safeBounds: CGRect, labelBelowVideo: Bool,
         onSingleTap: @escaping () -> Void) {
        self.session = session; self.group = group
        _playback = ObservedObject(wrappedValue: session.playback)
        _controls = ObservedObject(wrappedValue: session.controls)
        self.cameraControlsEnabled = cameraControlsEnabled
        self.controlsVisible = controlsVisible
        self.safeBounds = safeBounds; self.labelBelowVideo = labelBelowVideo
        self.onSingleTap = onSingleTap
    }

    private var timeZone: TimeZone { CameraHistoryTimestamp.timeZone(in: controls.deviceMetadata) }
    private var privacy: Bool? { CameraDetailControlSet(controls: controls.controls).observedPrivacyEnabled }
    private var isLive: Bool { group.active ? group.isLive : playback.isLive }
    private var isHistory: Bool { group.active ? group.source == .history : playback.isUsingHistory }
    private var gesturesEnabled: Bool {
        cameraControlsEnabled && group.showsVideo(session) && !CameraLiveVideoLifecycle.isSuspended(in: scenePhase)
    }
    private var panTiltTarget: CameraPanTiltGestureTarget? { CameraPanTiltGestureTarget(controls: controls.controls) }
    private var zoomTarget: CameraZoomGestureTarget? { CameraZoomGestureTarget(controls: controls.controls) }
    private var magnify: ((CameraMagnifyGesturePhase, CGFloat) -> Void)? {
        guard zoomTarget != nil else { return nil }
        return { phase, scale in session.gestures.magnify(phase, scale: scale) }
    }

    var body: some View {
        ZStack {
            CameraLiveVideoPlayer(deviceIdentifier: session.camera.device.addressableName, quality: session.quality,
                client: group.client, allowsRetry: true, restartRequest: restartRequest,
                recordingController: session.videoRecordingController, playbackController: playback,
                usesHistory: !isLive, onStateChanged: { session.liveState = $0 },
                onAspectRatioChanged: { aspectRatio = $0 })
                .id(session.quality)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    CameraLiveGestureSurface(videoVisible: group.showsVideo(session), cameraControlsEnabled: gesturesEnabled,
                        onPan: { phase, translation, viewport in session.gestures.pan(phase, translation: translation, viewport: viewport) },
                        onMagnify: magnify, onSingleTap: onSingleTap, onTwoFingerTap: { session.gestures.recenter() })
                }
            if group.resolvingTime {
                status("Loading history…", loading: true)
            } else if !isLive {
                if let error = playback.errorMessage {
                    VStack(spacing: 12) {
                        Text(error).multilineTextAlignment(.center)
                        Button("Try Again", systemImage: "arrow.clockwise") {
                            if group.active { group.retry(session) } else { playback.dismissError(); playback.retryHistory() }
                        }.buttonStyle(.bordered)
                    }.foregroundStyle(.white).padding()
                } else if isHistory, session.historyAvailable {
                    CameraHistoryStatus(playback: playback, timeZone: timeZone) { previous in
                        if group.active { group.jump(from: session, previous: previous) }
                        else { playback.seekToAdjacentRecording(previous: previous) }
                    }
                } else if !group.showsVideo(session) {
                    status(isHistory ? "No NVR history for this camera" : "No video in this buffer", loading: false)
                }
            }
        }
        .background(Color.black)
        .overlay {
            if group.active && controlsVisible {
                CameraGroupLabelLayout(safeBounds: safeBounds, aspectRatio: aspectRatio, belowVideo: labelBelowVideo) {
                    CameraGroupCameraLabel(name: session.camera.device.displayName)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .onChange(of: controls.deviceMetadata, initial: true) { _, metadata in playback.prepareHistory(metadata: metadata, client: group.client) }
        .onChange(of: gesturesEnabled, initial: true) { _, enabled in session.gestures.update(enabled: enabled) }
        .onChange(of: panTiltTarget?.observedPosition, initial: true) { _, _ in session.gestures.update(enabled: gesturesEnabled) }
        .onChange(of: controls.state) { _, _ in session.gestures.update(enabled: gesturesEnabled) }
        .accessibilityAction(named: "Recenter \(session.camera.device.displayName)") {
            if gesturesEnabled { session.gestures.recenter() }
        }
        .onChange(of: privacy) { old, new in
            if CameraPrivacyStreamRecovery.shouldRequestRestart(from: old, to: new) { restartRequest &+= 1 }
        }
        .task(id: CameraLiveVideoLifecycle.isSuspended(in: scenePhase)) {
            if CameraLiveVideoLifecycle.isSuspended(in: scenePhase) {
                playback.suspend(); await controls.stop()
            } else {
                playback.resume()
                playback.prepareHistory(metadata: controls.deviceMetadata, client: group.client)
                await controls.run(reactivating: true)
            }
        }
        .onDisappear { session.gestures.update(enabled: false); Task { await controls.stop() } }
    }

    private func status(_ message: String, loading: Bool) -> some View {
        VStack(spacing: 10) {
            if loading { ProgressView().tint(.white) }
            Text(message).font(.callout).multilineTextAlignment(.center)
            if let date = group.playbackDate {
                Text(CameraHistoryTimestamp.string(for: date, timeZone: timeZone)).font(.caption.monospacedDigit())
            }
        }.foregroundStyle(.white).padding().allowsHitTesting(false)
    }
}

/// The same per-camera gap/retry UI in the single player and in each group pane.
struct CameraHistoryStatus: View {
    @ObservedObject var playback: CameraLivePlaybackController
    let timeZone: TimeZone
    let jump: (Bool) -> Void

    @ViewBuilder var body: some View {
        switch playback.historyState {
        case .idle, .ready: EmptyView()
        case .loading:
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("Loading history…")
                if let date = playback.loadingHistoryDate {
                    Text(CameraHistoryTimestamp.string(for: date, timeZone: timeZone)).font(.callout.monospacedDigit())
                }
            }.foregroundStyle(.white).padding().allowsHitTesting(false)
        case .gap:
            VStack(spacing: 16) {
                Label("No recording at this time", systemImage: "video.slash")
                navigation
            }.foregroundStyle(.white).padding()
        case .failed(let message):
            VStack(spacing: 12) {
                Text("History unavailable").font(.headline)
                Text(message).font(.callout).multilineTextAlignment(.center)
                Button("Try Again", systemImage: "arrow.clockwise") { playback.retryHistory() }.buttonStyle(.borderedProminent)
            }.foregroundStyle(.white).padding()
        }
    }

    @ViewBuilder private var navigation: some View {
        switch playback.historyNavigation {
        case .idle, .loading:
            HStack(spacing: 10) { ProgressView().tint(.white); Text("Finding available video…").font(.callout) }
        case .ready(let neighbors): CameraHistoryNavigationControls(neighbors: neighbors, jump: jump)
        case .failed:
            Button("Find available video", systemImage: "arrow.clockwise") { playback.retryHistory() }.buttonStyle(.bordered)
        case .unsupported:
            Text("Update HBNVR and Homebase to find adjacent recordings.").font(.callout).multilineTextAlignment(.center)
        }
    }
}
