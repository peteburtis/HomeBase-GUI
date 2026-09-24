//
//  CameraDetailControlsOverlay.swift
//  HomeBase-GUI
//

import Combine
import Foundation
import HomeBaseProtocol
import SwiftUI

struct CameraDetailControlSet {
    let privacy: LiveDeviceControl?
    let pan: LiveDeviceControl?
    let tilt: LiveDeviceControl?
    let zoom: LiveDeviceControl?

    init(controls: [LiveDeviceControl]) {
        privacy = Self.bestControl(for: .privacy, in: controls)
        pan = Self.bestControl(for: .pan, in: controls)
        tilt = Self.bestControl(for: .tilt, in: controls)
        zoom = Self.bestControl(for: .zoom, in: controls)
    }

    var hasPanTilt: Bool {
        pan != nil || tilt != nil
    }

    var hasPTZ: Bool { hasPanTilt || zoom != nil }

    var hasAnyControl: Bool {
        privacy != nil || hasPanTilt || zoom != nil
    }

    var observedPrivacyEnabled: Bool? {
        privacy?.cameraOverlayObservedBooleanValue
    }

    private enum Role {
        case privacy
        case pan
        case tilt
        case zoom
    }

    private static func bestControl(
        for role: Role,
        in controls: [LiveDeviceControl]
    ) -> LiveDeviceControl? {
        controls.compactMap { control -> (Int, LiveDeviceControl)? in
            guard control.cameraOverlayIsReadableAndWritable else {
                return nil
            }
            let score = matchScore(control, for: role)
            guard score > 0 else { return nil }
            if role != .privacy, control.cameraOverlayScalarRange == nil {
                return nil
            }
            return (score, control)
        }
        .max { left, right in left.0 < right.0 }?
        .1
    }

    private static func matchScore(
        _ control: LiveDeviceControl,
        for role: Role
    ) -> Int {
        let metadata = control.cameraOverlayMetadata
        let canonicalComponent = metadata["canonicalComponent"]?
            .stringValue?.lowercased()
        let semanticNames = [
            control.descriptor.controlIdentifier,
            control.descriptor.kind,
        ].map { $0.lowercased() }

        switch role {
        case .privacy:
            if metadata["cameraPrivacy"]?.boolValue == true { return 100 }
            return semanticNames.contains("privacy.enabled") ? 50 : 0
        case .pan:
            if canonicalComponent == "pantilt[0]" { return 100 }
            return semanticNames.contains("ptz.pan.position") ? 50 : 0
        case .tilt:
            if canonicalComponent == "pantilt[1]" { return 100 }
            return semanticNames.contains("ptz.tilt.position") ? 50 : 0
        case .zoom:
            if canonicalComponent == "zoom[0]" { return 100 }
            return semanticNames.contains("ptz.zoom.position") ? 50 : 0
        }
    }
}

enum CameraPrivacyStreamRecovery {
    static func shouldRequestRestart(
        from previousValue: Bool?,
        to currentValue: Bool?
    ) -> Bool {
        previousValue == true && currentValue == false
    }
}

struct CameraPanTiltPosition: Equatable {
    let pan: Double
    let tilt: Double
}

struct CameraPanTiltGestureTarget {
    let canonicalControlPath: String
    let panRange: ClosedRange<Double>
    let tiltRange: ClosedRange<Double>
    let position: CameraPanTiltPosition
    let observedPosition: CameraPanTiltPosition
    let zoom: Double?

