import SwiftUI
import Combine
import HomeBaseProtocol
import ImageIO

/// One cell represents twenty minutes, not one seek step. The
/// continuous cursor can land anywhere inside a cell.
nonisolated enum CameraTimelineScale {
    static let seconds: Double = 20 * 60
    static let cellWidth: Double = 112
    static let thumbnailHeight = cellWidth * 9 / 16
    static let snapDistance: Double = 3
    static let playheadWidth: CGFloat = 2
    static let timestampSpacing: CGFloat = 6
    static let windowCells = 72
    static func offset(time: Double, start: Double, cellWidth: Double = cellWidth) -> Double { (time - start) / seconds * cellWidth }
    static func time(offset: Double, start: Double, end: Double, cellWidth: Double = cellWidth) -> Double {
        min(end, max(start, start + offset / cellWidth * seconds))
    }
    static func windowStart(at cursor: Double, latest: Double) -> Double {
        min(floor(cursor / seconds) - 36, floor(latest / seconds) - Double(windowCells) + 1) * seconds
    }
    static func settledTime(_ time: Double, start: Double, end: Double, cellWidth: Double = cellWidth) -> Double {
        let mark = (time / seconds).rounded() * seconds
        guard mark >= start, mark <= end,
              abs(mark - time) / seconds * cellWidth <= snapDistance + 0.000_001 else { return time }
        return mark
    }
    static func intervalLabelIsVisible(frame: CGRect, playhead: CGFloat, timestampWidth: CGFloat) -> Bool {
        if frame.maxX < playhead - playheadWidth / 2 { return true }
        // Wait for the rendered timestamp's width before showing labels on
        // its side. Older footage includes a date, so a fixed exclusion width
        // would either overlap it or unnecessarily hide nearby interval labels.
        return timestampWidth > 0
            && frame.minX > playhead + timestampSpacing + timestampWidth + timestampSpacing
    }
}

/// Timeline previews keep one stable, readable size in every layout. Compact
/// height changes placement relative to safe areas, not the scrubber scale.
nonisolated enum CameraTimelineSizing {
    static let standard = CGSize(width: CameraTimelineScale.cellWidth, height: CameraTimelineScale.thumbnailHeight)
    static let thumbnailToScrubberSpacing: CGFloat = 4
    static let thumbnailOpacity = 0.9
}

private struct CameraTimelineThumbnailSizeKey: EnvironmentKey {
    static let defaultValue = CameraTimelineSizing.standard
}

private struct CameraTimelinePlayheadKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private struct CameraTimelineTrailingControlInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = CameraPTZOverlayMetrics.inset
}

enum CameraTimelineControlPlacement {
    static func trailingInset(in bounds: CGRect, safeBounds: CGRect) -> CGFloat {
        max(0, bounds.maxX - safeBounds.maxX) + CameraPTZOverlayMetrics.inset
    }
}

enum CameraTimelinePlayheadPlacement {
    /// Coordinates are relative to the timeline, not the full media canvas.
    /// Keep the entire marker beyond the fold's frame and recommended margins.
    static func position(in bounds: CGRect, division: CameraGroupLayout.Division?) -> CGFloat? {
        guard let division, division.axis == .vertical,
              division.reservedFrame.intersects(bounds) else { return nil }
        return min(bounds.width, max(0,
            division.reservedFrame.maxX - bounds.minX + CameraTimelineScale.playheadWidth / 2))
    }
}

extension EnvironmentValues {
    var cameraTimelineThumbnailSize: CGSize {
        get { self[CameraTimelineThumbnailSizeKey.self] }
        set { self[CameraTimelineThumbnailSizeKey.self] = newValue }
    }

    var cameraTimelinePlayhead: CGFloat? {
        get { self[CameraTimelinePlayheadKey.self] }
        set { self[CameraTimelinePlayheadKey.self] = newValue }
    }

    var cameraTimelineTrailingControlInset: CGFloat {
        get { self[CameraTimelineTrailingControlInsetKey.self] }
        set { self[CameraTimelineTrailingControlInsetKey.self] = newValue }
    }
}

