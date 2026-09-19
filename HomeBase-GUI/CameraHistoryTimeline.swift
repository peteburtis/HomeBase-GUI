import SwiftUI
import Combine
import HomeBaseProtocol
import ImageIO

/// One cell represents twenty minutes, not one seek step. The
/// continuous center cursor can land anywhere inside a cell.
nonisolated enum CameraTimelineScale {
    static let seconds: Double = 20 * 60
    static let cellWidth: Double = 112
    static let thumbnailHeight = cellWidth * 9 / 16
    static let snapDistance: Double = 3
    static let playheadWidth: CGFloat = 2
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
    static func intervalLabelIsVisible(trailingEdge: CGFloat, playhead: CGFloat) -> Bool {
        trailingEdge < playhead - playheadWidth / 2
    }
}

/// Multiple mode budgets against the same hypothetical two-up 16:9 layout,
/// regardless of camera count. Ordinary single-camera mode uses full height.
nonisolated enum CameraTimelineSizing {
    static let standard = CGSize(width: CameraTimelineScale.cellWidth, height: CameraTimelineScale.thumbnailHeight)
    static let minimumHeight: CGFloat = 36
    static let labelGap: CGFloat = 2

    static func thumbnail(in canvas: CGSize, compactHeight: Bool, isMultiple: Bool, cameraLabelHeight: CGFloat,
                          timeLabelHeight: CGFloat) -> CGSize {
        guard isMultiple, compactHeight, canvas.width > 0, canvas.height > 0 else { return standard }
        let videoHeight = min(canvas.height, canvas.width / 2 * 9 / 16)
        let belowVideo = (canvas.height - videoHeight) / 2
        let available = belowVideo - cameraLabelHeight - labelGap - timeLabelHeight
        let height = min(standard.height, max(minimumHeight, available))
        return CGSize(width: height * 16 / 9, height: height)
    }
}

private struct CameraTimelineThumbnailSizeKey: EnvironmentKey {
    static let defaultValue = CameraTimelineSizing.standard
}

extension EnvironmentValues {
    var cameraTimelineThumbnailSize: CGSize {
        get { self[CameraTimelineThumbnailSizeKey.self] }
        set { self[CameraTimelineThumbnailSizeKey.self] = newValue }
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
    private(set) var cellWidth: Double = CameraTimelineScale.cellWidth
    private var unsupported = false
    private let clock: () -> Double
    init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }
    // Teardown is explicit in close(). No executor hop is needed to release
    // these values when SwiftUI destroys its StateObject outside a Swift task.
    nonisolated deinit {}