    init?(controls: [LiveDeviceControl]) {
        let controlSet = CameraDetailControlSet(controls: controls)
        guard let pan = controlSet.pan,
              let tilt = controlSet.tilt,
              pan.valid != false,
              tilt.valid != false,
              let panRange = pan.cameraOverlayScalarRange,
              let tiltRange = tilt.cameraOverlayScalarRange,
              let panValue = pan.cameraOverlayNumericValue,
              let tiltValue = tilt.cameraOverlayNumericValue,
              let observedPan = pan.cameraOverlayObservedNumericValue,
              let observedTilt = tilt.cameraOverlayObservedNumericValue,
              let canonicalIdentifier = pan.cameraOverlayMetadata[
                "canonicalControl"
              ]?.stringValue,
              let tiltCanonicalIdentifier = tilt.cameraOverlayMetadata[
                "canonicalControl"
              ]?.stringValue,
              tiltCanonicalIdentifier.caseInsensitiveCompare(
                canonicalIdentifier
              )
                == .orderedSame else {
            return nil
        }

        self.panRange = panRange
        self.tiltRange = tiltRange
        position = CameraPanTiltPosition(
            pan: panValue.clamped(to: panRange),
            tilt: tiltValue.clamped(to: tiltRange)
        )
        observedPosition = CameraPanTiltPosition(
            pan: observedPan.clamped(to: panRange),
            tilt: observedTilt.clamped(to: tiltRange)
        )
        canonicalControlPath = Self.canonicalPath(
            derivedControlPath: pan.descriptor.control,
            deviceIdentifier: pan.descriptor.deviceIdentifier,
            canonicalIdentifier: canonicalIdentifier
        )

        let zoomControl = controls.first { control in
            control.cameraOverlayMetadata["canonicalComponent"]?
                .stringValue?.caseInsensitiveCompare("Zoom[0]")
                == .orderedSame
        }
        if let zoomControl {
            guard zoomControl.cameraOverlayMetadata["canonicalControl"]?
                    .stringValue?.caseInsensitiveCompare(canonicalIdentifier)
                    == .orderedSame,
                  let zoomValue = zoomControl.cameraOverlayNumericValue else {
                return nil
            }
            zoom = zoomValue
        } else {
            zoom = nil
        }
    }

    func position(
        afterScrollingBy translation: CGSize,
        in viewport: CGSize
    ) -> CameraPanTiltPosition {
        let width = max(viewport.width, 1)
        let height = max(viewport.height, 1)
        let panSpan = panRange.upperBound - panRange.lowerBound
        let tiltSpan = tiltRange.upperBound - tiltRange.lowerBound
        return CameraPanTiltPosition(
            pan: (position.pan + Double(translation.width / width) * panSpan)
                .clamped(to: panRange),
            tilt: (position.tilt + Double(translation.height / height) * tiltSpan)
                .clamped(to: tiltRange)
        )
    }

    func payload(for position: CameraPanTiltPosition) -> HBJSONValue {
        var object: [String: HBJSONValue] = [
            "PanTilt": .array([
                .number(position.pan.clamped(to: panRange)),
                .number(position.tilt.clamped(to: tiltRange)),
            ]),
        ]
        if let zoom {
            object["Zoom"] = .array([.number(zoom)])
        }
        return .object(object)
    }

    private static func canonicalPath(
        derivedControlPath: String,
        deviceIdentifier: String,
        canonicalIdentifier: String
    ) -> String {
        guard let separator = derivedControlPath.lastIndex(of: ":") else {
            return "\(deviceIdentifier):\(canonicalIdentifier)"
        }
        return String(derivedControlPath[...separator]) + canonicalIdentifier
    }
}

struct CameraZoomGestureTarget {
    private static let rangeFractionPerDoubling = 0.5

    let control: LiveDeviceControl
    let range: ClosedRange<Double>
    let value: Double

    init?(controls: [LiveDeviceControl]) {
        guard let control = CameraDetailControlSet(controls: controls).zoom,
              control.valid != false,
              let range = control.cameraOverlayScalarRange,
              let value = control.cameraOverlayNumericValue else {
            return nil
        }
        self.control = control
        self.range = range
        self.value = value.clamped(to: range)
    }

    func value(afterMagnifyingBy magnification: CGFloat) -> Double {
        let magnification = Double(magnification)
        guard magnification.isFinite, magnification > 0 else { return value }
        let span = range.upperBound - range.lowerBound
        let delta = log2(magnification)
            * span
            * Self.rangeFractionPerDoubling
        return (value + delta).clamped(to: range)
    }
}

