import SwiftUI
import HomeBaseProtocol
#if os(iOS)
import UIKit
#endif

struct CameraDeviceHingeState: Equatable {
    var isPresent = false
    var isClosed = false
}

enum CameraGroupLayout {
    enum Arrangement: Equatable { case grid, column }
    enum LabelAnchor: Equatable { case leading, trailing }

    struct Division: Equatable {
        enum Axis: Equatable { case vertical, horizontal }

        let frame: CGRect
        let margins: EdgeInsets

        var axis: Axis {
            frame.height >= frame.width ? .vertical : .horizontal
        }

        var reservedFrame: CGRect {
            CGRect(
                x: frame.minX - margins.leading,
                y: frame.minY - margins.top,
                width: frame.width + margins.leading + margins.trailing,
                height: frame.height + margins.top + margins.bottom
            )
        }
    }

    struct CanvasPlacement {
        let frame: CGRect
        let safeBounds: CGRect
        let division: Division?

        init(size: CGSize, safeBounds: CGRect, division: Division?, occlusions: [CGRect]) {
            let frame = unobscuredContentRect(in: size, occlusions: occlusions)
            self.frame = frame
            self.safeBounds = safeBounds.offsetBy(dx: -frame.minX, dy: -frame.minY)
            self.division = division.map {
                Division(frame: $0.frame.offsetBy(dx: -frame.minX, dy: -frame.minY), margins: $0.margins)
            }
        }
    }

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

    static func ignoresSafeArea(
        horizontal: UserInterfaceSizeClass?,
        vertical: UserInterfaceSizeClass?,
        controlsVisible: Bool = true,
        hasDeviceHinge: Bool = false
    ) -> Bool {
        !controlsVisible || vertical == .compact
            || (hasDeviceHinge && horizontal == .compact)
    }

    static func avoidsOcclusions(
        horizontal: UserInterfaceSizeClass?,
        hinge: CameraDeviceHingeState
    ) -> Bool {
        horizontal == .compact && !(hinge.isPresent && hinge.isClosed)
    }

    /// Pre-iOS 27.1 has no reserved-region geometry. This is deliberately a
    /// conservative layout-point allowance, not a measured hardware cutout.
    static let legacyOcclusionInset: CGFloat = 64