/// Selection feedback belongs to user scrubbing, never the playback clock.
/// Re-arm after moving two points away, so resting near a mark cannot chatter.
nonisolated struct CameraTimelineDetents {
    private var previous: Double?
    private var latchedMark: Double?
    private var lastPulse = -Double.infinity
    mutating func begin(at time: Double) {
        previous = time; latchedMark = nil; lastPulse = -.infinity
    }
    mutating func advance(to time: Double, now: Double, cellWidth: Double = CameraTimelineScale.cellWidth) -> Bool {
        defer { previous = time }
        guard let previous, time != previous else { return false }
        if let mark = latchedMark, abs(previous - mark) / CameraTimelineScale.seconds * cellWidth > 2 {
            latchedMark = nil
        }
        let mark: Double
        if time > previous {
            mark = floor(time / CameraTimelineScale.seconds) * CameraTimelineScale.seconds
            guard previous < mark else { return false }
        } else {
            mark = ceil(time / CameraTimelineScale.seconds) * CameraTimelineScale.seconds
            guard previous > mark else { return false }
        }
        guard latchedMark != mark else { return false }
        latchedMark = mark
        // Coalesce rapid crossings during a flick rather than queueing buzzes.
        guard now - lastPulse >= 0.06 else { return false }
        lastPulse = now
        return true
    }
}

