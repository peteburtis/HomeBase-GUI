import SwiftUI
import HomeBaseProtocol

enum CameraGroupLayout {
    enum Arrangement: Equatable { case grid, column }
    enum LabelAnchor: Equatable { case leading, trailing }

    struct VideoGravity: Equatable {
        enum Horizontal: Equatable { case leading, center, trailing }
        enum Vertical: Equatable { case top, center, bottom }

        let horizontal: Horizontal
        let vertical: Vertical

        static let center = VideoGravity(
            horizontal: .center,
            vertical: .center
        )

        var alignment: Alignment {
            let horizontalAlignment: HorizontalAlignment
            switch horizontal {
            case .leading: horizontalAlignment = .leading
            case .center: horizontalAlignment = .center
            case .trailing: horizontalAlignment = .trailing
            }
            let verticalAlignment: VerticalAlignment
            switch vertical {
            case .top: verticalAlignment = .top
            case .center: verticalAlignment = .center
            case .bottom: verticalAlignment = .bottom
            }
            return Alignment(
                horizontal: horizontalAlignment,
                vertical: verticalAlignment
            )
        }
    }

    static func arrangement(
        count: Int,
        in size: CGSize,
        aspectRatios: [CGFloat] = []
    ) -> Arrangement {
        guard count > 1 else { return .grid }
        let gridArea = displayedVideoArea(
            count: count,
            in: size,
            arrangement: .grid,
            aspectRatios: aspectRatios
        )
        let columnArea = displayedVideoArea(
            count: count,
            in: size,
            arrangement: .column,
            aspectRatios: aspectRatios
        )
        return columnArea > gridArea ? .column : .grid
    }

    static func ignoresSafeArea(horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?) -> Bool {
        horizontal == .regular && vertical == .compact
    }

    private static func displayedVideoArea(
        count: Int,
        in size: CGSize,
        arrangement: Arrangement,
        aspectRatios: [CGFloat]
    ) -> CGFloat {
        let cells = cells(count: count, in: size, arrangement: arrangement)
        return cells.enumerated().reduce(0) { total, item in
            let ratio = aspectRatios.indices.contains(item.offset)
                ? aspectRatios[item.offset]
                : 16 / 9
            let frame = videoFrame(in: item.element, aspectRatio: ratio)
            return total + frame.width * frame.height
        }
    }

    static func labelsBelowVideo(count: Int, arrangement: Arrangement) -> Bool {
        count == 2 && arrangement == .grid
    }

    static func labelAnchor(
        index: Int,
        arrangement: Arrangement
    ) -> LabelAnchor {
        arrangement == .grid && !index.isMultiple(of: 2)
            ? .trailing
            : .leading
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

    static func videoGravity(
        index: Int,
        count: Int,
        arrangement: Arrangement
    ) -> VideoGravity {
        guard arrangement == .grid, count > 1 else { return .center }
        let columns = 2
        let rows = count <= 2 ? 1 : 2
        return VideoGravity(
            horizontal: index % columns == 0 ? .trailing : .leading,
            vertical: rows == 1
                ? .center
                : (index / columns == 0 ? .bottom : .top)
        )
    }

    static func videoFrame(
        in cell: CGRect,
        aspectRatio: CGFloat,
        gravity: VideoGravity = .center
    ) -> CGRect {
        let ratio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16 / 9
        let width = min(cell.width, cell.height * ratio), height = min(cell.height, cell.width / ratio)
        let x = switch gravity.horizontal {
        case .leading: cell.minX
        case .center: cell.midX - width / 2
        case .trailing: cell.maxX - width
        }
        let y = switch gravity.vertical {
        case .top: cell.minY
        case .center: cell.midY - height / 2
        case .bottom: cell.maxY - height
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func labelArea(
        in cell: CGRect,
        safeBounds: CGRect,
        aspectRatio: CGFloat,
        gravity: VideoGravity = .center
    ) -> CGRect {
        let video = videoFrame(
            in: cell,
            aspectRatio: aspectRatio,
            gravity: gravity
        )
        let intersection = CGRect(x: video.minX, y: cell.minY, width: video.width, height: cell.height).intersection(safeBounds)
        return intersection.isNull ? .zero : intersection
    }

    static func labelFrame(in cell: CGRect, safeBounds: CGRect, aspectRatio: CGFloat,
                           labelSize: CGSize, belowVideo: Bool,
                           gravity: VideoGravity = .center,
                           anchor: LabelAnchor = .leading) -> CGRect {
        let area = labelArea(
            in: cell,
            safeBounds: safeBounds,
            aspectRatio: aspectRatio,
            gravity: gravity
        )
        let video = videoFrame(
            in: cell,
            aspectRatio: aspectRatio,
            gravity: gravity
        )
        let height = min(labelSize.height, area.height)
        let desiredY = belowVideo ? video.maxY : video.maxY - height
        // If there is insufficient letterboxing, overlap the video rather than
        // putting text behind a screen corner or the home indicator.
        let width = min(labelSize.width, area.width)
        let x = anchor == .leading ? area.minX : area.maxX - width
        return CGRect(x: x, y: max(area.minY, min(desiredY, area.maxY - height)),
                      width: width, height: height)
    }
}

/// Shared with the timeline's hypothetical two-up label-row measurement.
struct CameraGroupCameraLabel: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption).foregroundStyle(.white).lineLimit(1)
            .padding(5)
            .background(
                .black.opacity(0.5),
                ignoresSafeAreaEdges: []
            )
    }
}