@MainActor
final class CameraPanTiltGestureController: ObservableObject {
    private struct WriteRequest {
        let target: CameraPanTiltGestureTarget
        let position: CameraPanTiltPosition
    }

    private static let interactiveWriteInterval = Duration.milliseconds(125)

    private let model: LiveDeviceControlsModel
    private var initialPosition: CameraPanTiltPosition?
    private var dragTarget: CameraPanTiltGestureTarget?
    private var pendingInteractiveWrite: WriteRequest?
    private var interactiveWriteTask: Task<Void, Never>?
    private var interactiveWriteGeneration: UUID?
    private var pendingWrite: WriteRequest?
    private var writerTask: Task<Void, Never>?
    private var writerGeneration: UUID?

    init(model: LiveDeviceControlsModel) {
        self.model = model
    }

    func captureInitialPosition(from target: CameraPanTiltGestureTarget) {
        guard initialPosition == nil else { return }
        initialPosition = target.observedPosition
    }

    func resetInitialPosition() {
        stop()
        initialPosition = nil
    }

    func beginDrag(using target: CameraPanTiltGestureTarget) {
        dragTarget = target
        pendingInteractiveWrite = nil
    }

    func updateDrag(translation: CGSize, viewport: CGSize) {
        guard let dragTarget else { return }
        scheduleInteractiveWrite(WriteRequest(
            target: dragTarget,
            position: dragTarget.position(
                afterScrollingBy: translation,
                in: viewport
            )
        ))
    }

    func endDrag(translation: CGSize, viewport: CGSize) {
        guard let dragTarget else { return }
        let request = WriteRequest(
            target: dragTarget,
            position: dragTarget.position(
                afterScrollingBy: translation,
                in: viewport
            )
        )
        cancelInteractiveThrottle()
        self.dragTarget = nil
        enqueue(request)
    }

    func cancelDrag() {
        dragTarget = nil
        cancelInteractiveThrottle()
    }

    func recenter(using target: CameraPanTiltGestureTarget) {
        guard let initialPosition else { return }
        cancelDrag()
        enqueue(WriteRequest(target: target, position: initialPosition))
    }

    func stop() {
        cancelDrag()
        pendingWrite = nil
        writerTask?.cancel()
        writerTask = nil
        writerGeneration = nil
    }

    private func scheduleInteractiveWrite(_ request: WriteRequest) {
        pendingInteractiveWrite = request
        guard interactiveWriteTask == nil else { return }

        pendingInteractiveWrite = nil
        enqueue(request)

        let generation = UUID()
        interactiveWriteGeneration = generation
        interactiveWriteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        for: Self.interactiveWriteInterval
                    )
                } catch {
                    break
                }
                guard let request = pendingInteractiveWrite else { break }
                pendingInteractiveWrite = nil
                enqueue(request)
            }
            if interactiveWriteGeneration == generation {
                interactiveWriteTask = nil
                interactiveWriteGeneration = nil
            }
        }
    }

    private func cancelInteractiveThrottle() {
        pendingInteractiveWrite = nil
        interactiveWriteTask?.cancel()
        interactiveWriteTask = nil
        interactiveWriteGeneration = nil
    }

    private func enqueue(_ request: WriteRequest) {
        pendingWrite = request
        guard writerTask == nil else { return }

        let generation = UUID()
        writerGeneration = generation
        writerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while let request = pendingWrite {
                pendingWrite = nil
                try? await model.setCanonicalPresentedValue(
                    request.target.payload(for: request.position),
                    controlPath: request.target.canonicalControlPath
                )
            }
            if writerGeneration == generation {
                writerTask = nil
                writerGeneration = nil
            }
        }
    }
}

@MainActor
final class CameraZoomGestureController: ObservableObject {
    private struct WriteRequest {
        let target: CameraZoomGestureTarget
        let value: Double
    }

    private static let interactiveWriteInterval = Duration.milliseconds(125)

    private let model: LiveDeviceControlsModel
    private var magnificationTarget: CameraZoomGestureTarget?
    private var pendingInteractiveWrite: WriteRequest?
    private var interactiveWriteTask: Task<Void, Never>?
    private var interactiveWriteGeneration: UUID?
    private var pendingWrite: WriteRequest?
    private var writerTask: Task<Void, Never>?
    private var writerGeneration: UUID?