@MainActor
final class CameraTimelineModel: ObservableObject {
    enum Preview { case image(CGImage), empty, failed }
    struct Entry { let preview: Preview; let expires: Double }
    @Published private(set) var cursor: Double?
    @Published private(set) var latest: Double?
    @Published private(set) var start: Double = 0
    @Published private(set) var previews: [Int: Entry] = [:]
    @Published private(set) var message: String?
    @Published private(set) var dragging = false
    @Published private(set) var feedbackTick = 0
    private var detents = CameraTimelineDetents()
    private var transport: (any CameraThumbnailFetching)?
    private var cameraID = ""
    private var anchor: (utc: Double, host: Double)?
    private var fetchTask: Task<Void, Never>?
    private var generation = UUID()
    private var wanted: [Int] = []
    private var viewport: Double = 700
    private var viewportPlayhead: Double = 350
    private(set) var cellWidth: Double = CameraTimelineScale.cellWidth
    private var unsupported = false
    private let clock: () -> Double
    init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }
    // Teardown is explicit in close(). No executor hop is needed to release
    // these values when SwiftUI destroys its StateObject outside a Swift task.
    nonisolated deinit {}

    var needsConnection: Bool { anchor == nil }
    var dateSelection: CameraHistoryDateSelection? {
        guard !needsConnection, let cursor, let latest else { return nil }
        return .init(date: Date(timeIntervalSince1970: cursor), latestDate: Date(timeIntervalSince1970: latest))
    }
    var end: Double { min(latest ?? start, start + Double(CameraTimelineScale.windowCells) * CameraTimelineScale.seconds) }
    var tiles: Range<Int> {
        Int(floor(start / CameraTimelineScale.seconds))..<max(Int(floor(start / CameraTimelineScale.seconds)), Int(ceil(end / CameraTimelineScale.seconds)))
    }

    func open(cameraID: String, transport: any CameraThumbnailFetching) async {
        close()
        if self.cameraID != cameraID { previews = [:]; cursor = nil }
        self.cameraID = cameraID; self.transport = transport
        let token = generation
        message = nil; unsupported = false
        do {
            var request = HBNVRMediaRequest(requestID: UUID().uuidString, operation: "availability", cameraID: cameraID,
                range: .init(start: -0.001, end: 0), relativeTo: "live")
            let batch: CameraHistoryBatch
            do { batch = try await transport.fetch(request) }
            catch CameraHistoryError.remote(3, _) {
                request.relativeTo = "now"; batch = try await transport.fetch(request)
            }
            try Task.checkCancellation()
            guard generation == token else { return }
            guard let utc = batch.anchor, utc.isFinite, abs(utc) < 1e11 - 86400 else { throw CameraHistoryError.invalidResponse }
            anchor = (utc, clock()); latest = utc
            cursor = min(cursor ?? utc, utc)
            recenter(); updateWanted()
            await transport.start()
        } catch {
            if generation == token, !Task.isCancelled { message = "Timeline unavailable" }
        }
    }

    /// Follow playback without generating a seek. Relative buffer cursors use
    /// the NVR-resolved anchor, never the phone's wall clock.
    func follow(_ position: CameraSwitchPosition) {
        guard !dragging, let anchor else { return }
        let edge = anchor.utc + max(0, clock() - anchor.host)
        latest = edge
        let value: Double
        switch position {
        case .live: value = edge
        case .canonical(let utc, _): value = utc
        case .relative(_, let offset, let capturedAt, _): value = edge + offset - max(0, clock() - capturedAt)
        }
        guard value.isFinite else { return }
        cursor = min(value, edge)
        if cursor! < start + 6 * CameraTimelineScale.seconds || cursor! > end { recenter() }
        updateWanted()
    }
    func setViewport(_ width: Double, cellWidth: Double = CameraTimelineScale.cellWidth, playhead: Double? = nil) {
        let newWidth = max(1, cellWidth), newViewport = max(1, width)
        let newPlayhead = min(newViewport, max(0, playhead ?? newViewport / 2))
        // Rotation/resizing is layout, not a user seek. Cancel any obsolete
        // scroll gesture before interpreting offsets in the new scale.
        if self.cellWidth != newWidth || viewport != newViewport || viewportPlayhead != newPlayhead { dragging = false }
        self.cellWidth = newWidth
        viewportPlayhead = newPlayhead
        viewport = newViewport; updateWanted()
    }
    func beginDrag() {
        guard let cursor, !dragging else { return }
        detents.begin(at: cursor); dragging = true
    }
    func scrub(offset: Double) {
        guard dragging else { return }
        setScrubTime(CameraTimelineScale.time(offset: offset, start: start, end: end, cellWidth: cellWidth))
        updateWanted()
    }
    private func setScrubTime(_ time: Double) {
        if detents.advance(to: time, now: clock(), cellWidth: cellWidth) { feedbackTick &+= 1 }
        cursor = time
    }
    func endDrag() -> Double? {
        guard dragging else { return nil }
        if let cursor { setScrubTime(CameraTimelineScale.settledTime(cursor, start: start, end: end, cellWidth: cellWidth)) }
        dragging = false
        let result = cursor
        // Rebase only after inertia stops. A bounded native scroll view can
        // continue in either direction without allocating an archive-sized list.
        if let cursor, cursor < start + 6 * CameraTimelineScale.seconds || cursor > end - 6 * CameraTimelineScale.seconds { recenter() }
        updateWanted()
        return result
    }
    func cancelDrag() {
        guard dragging else { return }
        dragging = false
        updateWanted()
    }
    private func recenter() {
        guard let cursor, let latest else { return }
        start = CameraTimelineScale.windowStart(at: cursor, latest: latest)
    }
    private func updateWanted() {
        guard let cursor, latest != nil else { return }
        let center = Int(floor(cursor / CameraTimelineScale.seconds))
        // Keep the visible-work set below the cache cap even in a very wide
        // desktop window, so eviction can never cause a perpetual refetch loop.
        // A fold shifts the playhead off-center. Cover the longer visible
        // side as well as the shorter one, without exceeding the cache cap.
        let radius = min(23, Int(ceil(max(viewportPlayhead, viewport - viewportPlayhead) / cellWidth)) + 2)
        let lower = max(tiles.lowerBound, center - radius)
        let upper = max(lower, min(tiles.upperBound, center + radius + 1))
        wanted = (lower..<upper)
            .sorted { abs(Double($0) + 0.5 - cursor / CameraTimelineScale.seconds) < abs(Double($1) + 0.5 - cursor / CameraTimelineScale.seconds) }
        trimPreviews(around: center)
        pump()
    }
    private func trimPreviews(around center: Int) {
        if previews.count > 48 {
            let keep = Set(previews.keys.sorted { abs($0 - center) < abs($1 - center) }.prefix(48))
            previews = previews.filter { keep.contains($0.key) }
        }
    }
    private func pump() {
        guard fetchTask == nil, let transport, !unsupported else { return }
        let token = generation
        fetchTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.fetchTask = nil } }
            while !Task.isCancelled, self.generation == token,
                  let tile = self.wanted.first(where: { self.previews[$0].map { $0.expires <= self.clock() } ?? true }) {
                let midpoint = (Double(tile) + 0.5) * CameraTimelineScale.seconds
                let point = min(midpoint, (self.latest ?? midpoint) - 0.001)
                do {
                    let result = try await transport.thumbnail(.init(requestID: UUID().uuidString, cameraID: self.cameraID,
                        timeline: "canonical", timestamp: point, size: .init(width: 320, height: 180)))
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    let preview: Preview
                    if let result {
                        guard let source = CGImageSourceCreateWithData(result.data as CFData, nil),
                              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                              properties[kCGImagePropertyPixelWidth] as? Int == result.width,
                              properties[kCGImagePropertyPixelHeight] as? Int == result.height,
                              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                              image.width == result.width, image.height == result.height else { throw CameraHistoryError.invalidResponse }
                        preview = .image(image)
                    } else { preview = .empty }
                    // Recent/missing footage can change as shards become readable.
                    let lifetime: Double = result == nil || point < midpoint ? 60 : 3600
                    self.previews[tile] = Entry(preview: preview, expires: self.clock() + lifetime)
                } catch is CancellationError { return }
                catch CameraThumbnailError.unsupported {
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.unsupported = true; self.message = "Update Homebase and HBNVR for timeline previews"; return
                } catch {
                    guard self.generation == token else { return }
                    self.previews[tile] = Entry(preview: .failed, expires: self.clock() + 30)
                }
                self.trimPreviews(around: Int(floor((self.cursor ?? point) / CameraTimelineScale.seconds)))
            }
        }
    }
    func close() {
        generation = UUID(); dragging = false
        previews.removeAll() // Includes decrypted cloud images; never retain across authorization/background changes.
        fetchTask?.cancel(); fetchTask = nil
        let old = transport; transport = nil; anchor = nil
        if let old { Task { await old.close() } }
    }
}