    static func legacyOcclusionFrames(
        in size: CGSize, isPhone: Bool, ignoresSafeArea: Bool, vertical: UserInterfaceSizeClass?
    ) -> [CGRect] {
        // Native safe areas already avoid the hardware. Only protect the
        // full-bleed phone canvas; don't double-inset normal layouts or iPads.
        // Compact width can persist in landscape. This top/bottom approximation
        // is only for regular height; it must not shrink compact-height video.
        guard isPhone, ignoresSafeArea, vertical == .regular,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return [] }
        let inset = min(legacyOcclusionInset, size.height / 2)
        return [
            CGRect(x: 0, y: 0, width: size.width, height: inset),
            CGRect(x: 0, y: size.height - inset, width: size.width, height: inset),
        ]
    }

    /// Largest axis-aligned rectangle outside every reported obstruction.
    /// A cutout wholly within the top quarter also reserves matching space
    /// below, keeping the content vertically centered rather than bottom-heavy.
    /// Unlike safe-area insets, this doesn't reserve space for system bars.
    /// Region frames already include the system's interactive-content margins.
    static func unobscuredContentRect(in size: CGSize, occlusions: [CGRect]) -> CGRect {
        let bounds = CGRect(origin: .zero, size: size)
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return .zero }
        let obstacles = occlusions.compactMap { frame -> CGRect? in
            guard !frame.isNull, !frame.isEmpty else { return nil }
            let clipped = frame.intersection(bounds)
            return clipped.isNull || clipped.isEmpty ? nil : clipped
        }
        guard !obstacles.isEmpty else { return bounds }
        let balancesVertically = obstacles.contains { $0.maxY <= bounds.height * 0.25 }

        // Every maximal rectangle's left/right edges lie on the canvas or an
        // obstacle edge. For each such span, merge blocked vertical intervals
        // and consider the remaining gaps. No per-device cutout dimensions.
        let xs = Set([bounds.minX, bounds.maxX]
            + obstacles.flatMap { [$0.minX, $0.maxX] }).sorted()
        var best = CGRect.zero
        func consider(_ available: CGRect) {
            var candidate = available
            if balancesVertically {
                // Reflect the larger inset onto the opposite edge. This stays
                // inside the unobscured candidate, even if another obstruction
                // needs more room at the bottom than the top cutout does.
                let inset = max(available.minY, bounds.maxY - available.maxY)
                guard inset < bounds.height / 2 else { return }
                candidate.origin.y = inset
                candidate.size.height = bounds.height - 2 * inset
            }
            guard candidate.width > 0, candidate.height > 0 else { return }
            let area = candidate.width * candidate.height
            let bestArea = best.width * best.height
            let distance = pow(candidate.midX - bounds.midX, 2) + pow(candidate.midY - bounds.midY, 2)
            let bestDistance = pow(best.midX - bounds.midX, 2) + pow(best.midY - bounds.midY, 2)
            // Equal areas prefer the more centered result, then the first
            // (leading/top) candidate, independent of API enumeration order.
            if area > bestArea || (area == bestArea && distance < bestDistance) {
                best = candidate
            }
        }
        for left in xs.indices.dropLast() {
            for right in (left + 1)..<xs.count {
                let blocked = obstacles.filter { $0.minX < xs[right] && $0.maxX > xs[left] }
                    .sorted { $0.minY < $1.minY }
                var y = bounds.minY
                for obstacle in blocked {
                    if obstacle.minY > y {
                        consider(CGRect(x: xs[left], y: y, width: xs[right] - xs[left], height: obstacle.minY - y))
                    }
                    y = max(y, obstacle.maxY)
                }
                consider(CGRect(x: xs[left], y: y, width: xs[right] - xs[left], height: bounds.maxY - y))
            }
        }
        return best
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

    /// Divides the media canvas around the first active fold region. A vertical
    /// fold fills leading then trailing; a horizontal fold is the transpose and
    /// fills top then bottom. Once a third camera is present, each side is split
    /// along its remaining axis.
    static func cells(count: Int, in size: CGSize, division: Division) -> [CGRect] {
        guard (1...4).contains(count), size.width > 0, size.height > 0 else { return [] }
        let bounds = CGRect(origin: .zero, size: size)
        let reserved = division.reservedFrame

        switch division.axis {
        case .vertical:
            let leadingEdge = min(max(reserved.minX, bounds.minX), bounds.maxX)
            let trailingEdge = min(max(reserved.maxX, leadingEdge), bounds.maxX)
            let leading = CGRect(x: bounds.minX, y: bounds.minY,
                                 width: leadingEdge - bounds.minX, height: bounds.height)
            let trailing = CGRect(x: trailingEdge, y: bounds.minY,
                                  width: bounds.maxX - trailingEdge, height: bounds.height)
            if count <= 2 {
                return Array([leading, trailing].prefix(count))
            }
            let leadingHalves = splitVertically(leading)
            let trailingHalves = splitVertically(trailing)
            return Array([
                leadingHalves.0, trailingHalves.0,
                leadingHalves.1, trailingHalves.1,
            ].prefix(count))

        case .horizontal:
            let topEdge = min(max(reserved.minY, bounds.minY), bounds.maxY)
            let bottomEdge = min(max(reserved.maxY, topEdge), bounds.maxY)
            let top = CGRect(x: bounds.minX, y: bounds.minY,
                             width: bounds.width, height: topEdge - bounds.minY)
            let bottom = CGRect(x: bounds.minX, y: bottomEdge,
                                width: bounds.width, height: bounds.maxY - bottomEdge)
            if count <= 2 {
                return Array([top, bottom].prefix(count))
            }
            let topHalves = splitHorizontally(top)
            let bottomHalves = splitHorizontally(bottom)
            return Array([
                topHalves.0, bottomHalves.0,
                topHalves.1, bottomHalves.1,
            ].prefix(count))
        }
    }

    private static func splitVertically(_ frame: CGRect) -> (CGRect, CGRect) {
        let firstHeight = frame.height / 2
        return (
            CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: firstHeight),
            CGRect(x: frame.minX, y: frame.minY + firstHeight,
                   width: frame.width, height: frame.height - firstHeight)
        )
    }

    private static func splitHorizontally(_ frame: CGRect) -> (CGRect, CGRect) {
        let firstWidth = frame.width / 2
        return (
            CGRect(x: frame.minX, y: frame.minY, width: firstWidth, height: frame.height),
            CGRect(x: frame.minX + firstWidth, y: frame.minY,
                   width: frame.width - firstWidth, height: frame.height)
        )
    }

    static func labelAnchor(index: Int, count: Int, divisionAxis: Division.Axis) -> LabelAnchor {
        switch divisionAxis {
        case .vertical:
            return index.isMultiple(of: 2) ? .leading : .trailing
        case .horizontal:
            guard count > 2 else { return .leading }
            return index < 2 ? .leading : .trailing
        }
    }

    static func labelsBelowVideo(count: Int, divisionAxis: Division.Axis) -> Bool {
        count == 2 && divisionAxis == .vertical
    }

    static func videoGravity(
        index: Int,
        count: Int,
        divisionAxis: Division.Axis
    ) -> VideoGravity {
        guard count > 2 else { return .center }
        // Keep each pair touching along its shared edge within a fold pane.
        // Only the reserved division should separate the two fold panes.
        switch divisionAxis {
        case .vertical:
            return VideoGravity(horizontal: .center, vertical: index < 2 ? .bottom : .top)
        case .horizontal:
            return VideoGravity(horizontal: index < 2 ? .trailing : .leading, vertical: .center)
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
/// coordinates. Both modes follow window and toolbar changes. Older iPhones
/// additionally use a fixed cutout allowance when the media is full-bleed.
struct CameraGroupCanvas<Content: View>: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let ignoresSafeArea: Bool
    let avoidsOcclusions: Bool
    let content: (CGSize, CGRect, CameraGroupLayout.Division?) -> Content

    init(ignoresSafeArea: Bool = true, avoidsOcclusions: Bool = false,
         @ViewBuilder content: @escaping (CGSize, CGRect, CameraGroupLayout.Division?) -> Content) {
        self.ignoresSafeArea = ignoresSafeArea
        self.avoidsOcclusions = avoidsOcclusions
        self.content = content
    }

    init(ignoresSafeArea: Bool = true, avoidsOcclusions: Bool = false,
         @ViewBuilder content: @escaping (CGSize, CGRect) -> Content) {
        self.ignoresSafeArea = ignoresSafeArea
        self.avoidsOcclusions = avoidsOcclusions
        self.content = { size, safeBounds, _ in
            content(size, safeBounds)
        }
    }

    var body: some View {
        GeometryReader { safe in
            let hasActiveDivision = firstActiveDivision(in: safe) != nil
            GeometryReader { canvas in
                let origin = canvas.frame(in: .global).origin
                let placement = CameraGroupLayout.CanvasPlacement(
                    size: canvas.size,
                    safeBounds: safe.frame(in: .global).offsetBy(dx: -origin.x, dy: -origin.y),
                    division: firstActiveDivision(in: canvas),
                    occlusions: avoidsOcclusions ? activeOcclusionFrames(in: canvas) : []
                )
                content(
                    placement.frame.size,
                    placement.safeBounds,
                    placement.division
                )
                .frame(width: placement.frame.width, height: placement.frame.height)
                .clipped()
                .position(x: placement.frame.midX, y: placement.frame.midY)
            }
            .ignoresSafeArea(
                .container,
                edges: ignoresSafeArea || hasActiveDivision ? .all : []
            )
        }
    }

    private func activeOcclusionFrames(in proxy: GeometryProxy) -> [CGRect] {
#if os(iOS)
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .occlusion).map(\.frame)
        }
        return CameraGroupLayout.legacyOcclusionFrames(in: proxy.size,
            isPhone: UIDevice.current.userInterfaceIdiom == .phone, ignoresSafeArea: ignoresSafeArea,
            vertical: verticalSizeClass)
#else
        return []
#endif
    }

    private func firstActiveDivision(in proxy: GeometryProxy) -> CameraGroupLayout.Division? {
#if os(iOS)
        if #available(iOS 27.1, *) {
            guard let region = proxy.reservedRegions(kind: .division).first else { return nil }
            return CameraGroupLayout.Division(
                frame: region.frame,
                margins: region.margins
            )
        }