    init(model: LiveDeviceControlsModel) {
        self.model = model
    }

    func beginMagnification(using target: CameraZoomGestureTarget) {
        magnificationTarget = target
        pendingInteractiveWrite = nil
    }

    func updateMagnification(_ magnification: CGFloat) {
        guard let magnificationTarget else { return }
        scheduleInteractiveWrite(WriteRequest(
            target: magnificationTarget,
            value: magnificationTarget.value(
                afterMagnifyingBy: magnification
            )
        ))
    }

    func endMagnification(_ magnification: CGFloat) {
        guard let magnificationTarget else { return }
        let request = WriteRequest(
            target: magnificationTarget,
            value: magnificationTarget.value(
                afterMagnifyingBy: magnification
            )
        )
        cancelInteractiveThrottle()
        self.magnificationTarget = nil
        enqueue(request)
    }

    func cancelMagnification() {
        magnificationTarget = nil
        cancelInteractiveThrottle()
    }

    func stop() {
        cancelMagnification()
        pendingWrite = nil
        writerTask?.cancel()
        writerTask = nil
        writerGeneration = nil
    }

    private func scheduleInteractiveWrite(_ request: WriteRequest) {
        pendingInteractiveWrite = request
        guard interactiveWriteTask == nil else { return }

        pendingInteractiveWrite = nil
        enqueue(request)

        let generation = UUID()
        interactiveWriteGeneration = generation
        interactiveWriteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        for: Self.interactiveWriteInterval
                    )
                } catch {
                    break
                }
                guard let request = pendingInteractiveWrite else { break }
                pendingInteractiveWrite = nil
                enqueue(request)
            }
            if interactiveWriteGeneration == generation {
                interactiveWriteTask = nil
                interactiveWriteGeneration = nil
            }
        }
    }

    private func cancelInteractiveThrottle() {
        pendingInteractiveWrite = nil
        interactiveWriteTask?.cancel()
        interactiveWriteTask = nil
        interactiveWriteGeneration = nil
    }

    private func enqueue(_ request: WriteRequest) {
        pendingWrite = request
        guard writerTask == nil else { return }

        let generation = UUID()
        writerGeneration = generation
        writerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while let request = pendingWrite {
                pendingWrite = nil
                try? await model.setPresentedValue(
                    .number(request.value),
                    for: request.target.control,
                    origin: .inline
                )
            }
            if writerGeneration == generation {
                writerTask = nil
                writerGeneration = nil
            }
        }
    }
}

private struct CameraGlassBacker<BackerShape: Shape>: ViewModifier {
    let shape: BackerShape
    let isInteractive: Bool
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
#if os(visionOS)
        content.background(.ultraThinMaterial, in: shape)
            .background(tint ?? .clear, in: shape)
#else
        content.glassEffect(
            .regular.tint(tint).interactive(isInteractive),
            in: shape
        )
#endif
    }
}

extension View {
    func cameraGlassBacker<BackerShape: Shape>(
        in shape: BackerShape,
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
        modifier(CameraGlassBacker(
            shape: shape,
            isInteractive: interactive,
            tint: tint
        ))
    }
}

enum CameraPrivacyButtonPresentation {
    static func systemImageName(privacyEnabled: Bool) -> String {
        privacyEnabled ? "eye.slash" : "eye"
    }
}

enum CameraDayNightMode: String, CaseIterable, Hashable {
    case day
    case night
    case automatic = "auto"

    init?(choiceLabel: String) {
        switch choiceLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "day": self = .day
        case "night": self = .night
        case "auto", "automatic": self = .automatic
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .day: "Day"
        case .night: "Night"
        case .automatic: "Auto"
        }
    }

    var systemImageName: String {
        switch self {
        case .day: "sun.max"
        case .night: "moon"
        case .automatic: "sun.max.fill"
        }
    }
}

