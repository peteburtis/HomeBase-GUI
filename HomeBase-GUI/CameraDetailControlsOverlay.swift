//
//  CameraDetailControlsOverlay.swift
//  HomeBase-GUI
//

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

private struct CameraGlassBacker<BackerShape: Shape>: ViewModifier {
    let shape: BackerShape
    let isInteractive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
#if os(visionOS)
        content.background(.ultraThinMaterial, in: shape)
#else
        content.glassEffect(
            isInteractive ? .regular.interactive() : .regular,
            in: shape
        )
#endif
    }
}

extension View {
    func cameraGlassBacker<BackerShape: Shape>(
        in shape: BackerShape,
        interactive: Bool = false
    ) -> some View {
        modifier(CameraGlassBacker(
            shape: shape,
            isInteractive: interactive
        ))
    }
}

struct CameraPrivacyToolbarControl: View {
    let control: LiveDeviceControl
    @ObservedObject var model: LiveDeviceControlsModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .accessibilityHidden(true)

            Toggle(
                "Privacy",
                isOn: Binding(
                    get: { isOn },
                    set: { requestedValue in
                        Task {
                            try? await model.setPresentedValue(
                                control.cameraOverlayBooleanWireValue(
                                    requestedValue
                                ),
                                for: control,
                                origin: .inline
                            )
                        }
                    }
                )
            )
            .labelsHidden()
            .disabled(!isEnabled || control.isUpdating)
            .accessibilityLabel("Privacy mode")
            .accessibilityValue(isOn ? "On" : "Off")
        }
        .fixedSize()
    }

    private var isOn: Bool {
        control.cameraOverlayBooleanValue ?? false
    }

    private var isEnabled: Bool {
        model.state == .live
            && control.valid != false
            && control.cameraOverlayBooleanValue != nil
    }
}

struct CameraDetailControlsOverlay: View {
    @ObservedObject var model: LiveDeviceControlsModel
    @State private var isPanTiltExpanded = true
    @State private var isZoomExpanded = true

    var body: some View {
        GeometryReader { geometry in
            let controls = CameraDetailControlSet(controls: model.controls)
            let axisLength = Self.axisLength(for: geometry.size)

            ZStack {
                VStack {
                    Spacer(minLength: 0)

                    HStack(alignment: .bottom) {
                        if let zoom = controls.zoom {
                            zoomCluster(zoom, length: axisLength)
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
                    .padding(.leading, max(18, geometry.safeAreaInsets.leading + 12))
                    .padding(.trailing, max(18, geometry.safeAreaInsets.trailing + 12))
                    .padding(.bottom, max(18, geometry.safeAreaInsets.bottom + 12))
                }
            }
        }
    }

    private func zoomCluster(
        _ control: LiveDeviceControl,
        length: CGFloat
    ) -> some View {
        VStack(spacing: 8) {
            if isZoomExpanded {
                CameraOverlaySlider(
                    control: control,
                    model: model,
                    orientation: .vertical,
                    length: length,
                    interactionEnabled: interactionEnabled(for: control)
                )
                .transition(
                    .opacity.combined(with: .scale(0.8, anchor: .bottom))
                )
            }

            CameraOverlayIcon(
                systemName: "plus.magnifyingglass",
                accessibilityLabel: "zoom controls",
                isExpanded: isZoomExpanded
            ) {
                withAnimation(.snappy) {
                    isZoomExpanded.toggle()
                }
            }
        }
        .animation(.snappy, value: isZoomExpanded)
    }

    private func panTiltCluster(
        pan: LiveDeviceControl?,
        tilt: LiveDeviceControl?,
        length: CGFloat
    ) -> some View {
        let iconLength: CGFloat = 44
        let spacing: CGFloat = 8

        return ZStack(alignment: .bottomTrailing) {
            if isPanTiltExpanded {
                if let pan {
                    CameraOverlaySlider(
                        control: pan,
                        model: model,
                        orientation: .horizontal,
                        length: length,
                        interactionEnabled: interactionEnabled(for: pan)
                    )
                    .padding(.trailing, iconLength + spacing)
                    .transition(.opacity)
                }

                if let tilt {
                    CameraOverlaySlider(
                        control: tilt,
                        model: model,
                        orientation: .vertical,
                        length: length,
                        interactionEnabled: interactionEnabled(for: tilt)
                    )
                    .padding(.bottom, iconLength + spacing)
                    .transition(.opacity)
                }
            }

            CameraOverlayIcon(
                systemName: "arrow.up.and.down.and.arrow.left.and.right",
                accessibilityLabel: "pan and tilt controls",
                isExpanded: isPanTiltExpanded
            ) {
                withAnimation(.snappy) {
                    isPanTiltExpanded.toggle()
                }
            }
        }
        .frame(
            width: isPanTiltExpanded
                ? length + iconLength + spacing
                : iconLength,
            height: isPanTiltExpanded
                ? length + iconLength + spacing
                : iconLength,
            alignment: .bottomTrailing
        )
        .animation(.snappy, value: isPanTiltExpanded)
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

private struct CameraOverlaySlider: View {
    private static let interactiveWriteInterval = Duration.milliseconds(175)

    let control: LiveDeviceControl
    @ObservedObject var model: LiveDeviceControlsModel
    let orientation: CameraSliderOrientation
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
        length: CGFloat,
        interactionEnabled: Bool
    ) {
        self.control = control
        self.model = model
        self.orientation = orientation
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
        .padding(5)
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
        }
    }

    private var slider: some View {
        Slider(
            value: Binding(
                get: { draftValue },
                set: { requestedValue in
                    let requestedValue = requestedValue.clamped(to: range)
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

private struct CameraOverlayIcon: View {
    let systemName: String
    let accessibilityLabel: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .cameraGlassBacker(in: Circle(), interactive: true)
        .accessibilityLabel(
            "\(isExpanded ? "Hide" : "Show") \(accessibilityLabel)"
        )
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
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