#endif
        return nil
    }
}

/// Observe the scene's hardware capability, not a model name or hinge angle.
/// A Duo still has a hinge when closed or fully open (without an active division).
struct CameraDeviceHingeObserver: ViewModifier {
    @Binding var state: CameraDeviceHingeState

    @ViewBuilder
    func body(content: Content) -> some View {
#if os(iOS)
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, context in
                state = CameraDeviceHingeState(
                    isPresent: context.hinge != nil,
                    isClosed: context.hinge?.status == .closed
                )
            }
        } else {
            content
        }
#else
        content
#endif
    }
}

struct CameraGroupVideo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var deviceHinge = CameraDeviceHingeState()
    @ObservedObject var group: CameraGroupPlayback
    let cameraControlsEnabled: Bool
    let controlsVisible: Bool
    var isExternalDisplay = false
    var isAccessAllowed = true
    var allowsPictureInPicture = false
    var focusedCameraID: String?
    var onFullScreen: ((String) -> Void)?
    let onSingleTap: () -> Void

    var body: some View {
        let presentation = CameraGroupPresentation(sessions: group.sessions, focusedCameraID: focusedCameraID)
        let ignoresSafeArea = isExternalDisplay || CameraGroupLayout.ignoresSafeArea(
            horizontal: horizontalSizeClass,
            vertical: verticalSizeClass,
            controlsVisible: controlsVisible,
            hasDeviceHinge: deviceHinge.isPresent
        )
        CameraGroupCanvas(ignoresSafeArea: ignoresSafeArea, avoidsOcclusions: !isExternalDisplay && CameraGroupLayout.avoidsOcclusions(
            horizontal: horizontalSizeClass, hinge: deviceHinge
        )) { size, safeBounds, division in
            let arrangement = division == nil
                ? CameraGroupLayout.arrangement(
                    count: group.sessions.count,
                    in: size,
                    aspectRatios: group.sessions.map { $0.liveVideo.aspectRatio }
                )
                : .grid
            let cells = if let division {
                CameraGroupLayout.cells(
                    count: group.sessions.count,
                    in: size,
                    division: division
                )
            } else {
                CameraGroupLayout.cells(
                    count: group.sessions.count,
                    in: size,
                    arrangement: arrangement
                )
            }
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                    if cells.indices.contains(index) {
                        let isFocused = presentation.focusedSession === session
                        let frame = presentation.frame(for: session, normal: cells[index], size: size, division: division)
                        let gravity = if isFocused {
                            CameraGroupLayout.VideoGravity.center
                        } else if let division {
                            CameraGroupLayout.videoGravity(
                                index: index,
                                count: group.sessions.count,
                                divisionAxis: division.axis
                            )
                        } else {
                            CameraGroupLayout.videoGravity(
                                index: index,
                                count: group.sessions.count,
                                arrangement: arrangement
                            )
                        }
                        let labelAnchor = if let division {
                            CameraGroupLayout.labelAnchor(
                                index: index,
                                count: group.sessions.count,
                                divisionAxis: division.axis
                            )
                        } else {
                            CameraGroupLayout.labelAnchor(
                                index: index,
                                arrangement: arrangement
                            )
                        }
                        let labelBelowVideo = if let division {
                            CameraGroupLayout.labelsBelowVideo(
                                count: group.sessions.count,
                                divisionAxis: division.axis
                            )
                        } else {
                            CameraGroupLayout.labelsBelowVideo(
                                count: group.sessions.count,
                                arrangement: arrangement
                            )
                        }
                        CameraGroupPane(session: session, group: group,
                            isExternalDisplay: isExternalDisplay,
                            cameraControlsEnabled: cameraControlsEnabled && presentation.isVisible(session),
                            controlsVisible: controlsVisible,
                            isAccessAllowed: isAccessAllowed,
                            allowsPictureInPicture: allowsPictureInPicture,
                            showsCameraLabel: presentation.showsMultipleCameras,
                            onFullScreen: presentation.showsMultipleCameras ? onFullScreen.map { action in { action(session.id) } } : nil,
                            safeBounds: safeBounds.offsetBy(dx: -frame.minX, dy: -frame.minY),
                            videoGravity: gravity,
                            labelAnchor: labelAnchor,
                            labelBelowVideo: labelBelowVideo,
                            onSingleTap: onSingleTap)
                            .modifier(CameraFocusedPanePlacement(frame: frame,
                                isVisible: presentation.isVisible(session), isFocused: isFocused))
                    }
                }
            }
        }
        .modifier(CameraDeviceHingeObserver(state: $deviceHinge))
        .animation(reduceMotion ? nil : .snappy, value: group.sessions.map(\.id))
        .animation(reduceMotion ? nil : .snappy, value: presentation.focusedSession?.id)
    }
}