struct CameraDayNightModeChoice: Equatable, Identifiable {
    let mode: CameraDayNightMode
    let wireValue: HBJSONValue

    var id: CameraDayNightMode { mode }
}

/// Resolves vendor controls into the camera UI's semantic day/night role.
///
/// Explicit metadata is preferred for future camera modules. The identifier
/// catalog keeps today's vendor-specific controls out of the view itself and
/// can be extended without changing the presentation or wire-value handling.
struct CameraDayNightModeTarget {
    static let semanticMetadataKey = "cameraDayNightMode"
    static let supportedControlIdentifiers = [
        "Camera.Image.DayNightMode",
        "Camera.DayNightMode",
        "Image.DayNightMode",
        "Tapo.Image.DayNightMode",
    ]

    let control: LiveDeviceControl
    let choices: [CameraDayNightModeChoice]
    let selectedMode: CameraDayNightMode?

    init?(controls: [LiveDeviceControl]) {
        let candidates = controls.compactMap {
            control -> (
                score: Int,
                control: LiveDeviceControl,
                choices: [CameraDayNightModeChoice]
            )? in
            guard control.cameraOverlayIsReadableAndWritable,
                  let score = Self.matchScore(for: control),
                  let choices = Self.choices(for: control) else {
                return nil
            }
            return (score, control, choices)
        }
        guard let candidate = candidates.max(by: {
            $0.score < $1.score
        }) else {
            return nil
        }

        control = candidate.control
        choices = candidate.choices
        let presentedValue = candidate.control.pendingValue
            ?? candidate.control.value
        selectedMode = presentedValue.flatMap { value in
            candidate.choices.first(where: {
                $0.wireValue.isEquivalentControlValue(to: value)
            })?.mode
        }
    }

    func wireValue(for mode: CameraDayNightMode) -> HBJSONValue? {
        choices.first(where: { $0.mode == mode })?.wireValue
    }

    private static func choices(
        for control: LiveDeviceControl
    ) -> [CameraDayNightModeChoice]? {
        let schema = ControlValueSchema(
            kind: control.descriptor.kind,
            metadata: control.cameraOverlayMetadata
        )
        guard let advertisedChoices = schema.selectionChoices else {
            return nil
        }

        var choices: [CameraDayNightModeChoice] = []
        for advertisedChoice in advertisedChoices {
            guard let mode = CameraDayNightMode(
                choiceLabel: advertisedChoice.label
            ), !choices.contains(where: { $0.mode == mode }) else {
                continue
            }
            choices.append(CameraDayNightModeChoice(
                mode: mode,
                wireValue: advertisedChoice.value
            ))
        }
        guard choices.count >= 2 else { return nil }
        return choices
    }

    private static func matchScore(
        for control: LiveDeviceControl
    ) -> Int? {
        let metadata = control.cameraOverlayMetadata
        if metadata[semanticMetadataKey]?.boolValue == true {
            return 10_000
        }

        let semanticNames = [
            control.descriptor.controlIdentifier,
            control.descriptor.kind,
        ]
        for (index, identifier) in supportedControlIdentifiers.enumerated()
        where semanticNames.contains(where: {
            $0.caseInsensitiveCompare(identifier) == .orderedSame
        }) {
            return 5_000 - index
        }
        return nil
    }
}

struct CameraPrivacyToolbarControl: View {
    let control: LiveDeviceControl
    @ObservedObject var model: LiveDeviceControlsModel

    var body: some View {
        Toggle(isOn: selection) {
            Label("Privacy mode", systemImage:
                CameraPrivacyButtonPresentation.systemImageName(
                    privacyEnabled: isOn
                ))
        }
        .toggleStyle(.button)
        .disabled(!isEnabled || control.isUpdating)
        .accessibilityLabel("Privacy mode")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(
            isOn ? "Turns privacy mode off" : "Turns privacy mode on"
        )
    }

    private var isOn: Bool {
        control.cameraOverlayBooleanValue ?? false
    }