    var needsConnection: Bool { anchor == nil }
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
    func setViewport(_ width: Double, cellWidth: Double = CameraTimelineScale.cellWidth) {
        let newWidth = max(1, cellWidth), newViewport = max(1, width)
        // Rotation/resizing is layout, not a user seek. Cancel any obsolete
        // scroll gesture before interpreting offsets in the new scale.
        if self.cellWidth != newWidth || viewport != newViewport { dragging = false }
        self.cellWidth = newWidth
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
    private func recenter() {
        guard let cursor, let latest else { return }
        start = CameraTimelineScale.windowStart(at: cursor, latest: latest)
    }
    private func updateWanted() {
        guard let cursor, latest != nil else { return }
        let center = Int(floor(cursor / CameraTimelineScale.seconds))
        // Keep the visible-work set below the cache cap even in a very wide
        // desktop window, so eviction can never cause a perpetual refetch loop.
        let radius = min(23, Int(ceil(viewport / cellWidth / 2)) + 2)
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

/// Compact height is a layout trait, not an orientation or device-name test.
/// Measure the full canvas even when toolbars change its safe area. Only the
/// timeline extends through those insets; regular height keeps the safe layout.
struct CameraTimelinePlacement<Content: View>: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.displayScale) private var displayScale
    @State private var cameraLabelHeight: CGFloat = 26
    @State private var timeLabelHeight: CGFloat = 10
    let isMultiple: Bool
    let content: Content
    init(isMultiple: Bool, @ViewBuilder content: () -> Content) {
        self.isMultiple = isMultiple
        self.content = content()
    }

    var body: some View {
        CameraGroupCanvas { size, safeBounds in
            let compact = verticalSizeClass == .compact
            let bounds = compact ? CGRect(origin: .zero, size: size) : safeBounds
            content
                .environment(\.cameraTimelineThumbnailSize, CameraTimelineSizing.thumbnail(in: size,
                    compactHeight: compact, isMultiple: isMultiple,
                    cameraLabelHeight: cameraLabelHeight, timeLabelHeight: timeLabelHeight))
                .frame(width: bounds.width, height: bounds.height, alignment: .bottom)
                .position(x: bounds.midX, y: bounds.midY)
        }
        .background {
            // Measure the same fonts/padding as the real labels, including
            // Dynamic Type, without depending on any selected camera's label.
            VStack {
                CameraGroupCameraLabel(name: "Camera")
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cameraLabelHeight = $0 }
                CameraTimelineTimeLabelLayout(bottomPadding: 2 / displayScale) {
                    Text("00:00:00").font(.system(size: 10, weight: .semibold).monospacedDigit()).fixedSize()
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { timeLabelHeight = $0 }
            }
            .hidden().accessibilityHidden(true).allowsHitTesting(false)
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
    @StateObject private var model = CameraTimelineModel()
    @State private var scroll = ScrollPosition(x: 0)
    @State private var attempt = 0
    @State private var viewportWidth: CGFloat = 0
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

    var body: some View {
        VStack(spacing: 3) {
            if model.cursor == nil {
                HStack {
                    Text(model.message ?? "Loading timeline…").font(.caption)
                    if model.message != nil { Button("Retry") { attempt += 1 }.font(.caption) }
                }
                .padding(.top, 6)
            }
            if let message = model.message, model.cursor != nil {
                HStack {
                    Text(message).font(.caption2)
                    if model.needsConnection { Button("Retry") { attempt += 1 }.font(.caption) }
                }
                .padding(.top, 6)
            }
            ScrollView(.horizontal) {
                // At most 72 cells. Eager geometry avoids lazy-stack estimates
                // retaining old widths/origins after resizing or rebasing.
                // Preview downloads are still limited to the visible window.
                HStack(spacing: 0) {
                    ForEach(Array(model.tiles), id: \.self) { tile in cell(tile) }
                }
                .padding(.horizontal, viewportWidth / 2)
            }
            // Use the thumbnail and label's natural height: no
            // spare row height or bottom inset below the playhead.
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
                    model.scrub(offset: context.geometry.contentOffset.x + context.geometry.contentInsets.leading)
                    let before = model.cursor, start = model.start
                    if let target = model.endDrag(), isActive, interactionEnabled { onSeek(Date(timeIntervalSince1970: target)) }
                    if !reduceMotion, before != model.cursor, start == model.start {
                        withAnimation(.easeOut(duration: 0.12)) { alignScroll() }
                    } else { alignScroll() }
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
            .overlay {
                Rectangle().fill(.yellow).frame(width: CameraTimelineScale.playheadWidth).allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                if let cursor = model.cursor, let latest = model.latest {
                    CameraTimelineTimeLabelLayout(bottomPadding: 2 / displayScale) {
                        Text(CameraHistoryTimestamp.timelineString(for: Date(timeIntervalSince1970: cursor),
                            latest: Date(timeIntervalSince1970: latest), timeZone: timeZone))
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .lineLimit(1)
                    }
                    .padding(.leading, viewportWidth / 2 + 6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true) // The adjustable timeline announces the full timestamp.
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                viewportWidth = width
                updateScale()
            }
        }
        .background(.black.opacity(0.65))
        .foregroundStyle(.yellow)
        .sensoryFeedback(.selection, trigger: model.feedbackTick)
        .onChange(of: thumbnailSize, initial: true) { _, _ in updateScale() }
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
    private func close() {
        // The timeline can close while the scroll view is still decelerating.
        // Cancel that uncommitted scrub instead of leaving playback paused.
        if model.dragging { onCancel() }
        model.close()
    }
    private func alignScroll() {
        guard !model.dragging, let cursor = model.cursor else { return }
        // The long-lived follow task must read current metrics, not the view
        // value it captured before a size-class/font change.
        scroll.scrollTo(x: CameraTimelineScale.offset(time: cursor, start: model.start, cellWidth: model.cellWidth))
    }
    private func updateScale() {
        model.setViewport(viewportWidth, cellWidth: thumbnailSize.width)
        alignScroll()
    }
    private func cell(_ tile: Int) -> some View {
        let start = Double(tile) * CameraTimelineScale.seconds
        let width = min(thumbnailSize.width, max(0, (model.end - start) / CameraTimelineScale.seconds * thumbnailSize.width))
        let space = timelineSpace, playhead = viewportWidth / 2
        return VStack(spacing: 0) {
            ZStack {
                Color(white: 0.12)
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
            CameraTimelineTimeLabelLayout(bottomPadding: 2 / displayScale) {
                Text(CameraHistoryTimestamp.string(for: Date(timeIntervalSince1970: start), timeZone: timeZone).suffix(8).prefix(5))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .fixedSize()
                    .visualEffect { content, geometry in
                        content.opacity(CameraTimelineScale.intervalLabelIsVisible(
                            trailingEdge: geometry.frame(in: .named(space)).maxX,
                            playhead: playhead) ? 1 : 0)
                    }
                    .frame(width: thumbnailSize.width, alignment: .leading)
            }
        }
        .frame(width: width, alignment: .leading).clipped()
        .accessibilityHidden(true)
    }
}