private struct CameraGroupPane: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var session: CameraGroupSession
    @ObservedObject var group: CameraGroupPlayback
    @ObservedObject private var playback: CameraLivePlaybackController
    @ObservedObject private var controls: LiveDeviceControlsModel
    @ObservedObject private var liveVideo: CameraLiveVideoModel
    let isExternalDisplay: Bool
    let cameraControlsEnabled: Bool
    let controlsVisible: Bool
    let isAccessAllowed: Bool
    let allowsPictureInPicture: Bool
    let showsCameraLabel: Bool
    let onFullScreen: (() -> Void)?
    let safeBounds: CGRect
    let videoGravity: CameraGroupLayout.VideoGravity
    let labelAnchor: CameraGroupLayout.LabelAnchor
    let labelBelowVideo: Bool
    let onSingleTap: () -> Void

    init(session: CameraGroupSession, group: CameraGroupPlayback, isExternalDisplay: Bool, cameraControlsEnabled: Bool,
         controlsVisible: Bool,
         isAccessAllowed: Bool,
         allowsPictureInPicture: Bool,
         showsCameraLabel: Bool,
         onFullScreen: (() -> Void)?,
         safeBounds: CGRect,
         videoGravity: CameraGroupLayout.VideoGravity,
         labelAnchor: CameraGroupLayout.LabelAnchor,
         labelBelowVideo: Bool,
         onSingleTap: @escaping () -> Void) {
        self.session = session; self.group = group
        self.isExternalDisplay = isExternalDisplay
        _playback = ObservedObject(wrappedValue: session.playback)
        _controls = ObservedObject(wrappedValue: session.controls)
        _liveVideo = ObservedObject(wrappedValue: session.liveVideo)
        self.cameraControlsEnabled = cameraControlsEnabled
        self.controlsVisible = controlsVisible
        self.isAccessAllowed = isAccessAllowed
        self.allowsPictureInPicture = allowsPictureInPicture
        self.showsCameraLabel = showsCameraLabel
        self.onFullScreen = onFullScreen
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
                allowsRetry: !isExternalDisplay,
                usesHistory: !isLive,
                isSecondaryOutput: isExternalDisplay,
                retry: session.restartLiveVideoIfNeeded
            )
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: videoGravity.alignment
                )
                .background {
                    if !isExternalDisplay {
                        CameraLiveGestureSurface(videoVisible: group.showsVideo(session), cameraControlsEnabled: gesturesEnabled,
                            onPan: { phase, translation, viewport in session.gestures.pan(phase, translation: translation, viewport: viewport) },
                            onMagnify: magnify, onSingleTap: onSingleTap, onTwoFingerTap: { session.gestures.recenter() })
                    }
                }
            if group.resolvingTime {
                status("Loading history…", loading: true)
            } else if !isLive {
                if let error = playback.errorMessage {
                    VStack(spacing: 12) {
                        Text(error).multilineTextAlignment(.center)
                        if !isExternalDisplay {
                            Button("Try Again", systemImage: "arrow.clockwise") {
                                if group.active { group.retry(session) } else { playback.dismissError(); playback.retryHistory() }
                            }.buttonStyle(.bordered)
                        }
                    }.foregroundStyle(.white).padding()
                } else if isHistory, session.historyAvailable {
                    CameraHistoryStatus(playback: playback, timeZone: timeZone, showsControls: !isExternalDisplay) { previous in
                        if group.active { group.jump(from: session, previous: previous) }
                        else { playback.seekToAdjacentRecording(previous: previous) }
                    }
                } else if !group.showsVideo(session) {
                    status(isHistory ? "No NVR history for this camera" : "No video in this buffer", loading: false)
                }
            }
        }
        .background(Color.black)