    private var selection: Binding<Bool> {
        Binding(
            get: { isOn },
            set: { requestedValue in
                guard requestedValue != isOn else { return }
                Task {
                    try? await model.setPresentedValue(
                        control.cameraOverlayBooleanWireValue(requestedValue),
                        for: control,
                        origin: .inline
                    )
                }
            }
        )
    }

    private var isEnabled: Bool {
        model.state == .live
            && control.valid != false
            && control.cameraOverlayBooleanValue != nil
    }
}

struct CameraDayNightModeToolbarControl: View {
    let target: CameraDayNightModeTarget
    @ObservedObject var model: LiveDeviceControlsModel
    var appliesRepeatedSelections = false

    var body: some View {
        Picker(selection: selection) {
            ForEach(target.choices) { choice in
                Label(
                    choice.mode.title,
                    systemImage: choice.mode.systemImageName
                )
                .tag(Optional(choice.mode))
            }
        } label: {
            Label("Day and night mode", systemImage: displayedMode.systemImageName)
        }
        .pickerStyle(.menu)
        .disabled(!isEnabled || target.control.isUpdating)
        .accessibilityLabel("Day and night mode")
        .accessibilityValue(target.selectedMode?.title ?? "Unavailable")
    }

    private var displayedMode: CameraDayNightMode {
        target.selectedMode ?? target.choices[0].mode
    }

    private var isEnabled: Bool {
        model.state == .live
            && target.control.valid != false
            && target.selectedMode != nil
    }

    private var selection: Binding<CameraDayNightMode?> {
        Binding(
            get: { target.selectedMode },
            set: { mode in
                guard let mode,
                      appliesRepeatedSelections
                        || mode != target.selectedMode else {
                    return
                }
                apply(mode)
            }
        )
    }

    private func apply(_ mode: CameraDayNightMode) {
        guard let wireValue = target.wireValue(for: mode) else { return }
        Task { try? await model.setPresentedValue(wireValue, for: target.control, origin: .inline) }
    }
}

struct CameraDetailControlsOverlay: View {
    @ObservedObject var model: LiveDeviceControlsModel

    var body: some View {
        GeometryReader { geometry in
            let controls = CameraDetailControlSet(controls: model.controls)
            let axisLength = Self.axisLength(for: geometry.size)

            ZStack {
                VStack {
                    Spacer(minLength: 0)

                    HStack(alignment: .bottom) {
                        if let zoom = controls.zoom {
                            CameraOverlaySlider(
                                control: zoom, model: model, orientation: .vertical,
                                direction: .normal,
                                length: CameraPTZOverlayMetrics.zoomLength(axisLength: axisLength),
                                interactionEnabled: interactionEnabled(for: zoom)
                            )
                        }

                        Spacer(minLength: 24)

                        if controls.hasPanTilt {
                            panTiltCluster(
                                pan: controls.pan,
                                tilt: controls.tilt,
                                length: axisLength
                            )
                        }
                    }
                    .padding(.horizontal, CameraPTZOverlayMetrics.inset)
                    .padding(.bottom, CameraPTZOverlayMetrics.inset)
                }
            }
        }
    }

    private func panTiltCluster(
        pan: LiveDeviceControl?,
        tilt: LiveDeviceControl?,
        length: CGFloat
    ) -> some View {
        let clearance = CameraPTZOverlayMetrics.buttonClearance

        return ZStack(alignment: .bottomTrailing) {
            if let pan {
                CameraOverlaySlider(
                    control: pan,
                    model: model,
                    orientation: .horizontal,
                    direction: .inverted,
                    length: length,
                    interactionEnabled: interactionEnabled(for: pan)
                )
                .padding(.trailing, clearance)
                .transition(.opacity)
            }

            if let tilt {
                CameraOverlaySlider(
                    control: tilt,
                    model: model,
                    orientation: .vertical,
                    direction: .normal,
                    length: length,
                    interactionEnabled: interactionEnabled(for: tilt)
                )
                .padding(.bottom, clearance)
                .transition(.opacity)
            }
        }
        .frame(
            width: length + clearance + 2 * CameraPTZOverlayMetrics.sliderPadding,
            height: length + clearance + 2 * CameraPTZOverlayMetrics.sliderPadding,
            alignment: .bottomTrailing
        )
    }