/// The container accepts the safe-area-adjusted placement proposal while the
/// nested label keeps its intrinsic background. This prevents the label's
/// background from stretching through a bottom or side safe-area inset.
struct CameraGroupCameraLabelContainer: View {
    let name: String
    let anchor: CameraGroupLayout.LabelAnchor

    var body: some View {
        HStack(spacing: 0) {
            if anchor == .trailing { Spacer(minLength: 0) }
            CameraGroupCameraLabel(name: name)
            if anchor == .leading { Spacer(minLength: 0) }
        }
    }
}

struct CameraGroupLabelLayout: Layout {
    let safeBounds: CGRect
    let aspectRatio: CGFloat
    let belowVideo: Bool
    var gravity: CameraGroupLayout.VideoGravity = .center
    var anchor: CameraGroupLayout.LabelAnchor = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let label = subviews.first else { return }
        let cell = CGRect(origin: .zero, size: bounds.size)
        let area = CameraGroupLayout.labelArea(
            in: cell,
            safeBounds: safeBounds,
            aspectRatio: aspectRatio,
            gravity: gravity
        )
        let size = label.sizeThatFits(ProposedViewSize(width: area.width, height: nil))
        let frame = CameraGroupLayout.labelFrame(in: cell, safeBounds: safeBounds, aspectRatio: aspectRatio,
                                                labelSize: size, belowVideo: belowVideo,
                                                gravity: gravity, anchor: anchor)
        label.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                    anchor: .topLeading, proposal: ProposedViewSize(frame.size))
    }
}

/// Optionally extend the media canvas outside the safe area. Capture the
/// protected layout before expanding, then translate it into the full canvas
/// coordinates. Both modes follow window and toolbar changes without hard-coded
/// insets.
struct CameraGroupCanvas<Content: View>: View {
    let ignoresSafeArea: Bool
    let content: (CGSize, CGRect) -> Content

    init(ignoresSafeArea: Bool = true,
         @ViewBuilder content: @escaping (CGSize, CGRect) -> Content) {
        self.ignoresSafeArea = ignoresSafeArea
        self.content = content
    }

    var body: some View {
        GeometryReader { safe in
            GeometryReader { canvas in
                let origin = canvas.frame(in: .global).origin
                content(canvas.size, safe.frame(in: .global).offsetBy(dx: -origin.x, dy: -origin.y))
            }
            .ignoresSafeArea(.container, edges: ignoresSafeArea ? .all : [])
        }
    }
}