enum CameraTimelinePlacementEdge {
    case top
    case bottom
}

/// Compact height is a layout trait, not an orientation or device-name test.
/// It uses the full canvas under the system bars. Regular height respects the
/// safe bounds, while the timeline itself keeps the same size in both. An active
/// fold keeps the strip full-width and moves only its playhead beyond the fold.
struct CameraTimelinePlacement<Content: View>: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let edge: CameraTimelinePlacementEdge
    let content: Content
    init(
        edge: CameraTimelinePlacementEdge = .bottom,
        @ViewBuilder content: () -> Content
    ) {
        self.edge = edge
        self.content = content()
    }

    var body: some View {
        CameraGroupCanvas { size, safeBounds, division in
            let compact = verticalSizeClass == .compact
            let bounds = compact
                ? CGRect(origin: .zero, size: size)
                : safeBounds
            content
                .environment(\.cameraTimelineThumbnailSize, CameraTimelineSizing.standard)
                .environment(\.cameraTimelinePlayhead,
                    CameraTimelinePlayheadPlacement.position(in: bounds, division: division))
                .environment(\.cameraTimelineTrailingControlInset,
                    CameraTimelineControlPlacement.trailingInset(in: bounds, safeBounds: safeBounds))
                .frame(
                    width: bounds.width,
                    height: bounds.height,
                    alignment: edge == .top ? .top : .bottom
                )
                .position(x: bounds.midX, y: bounds.midY)
        }
    }
}