#if os(iOS)
        .modifier(CameraPiPPane(session: session, alignment: videoGravity.alignment,
            isLive: isLive))
#endif
        .contextMenu {
            if let onFullScreen {
                Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right", action: onFullScreen)
            }
#if os(iOS)
            CameraPiPMenuItems(session: session, isLive: isLive,
                canStart: isAccessAllowed && allowsPictureInPicture)
#endif
        }
        .overlay {
            if showsCameraLabel && controlsVisible {
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
        .onChange(of: gesturesEnabled, initial: true) { _, enabled in
            if !isExternalDisplay { session.gestures.update(enabled: enabled) }
        }
        .onChange(of: panTiltTarget?.observedPosition, initial: true) { _, _ in
            if !isExternalDisplay { session.gestures.update(enabled: gesturesEnabled) }
        }
        .onChange(of: controls.state) { _, _ in
            if !isExternalDisplay { session.gestures.update(enabled: gesturesEnabled) }
        }
        .accessibilityActions {
            if let onFullScreen { Button("Full Screen", action: onFullScreen) }
        }
        .accessibilityAction(named: "Recenter \(session.camera.device.displayName)") {
            if gesturesEnabled { session.gestures.recenter() }
        }
        .onChange(of: privacy) { old, new in
            if !isExternalDisplay, CameraPrivacyStreamRecovery.shouldRequestRestart(from: old, to: new) {
                session.restartLiveVideoIfNeeded()
            }
        }
        .onDisappear { if !isExternalDisplay { session.gestures.update(enabled: false) } }
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
    var showsControls = true
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
                if showsControls { navigation }
            }.foregroundStyle(.white).padding()
        case .failed(let message):
            VStack(spacing: 12) {
                Text("History unavailable").font(.headline)
                Text(message).font(.callout).multilineTextAlignment(.center)
                if showsControls {
                    Button("Try Again", systemImage: "arrow.clockwise") { playback.retryHistory() }.buttonStyle(.borderedProminent)
                }
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