    private func interactionEnabled(
        for control: LiveDeviceControl
    ) -> Bool {
        model.state == .live && control.valid != false
    }

    static func axisLength(for size: CGSize) -> CGFloat {
        min(260, max(140, min(size.width * 0.28, size.height * 0.48)))
    }
}

private enum CameraSliderOrientation {
    case horizontal
    case vertical
}

enum CameraOverlaySliderDirection {
    case normal
    case inverted

    func displayedValue(
        for controlValue: Double,
        in range: ClosedRange<Double>
    ) -> Double {
        switch self {
        case .normal:
            controlValue.clamped(to: range)
        case .inverted:
            (range.lowerBound + range.upperBound - controlValue)
                .clamped(to: range)
        }
    }

    func controlValue(
        for displayedValue: Double,
        in range: ClosedRange<Double>
    ) -> Double {
        self.displayedValue(for: displayedValue, in: range)
    }
}

private struct CameraOverlaySlider: View {
    private static let interactiveWriteInterval = Duration.milliseconds(175)

    let control: LiveDeviceControl
    @ObservedObject var model: LiveDeviceControlsModel
    let orientation: CameraSliderOrientation
    let direction: CameraOverlaySliderDirection
    let length: CGFloat
    let interactionEnabled: Bool

    @State private var draftValue: Double
    @State private var isEditing = false
    @State private var pendingInteractiveWrite: Double?
    @State private var interactiveWriteTask: Task<Void, Never>?
    @State private var interactiveWriteGeneration: UUID?
    @State private var pendingWrite: Double?
    @State private var activeWrite: Double?
    @State private var deferredExternalValue: Double?

    init(
        control: LiveDeviceControl,
        model: LiveDeviceControlsModel,
        orientation: CameraSliderOrientation,
        direction: CameraOverlaySliderDirection,
        length: CGFloat,
        interactionEnabled: Bool
    ) {
        self.control = control
        self.model = model
        self.orientation = orientation
        self.direction = direction
        self.length = length
        self.interactionEnabled = interactionEnabled
        let range = control.cameraOverlayScalarRange ?? 0 ... 1
        _draftValue = State(
            initialValue: (control.cameraOverlayNumericValue
                ?? ((range.lowerBound + range.upperBound) / 2))
                .clamped(to: range)
        )
    }