struct CameraGroupVideo: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ObservedObject var group: CameraGroupPlayback
    let cameraControlsEnabled: Bool
    let controlsVisible: Bool
    var isAccessAllowed = true
    let onSingleTap: () -> Void

    var body: some View {
        let ignoresSafeArea = CameraGroupLayout.ignoresSafeArea(
            horizontal: horizontalSizeClass, vertical: verticalSizeClass
        )
        CameraGroupCanvas(ignoresSafeArea: ignoresSafeArea) { size, safeBounds in
            let arrangement = CameraGroupLayout.arrangement(
                count: group.sessions.count,
                in: size,
                aspectRatios: group.sessions.map { $0.liveVideo.aspectRatio }
            )
            let cells = CameraGroupLayout.cells(count: group.sessions.count, in: size, arrangement: arrangement)
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                    if cells.indices.contains(index) {
                        let gravity = CameraGroupLayout.videoGravity(
                            index: index,
                            count: group.sessions.count,
                            arrangement: arrangement
                        )
                        let labelAnchor = CameraGroupLayout.labelAnchor(
                            index: index,
                            arrangement: arrangement
                        )
                        CameraGroupPane(session: session, group: group, cameraControlsEnabled: cameraControlsEnabled,
                            controlsVisible: controlsVisible,
                            isAccessAllowed: isAccessAllowed,
                            safeBounds: safeBounds.offsetBy(dx: -cells[index].minX, dy: -cells[index].minY),
                            videoGravity: gravity,
                            labelAnchor: labelAnchor,
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
    @ObservedObject private var liveVideo: CameraLiveVideoModel
    let cameraControlsEnabled: Bool
    let controlsVisible: Bool
    let isAccessAllowed: Bool
    let safeBounds: CGRect
    let videoGravity: CameraGroupLayout.VideoGravity
    let labelAnchor: CameraGroupLayout.LabelAnchor
    let labelBelowVideo: Bool
    let onSingleTap: () -> Void

    init(session: CameraGroupSession, group: CameraGroupPlayback, cameraControlsEnabled: Bool,
         controlsVisible: Bool,
         isAccessAllowed: Bool,
         safeBounds: CGRect,
         videoGravity: CameraGroupLayout.VideoGravity,
         labelAnchor: CameraGroupLayout.LabelAnchor,
         labelBelowVideo: Bool,
         onSingleTap: @escaping () -> Void) {
        self.session = session; self.group = group
        _playback = ObservedObject(wrappedValue: session.playback)
        _controls = ObservedObject(wrappedValue: session.controls)
        _liveVideo = ObservedObject(wrappedValue: session.liveVideo)
        self.cameraControlsEnabled = cameraControlsEnabled
        self.controlsVisible = controlsVisible
        self.isAccessAllowed = isAccessAllowed
        self.safeBounds = safeBounds
        self.videoGravity = videoGravity
        self.labelAnchor = labelAnchor
        self.labelBelowVideo = labelBelowVideo
        self.onSingleTap = onSingleTap
    }

    private var timeZone: TimeZone { CameraHistoryTimestamp.timeZone(in: controls.deviceMetadata) }
    private var privacy: Bool? { CameraDetailControlSet(controls: controls.controls).observedPrivacyEnabled }
    private var isLive: Bool { group.active ? group.isLive : playback.isLive }
    private var isHistory: Bool { group.active ? group.source == .history : playback.isUsingHistory }
    private var gesturesEnabled: Bool {
        isAccessAllowed && cameraControlsEnabled && group.showsVideo(session) && !CameraLiveVideoLifecycle.isSuspended(in: scenePhase)
    }
    private var panTiltTarget: CameraPanTiltGestureTarget? { CameraPanTiltGestureTarget(controls: controls.controls) }
    private var zoomTarget: CameraZoomGestureTarget? { CameraZoomGestureTarget(controls: controls.controls) }
    private var magnify: ((CameraMagnifyGesturePhase, CGFloat) -> Void)? {
        guard zoomTarget != nil else { return nil }
        return { phase, scale in session.gestures.magnify(phase, scale: scale) }
    }

    var body: some View {
        ZStack {
            CameraLiveVideoSurface(
                model: liveVideo,
                allowsRetry: true,
                usesHistory: !isLive,
                retry: session.restartLiveVideoIfNeeded
            )
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: videoGravity.alignment
                )
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
            if group.hasMultipleCameras && controlsVisible {
                CameraGroupLabelLayout(
                    safeBounds: safeBounds,
                    aspectRatio: liveVideo.aspectRatio,
                    belowVideo: labelBelowVideo,
                    gravity: videoGravity,
                    anchor: labelAnchor
                ) {
                    CameraGroupCameraLabelContainer(
                        name: session.camera.device.displayName,
                        anchor: labelAnchor
                    )
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .onChange(of: gesturesEnabled, initial: true) { _, enabled in session.gestures.update(enabled: enabled) }
        .onChange(of: panTiltTarget?.observedPosition, initial: true) { _, _ in session.gestures.update(enabled: gesturesEnabled) }
        .onChange(of: controls.state) { _, _ in session.gestures.update(enabled: gesturesEnabled) }
        .accessibilityAction(named: "Recenter \(session.camera.device.displayName)") {
            if gesturesEnabled { session.gestures.recenter() }
        }
        .onChange(of: privacy) { old, new in
            if CameraPrivacyStreamRecovery.shouldRequestRestart(from: old, to: new) {
                session.restartLiveVideoIfNeeded()
            }
        }
        .onDisappear { session.gestures.update(enabled: false) }
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