/// These labels contain only numeric date/time characters, so reserve space to the text's
/// baseline rather than an unused descender region. Keep two physical pixels
/// below the baseline without hard-coding metrics for the system font.
private struct CameraTimelineTimeLabelLayout: Layout {
    let bottomPadding: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let label = subviews.first else { return .zero }
        let dimensions = label.dimensions(in: ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: dimensions.width, height: dimensions[.lastTextBaseline] + bottomPadding)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

struct CameraHistoryTimeline: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.cameraTimelineThumbnailSize) private var thumbnailSize
    @Environment(\.cameraTimelinePlayhead) private var preferredPlayhead
    @Environment(\.cameraTimelineTrailingControlInset) private var trailingControlInset
    @StateObject private var model = CameraTimelineModel()
    @State private var scroll = ScrollPosition(x: 0)
    @State private var attempt = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var timestampWidth: CGFloat = 0
#if os(iOS)
    @State private var toolbarDragStartOffset: Double?
#endif
    @Namespace private var timelineSpace
    struct Source: Equatable { let metadata: HBCameraPlaybackMetadata; let credentials: CameraS3Credentials? }
    private struct ConnectionKey: Equatable { let background: Bool; let attempt: Int; let source: Source? }
    let makeTransport: () async -> any CameraThumbnailFetching
    var source: Source? = nil
    let cameraID: String
    let timeZone: TimeZone
    let position: () -> CameraSwitchPosition
    let onBegin: () -> Void
    let onSeek: (Date) -> Void
    var isActive = true
    var interactionEnabled = true
    var onCancel: () -> Void = {}
    var toolbarScrubRelay: CameraToolbarScrubRelay?
    var onPlayFromDate: ((Date) -> Void)? = nil

    private var playhead: CGFloat {
        min(viewportWidth, max(0, preferredPlayhead ?? viewportWidth / 2))
    }

    var body: some View {
        ScrollView(.horizontal) {
            // At most 72 cells. Eager geometry avoids lazy-stack estimates
            // retaining old widths/origins after resizing or rebasing.
            // Preview downloads are still limited to the visible window.
            HStack(spacing: 0) {
                if model.tiles.isEmpty {
                    referenceCell
                } else {
                    ForEach(Array(model.tiles), id: \.self) { tile in
                        cell(tile)
                    }
                }
            }
            // Asymmetric padding keeps content offsets in time coordinates:
            // the same instant stays under the marker when the fold changes.
            .padding(.leading, playhead)
            .padding(.trailing, viewportWidth - playhead)
        }
        // The invisible reference cell gives the scroll view its final height
        // before availability or thumbnails arrive.
        .fixedSize(horizontal: false, vertical: true)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .contentMargins(.vertical, 0, for: .scrollContent)
        .scrollIndicators(.hidden)
        .scrollDisabled(!isActive || !interactionEnabled)
        .scrollPosition($scroll)
        .coordinateSpace(name: timelineSpace)
        .onScrollGeometryChange(for: Double.self) { Double($0.contentOffset.x + $0.contentInsets.leading) } action: { _, offset in
            model.scrub(offset: offset)
        }
        .onScrollPhaseChange { _, phase, context in
            if phase == .interacting, isActive, interactionEnabled, !model.dragging {
                model.beginDrag()
                if model.dragging { onBegin() }
            }
            if phase == .idle, model.dragging {
#if os(iOS)
                guard toolbarDragStartOffset == nil else { return }
#endif
                finishDrag(offset: context.geometry.contentOffset.x + context.geometry.contentInsets.leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording timeline")
        .accessibilityValue(model.cursor.map { CameraHistoryTimestamp.string(for: Date(timeIntervalSince1970: $0), timeZone: timeZone) } ?? "Loading")
        .accessibilityAdjustableAction { direction in
            guard isActive, interactionEnabled, let cursor = model.cursor else { return }
            onBegin()
            onSeek(Date(timeIntervalSince1970: min(model.latest ?? cursor,
                cursor + (direction == .increment ? 1 : -1) * CameraTimelineScale.seconds)))
        }
        .overlay(alignment: .leading) {
            if model.cursor != nil {
                Rectangle().fill(.yellow).frame(width: CameraTimelineScale.playheadWidth)
                    .offset(x: playhead - CameraTimelineScale.playheadWidth / 2)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let cursor = model.cursor, let latest = model.latest {
                CameraTimelineTimeLabelLayout(bottomPadding: 2 / displayScale) {
                    Text(CameraHistoryTimestamp.timelineString(for: Date(timeIntervalSince1970: cursor),
                        latest: Date(timeIntervalSince1970: latest), timeZone: timeZone))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { timestampWidth = $0 }
                .padding(.leading, playhead + CameraTimelineScale.timestampSpacing)
                .allowsHitTesting(false)
                .accessibilityHidden(true) // The adjustable timeline announces the full timestamp.
            }
        }
        .overlay(alignment: .top) {
            statusOverlay
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            viewportWidth = width
            updateScale()
        }
        .background(.black.opacity(0.65))
        .foregroundStyle(.yellow)
        .overlay(alignment: .trailing) {
            if let onPlayFromDate {
                CameraHistoryCalendarButton(selection: {
                    model.follow(position())
                    return model.dateSelection
                }, timeZone: timeZone,
                    isEnabled: isActive && interactionEnabled && !model.dragging && model.dateSelection != nil,
                    onPlay: onPlayFromDate)
                    .padding(.trailing, trailingControlInset)
            }
        }
        .sensoryFeedback(.selection, trigger: model.feedbackTick)
        .onChange(of: thumbnailSize, initial: true) { _, _ in updateScale() }
        .onChange(of: preferredPlayhead) { _, _ in updateScale() }
#if os(iOS)
        .onReceive(toolbarScrubEvents) { handleToolbarScrub($0) }
#endif
        .task(id: !isActive || scenePhase == .background) {
            guard isActive, scenePhase != .background else { return }
            while !Task.isCancelled {
                model.follow(position())
                if !model.dragging { alignScroll() }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        .task(id: ConnectionKey(background: !isActive || scenePhase == .background, attempt: attempt, source: source)) {
            close()
            guard isActive, scenePhase != .background else { close(); return }
            let transport = await makeTransport()
            guard !Task.isCancelled else { await transport.close(); return }
            await model.open(cameraID: cameraID, transport: transport)
            // The background/disappearance path owns close. An obsolete task
            // must not tear down a newer foreground connection after returning.
            guard !Task.isCancelled else { return }
            model.follow(position()); alignScroll()
        }
        .onDisappear { close() }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if model.cursor == nil {
            HStack {
                Text(model.message ?? "Loading timeline…").font(.caption)
                if model.message != nil {
                    Button("Retry") { attempt += 1 }.font(.caption)
                }
            }
            .padding(.top, 6)
        } else if let message = model.message {
            HStack {
                Text(message).font(.caption2)
                if model.needsConnection {
                    Button("Retry") { attempt += 1 }.font(.caption)
                }
            }
            .padding(.top, 6)
        }
    }

    private var referenceCell: some View {
        VStack(spacing: CameraTimelineSizing.thumbnailToScrubberSpacing) {
            thumbnailGridCell
                .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                .opacity(CameraTimelineSizing.thumbnailOpacity)
            CameraTimelineTimeLabelLayout(bottomPadding: 2 / displayScale) {
                Text("00:00")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .fixedSize()
                    .hidden()
            }
        }
        .frame(width: thumbnailSize.width)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func close() {
        // The timeline can close while the scroll view is still decelerating.
        // Cancel that uncommitted scrub instead of leaving playback paused.
        if model.dragging { onCancel() }
        model.close()
    }
    private func alignScroll(whileDragging: Bool = false) {
        guard (whileDragging || !model.dragging), let cursor = model.cursor else { return }
        // The long-lived follow task must read current metrics, not the view
        // value it captured before a size-class/font change.
        scroll.scrollTo(x: CameraTimelineScale.offset(time: cursor, start: model.start, cellWidth: model.cellWidth))
    }
    private func updateScale() {
        let wasDragging = model.dragging
        model.setViewport(viewportWidth, cellWidth: thumbnailSize.width, playhead: playhead)
        if wasDragging, !model.dragging {
#if os(iOS)
            toolbarDragStartOffset = nil
#endif
            onCancel()
            model.follow(position())
        }
        alignScroll()
    }
    private func finishDrag(offset: Double? = nil) {
        if let offset { model.scrub(offset: offset) }
        let before = model.cursor, start = model.start
        guard let target = model.endDrag() else { return }
        if isActive, interactionEnabled { onSeek(Date(timeIntervalSince1970: target)) }
        if !reduceMotion, before != model.cursor, start == model.start {
            withAnimation(.easeOut(duration: 0.12)) { alignScroll() }
        } else { alignScroll() }
    }
#if os(iOS)
    private var toolbarScrubEvents: AnyPublisher<CameraToolbarScrubEvent, Never> {
        toolbarScrubRelay?.events.eraseToAnyPublisher()
            ?? Empty().eraseToAnyPublisher()
    }

    private func handleToolbarScrub(_ event: CameraToolbarScrubEvent) {
        switch event {
        case .began:
            guard isActive, interactionEnabled, !model.dragging, let cursor = model.cursor else { return }
            toolbarDragStartOffset = CameraTimelineScale.offset(
                time: cursor,
                start: model.start,
                cellWidth: model.cellWidth
            )
            model.beginDrag()
            if model.dragging { onBegin() }
        case .changed(let translation):
            updateToolbarDrag(translation: translation)
        case .ended(let translation):
            guard toolbarDragStartOffset != nil else { return }
            updateToolbarDrag(translation: translation)
            toolbarDragStartOffset = nil
            finishDrag()
        case .cancelled:
            guard toolbarDragStartOffset != nil else { return }
            toolbarDragStartOffset = nil
            model.cancelDrag()
            onCancel()
            model.follow(position())
            alignScroll()
        }
    }

    private func updateToolbarDrag(translation: CGFloat) {
        guard let start = toolbarDragStartOffset, model.dragging else { return }
        model.scrub(offset: start - Double(translation))
        alignScroll(whileDragging: true)
    }
#endif
    private func cell(_ tile: Int) -> some View {
        let start = Double(tile) * CameraTimelineScale.seconds
        let width = min(thumbnailSize.width, max(0, (model.end - start) / CameraTimelineScale.seconds * thumbnailSize.width))
        let space = timelineSpace, playhead = self.playhead, timestampWidth = self.timestampWidth
        return VStack(spacing: CameraTimelineSizing.thumbnailToScrubberSpacing) {
            ZStack {
                thumbnailGridCell
                if let entry = model.previews[tile] {
                    switch entry.preview {
                    case .image(let image): Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    case .empty: Text("No preview").font(.caption2)
                    case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                    }
                } else { ProgressView().controlSize(.mini) }
            }
            .frame(width: thumbnailSize.width, height: thumbnailSize.height)
            .clipped()
            .opacity(CameraTimelineSizing.thumbnailOpacity)
            CameraTimelineTimeLabelLayout(bottomPadding: 2 / displayScale) {
                Text(CameraHistoryTimestamp.string(for: Date(timeIntervalSince1970: start), timeZone: timeZone).suffix(8).prefix(5))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .fixedSize()
                    .visualEffect { content, geometry in
                        content.opacity(CameraTimelineScale.intervalLabelIsVisible(
                            frame: geometry.frame(in: .named(space)),
                            playhead: playhead, timestampWidth: timestampWidth) ? 1 : 0)
                    }
                    .frame(width: thumbnailSize.width, alignment: .leading)
            }
        }
        .frame(width: width, alignment: .leading).clipped()
        .accessibilityHidden(true)
    }

    private var thumbnailGridCell: some View {
        ZStack {
            Color(white: 0.12)
            Rectangle()
                .strokeBorder(.tertiary, lineWidth: 1 / displayScale)
        }
    }
}