    var body: some View {
        Group {
            if orientation == .vertical {
                slider
                    .frame(width: length)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 44, height: length)
            } else {
                slider
                    .frame(width: length, height: 44)
            }
        }
        .padding(CameraPTZOverlayMetrics.sliderPadding)
        .cameraGlassBacker(in: Capsule(), interactive: true)
        .onChange(of: sourceValue) { _, updatedValue in
            guard let updatedValue else { return }
            let clampedValue = updatedValue.clamped(to: range)
            guard !ownsPresentedValue else {
                deferredExternalValue = clampedValue
                return
            }
            deferredExternalValue = nil
            draftValue = clampedValue
        }
        .onDisappear {
            interactiveWriteTask?.cancel()
            interactiveWriteTask = nil
            interactiveWriteGeneration = nil
            pendingInteractiveWrite = nil
            pendingWrite = nil
            isEditing = false
        }
    }

    private var slider: some View {
        Slider(
            value: Binding(
                get: {
                    direction.displayedValue(
                        for: draftValue,
                        in: range
                    )
                },
                set: { displayedValue in
                    let requestedValue = direction.controlValue(
                        for: displayedValue,
                        in: range
                    )
                    draftValue = requestedValue
                    guard isEditing, canInteract else { return }
                    scheduleInteractiveWrite(requestedValue)
                }
            ),
            in: range,
            onEditingChanged: { editing in
                if editing {
                    deferredExternalValue = nil
                    isEditing = true
                    return
                }

                isEditing = false
                let requestedValue = draftValue.clamped(to: range)
                interactiveWriteTask?.cancel()
                interactiveWriteTask = nil
                interactiveWriteGeneration = nil
                pendingInteractiveWrite = nil
                guard canInteract,
                      requestedValue != sourceValue
                        || activeWrite != nil
                        || pendingWrite != nil else {
                    return
                }
                enqueue(requestedValue)
            }
        )
        .tint(.white)
        .disabled(!canInteract)
        .accessibilityLabel(control.displayName)
        .accessibilityValue(control.presentedValue)
    }

    private var range: ClosedRange<Double> {
        control.cameraOverlayScalarRange ?? 0 ... 1
    }

    private var sourceValue: Double? {
        control.cameraOverlayNumericValue
    }

    private var canInteract: Bool {
        interactionEnabled && sourceValue != nil
    }

    private func scheduleInteractiveWrite(_ value: Double) {
        pendingInteractiveWrite = value
        guard interactiveWriteTask == nil else { return }

        let generation = UUID()
        interactiveWriteGeneration = generation
        interactiveWriteTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.interactiveWriteInterval)
                } catch {
                    break
                }
                guard let nextValue = pendingInteractiveWrite else { break }
                pendingInteractiveWrite = nil
                enqueue(nextValue)
            }
            if interactiveWriteGeneration == generation {
                interactiveWriteTask = nil
                interactiveWriteGeneration = nil
            }
        }
    }

    private func enqueue(_ value: Double) {
        guard value != activeWrite || pendingWrite != nil else { return }
        pendingWrite = value
        guard activeWrite == nil else { return }

        Task { @MainActor in
            while let nextValue = pendingWrite {
                pendingWrite = nil
                activeWrite = nextValue
                do {
                    try await model.setPresentedValue(
                        .number(nextValue),
                        for: control,
                        origin: .inline
                    )
                } catch {
                    if pendingWrite == nil,
                       !isEditing,
                       let deferredExternalValue {
                        draftValue = deferredExternalValue
                    }
                }
                activeWrite = nil
            }
            if !isEditing { deferredExternalValue = nil }
        }
    }

    private var ownsPresentedValue: Bool {
        isEditing || activeWrite != nil || pendingWrite != nil
    }
}

extension LiveDeviceControl {
    var cameraOverlayMetadata: [String: HBJSONValue] {
        var metadata = descriptor.metadata
        if let details {
            metadata.merge(details.metadata) { _, detailsValue in
                detailsValue
            }
        }
        return metadata
    }

    var cameraOverlayIsReadableAndWritable: Bool {
        let metadata = cameraOverlayMetadata
        return metadata["readable"]?.boolValue == true
            && metadata["writable"]?.boolValue == true
            && metadata["structured"]?.boolValue != true
    }

    var cameraOverlayScalarRange: ClosedRange<Double>? {
        let metadata = cameraOverlayMetadata
        guard let minimum = metadata["minimum"]?.numberValue,
              let maximum = metadata["maximum"]?.numberValue,
              minimum.isFinite,
              maximum.isFinite,
              minimum < maximum else { return nil }
        return minimum ... maximum
    }

    var cameraOverlayNumericValue: Double? {
        (pendingValue ?? value)?.numberValue
    }

    var cameraOverlayObservedNumericValue: Double? {
        value?.numberValue
    }

    var cameraOverlayBooleanValue: Bool? {
        let value = pendingValue ?? value
        return Self.cameraOverlayBoolean(from: value)
    }

    var cameraOverlayObservedBooleanValue: Bool? {
        Self.cameraOverlayBoolean(from: value)
    }

    private static func cameraOverlayBoolean(
        from value: HBJSONValue?
    ) -> Bool? {
        if let boolean = value?.boolValue { return boolean }
        if let number = value?.numberValue { return number > 0 }
        return nil
    }

    func cameraOverlayBooleanWireValue(_ enabled: Bool) -> HBJSONValue {
        switch pendingValue ?? value {
        case .bool:
            return .bool(enabled)
        case .number:
            return .number(enabled ? 1 : 0)
        default:
            return .integer(enabled ? 1 : 0)
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
