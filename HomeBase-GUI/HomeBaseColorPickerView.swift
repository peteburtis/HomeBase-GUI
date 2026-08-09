//
//  HomeBaseColorPickerView.swift
//  HomeBase-GUI
//

import CoreGraphics
import Foundation
import HomeBaseProtocol
import SwiftUI

struct HomeBaseColorPickerObservation: Equatable, Sendable {
    let value: HBJSONValue?
    let aggregateState: HBControlAggregateState?
    let aggregateValues: [HBJSONValue]?
    let aggregateValueCount: Int?
}

struct HomeBaseColorPickerCapabilities: Equatable {
    let supportsRGB: Bool
    let supportsWhite: Bool
    let supportsXY: Bool

    init?(controlKind: String) {
        let components = controlKind.lowercased().split(
            separator: ":",
            maxSplits: 1
        )
        guard components.count == 2,
              components[0] == "color-v1" else {
            return nil
        }
        let modes = Set(components[1].split(separator: "+").map(String.init))
        supportsRGB = modes.contains("rgb")
        supportsWhite = modes.contains("white")
        supportsXY = modes.contains("xy")
        guard supportsChromatic || supportsWhite else { return nil }
    }

    var supportsChromatic: Bool {
        supportsRGB || supportsXY
    }
}

@MainActor
struct HomeBaseColorPickerView: View {
    @Environment(\.scenePhase) private var scenePhase

    private enum FocusedField: Hashable {
        case htmlRGB
        case whiteKelvin
    }

    private enum Mode: String, CaseIterable, Identifiable {
        case color
        case white

        var id: Self { self }

        var title: String {
            switch self {
            case .color: "Color"
            case .white: "White"
            }
        }
    }

    let capabilities: HomeBaseColorPickerCapabilities
    let liveValues: () -> AsyncThrowingStream<
        HomeBaseColorPickerObservation,
        Error
    >
    let setValue: (HBJSONValue) async throws -> Void

    @State private var mode: Mode
    @State private var chromaticSelection: CGPoint?
    @State private var whiteSelection: CGPoint?
    @State private var chromaticConstituentSelections: [CGPoint]
    @State private var whiteConstituentSelections: [CGPoint]
    @State private var aggregateValueCount: Int?
    @State private var pendingInteractiveWrite: HBJSONValue?
    @State private var interactiveWriteTask: Task<Void, Never>?
    @State private var interactiveWriteGeneration: UUID?
    @State private var pendingWrite: HBJSONValue?
    @State private var isSending = false
    @State private var updateError: String?
    @State private var htmlRGBText: String
    @State private var htmlRGBError: String?
    @State private var whiteKelvinText: String
    @State private var whiteKelvinError: String?
    @State private var isManipulating = false
    @State private var deferredLiveObservation: HomeBaseColorPickerObservation?
    @State private var liveUpdateDeadline: Date?
    @State private var resumeLiveUpdatesTask: Task<Void, Never>?
    @FocusState private var focusedField: FocusedField?

    init(
        capabilities: HomeBaseColorPickerCapabilities,
        initialValue: HBJSONValue?,
        aggregateState: HBControlAggregateState?,
        aggregateValues: [HBJSONValue]?,
        aggregateValueCount: Int?,
        liveValues: @escaping () -> AsyncThrowingStream<
            HomeBaseColorPickerObservation,
            Error
        >,
        setValue: @escaping (HBJSONValue) async throws -> Void
    ) {
        self.capabilities = capabilities
        self.liveValues = liveValues
        self.setValue = setValue

        let initialMode = Self.initialMode(
            capabilities: capabilities,
            initialValue: initialValue,
            aggregateValues: aggregateValues
        )
        let initialChromaticSelection = initialValue.flatMap { value in
            HomeBaseColorPickerMapping.chromaticLocation(for: value)
        }
        let initialWhiteKelvin = initialValue.flatMap { value in
            HomeBaseColorPickerMapping.whiteKelvin(from: value)
        }
        let initialConstituentSelections = Self.constituentSelections(
            aggregateState == .mixed ? aggregateValues : nil
        )
        _mode = State(initialValue: initialMode)
        _chromaticSelection = State(initialValue: initialChromaticSelection)
        _chromaticConstituentSelections = State(
            initialValue: initialConstituentSelections.chromatic
        )
        _whiteConstituentSelections = State(
            initialValue: initialConstituentSelections.white
        )
        _aggregateValueCount = State(
            initialValue: aggregateState == .mixed
                ? aggregateValueCount
                : nil
        )
        _htmlRGBText = State(
            initialValue: initialChromaticSelection.flatMap { location in
                HomeBaseColorPickerMapping.htmlRGB(at: location)
            } ?? ""
        )
        _whiteKelvinText = State(
            initialValue: initialWhiteKelvin.map(Self.kelvinText) ?? ""
        )
        _whiteSelection = State(
            initialValue: initialWhiteKelvin.map { kelvin in
                HomeBaseColorPickerMapping.whiteLocation(kelvin: kelvin)
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if capabilities.supportsChromatic,
                   capabilities.supportsWhite {
                    Picker("Color mode", selection: modeBinding) {
                        ForEach(Mode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                HomeBaseColorSelectionField(
                    mode: mode == .color ? .chromatic : .white,
                    selection: selection,
                    constituentSelections: constituentSelections,
                    selectionChanged: updateSelection,
                    selectionCommitted: commitSelection,
                    manipulationChanged: manipulationChanged
                )
                .frame(maxWidth: 460)
                .zIndex(1)

                Text(selectionSummary)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 22)

                if mode == .color {
                    htmlRGBEditor
                } else {
                    whiteKelvinEditor
                }

                if let updateError {
                    Label(updateError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ZStack {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(height: 30)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await monitorLiveValues()
        }
        .onChange(of: focusedField) { _, focusedField in
            if focusedField != nil {
                beginLocalInteraction()
            } else if !isManipulating {
                holdLiveUpdatesForUserInteraction()
            }
        }
        .onDisappear {
            interactiveWriteTask?.cancel()
            interactiveWriteTask = nil
            interactiveWriteGeneration = nil
            resumeLiveUpdatesTask?.cancel()
            resumeLiveUpdatesTask = nil
        }
    }

    private var htmlRGBEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("HTML RGB")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("#RRGGBB", text: $htmlRGBText)
                .font(.body.monospaced())
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .htmlRGB)
                .onSubmit(commitHTMLRGB)
                .onChange(of: htmlRGBText) {
                    htmlRGBError = nil
                }
#if os(iOS)
                .textInputAutocapitalization(.characters)
                .keyboardType(.asciiCapable)
                .submitLabel(.done)
#endif

            if let htmlRGBError {
                Text(htmlRGBError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: 460)
    }

    private var whiteKelvinEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Kelvin")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("2200–6500", text: $whiteKelvinText)
                .font(.body.monospacedDigit())
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .whiteKelvin)
                .onSubmit(commitWhiteKelvin)
                .onChange(of: whiteKelvinText) {
                    whiteKelvinError = nil
                }
#if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.numbersAndPunctuation)
                .submitLabel(.done)
#endif

            if let whiteKelvinError {
                Text(whiteKelvinError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: 460)
    }

    private var modeBinding: Binding<Mode> {
        Binding(
            get: { mode },
            set: { requestedMode in
                guard requestedMode != mode else { return }
                focusedField = nil
                mode = requestedMode
                holdLiveUpdatesForUserInteraction()
            }
        )
    }

    private var selection: CGPoint? {
        switch mode {
        case .color: chromaticSelection
        case .white: whiteSelection
        }
    }

    private var constituentSelections: [CGPoint] {
        switch mode {
        case .color: chromaticConstituentSelections
        case .white: whiteConstituentSelections
        }
    }

    private var selectionSummary: String {
        guard let selection else {
            if !constituentSelections.isEmpty {
                let representedCount = constituentSelections.count
                let totalCount = max(
                    aggregateValueCount ?? representedCount,
                    representedCount
                )
                if totalCount > representedCount {
                    return "Showing \(representedCount) of \(totalCount) values"
                }
                return "\(representedCount) current values · Drag to override all"
            }
            return "Touch or drag to choose"
        }
        switch mode {
        case .color:
            return "Selected color"
        case .white:
            let kelvin = HomeBaseColorPickerMapping.kelvin(at: selection)
            return "\(Int(kelvin.rounded())) K"
        }
    }

    private func updateSelection(_ selection: CGPoint) {
        updateError = nil
        if isManipulating {
            clearConstituentSelections()
        }
        switch mode {
        case .color:
            chromaticSelection = selection
            if let htmlRGB = HomeBaseColorPickerMapping.htmlRGB(
                at: selection
            ) {
                htmlRGBText = htmlRGB
                htmlRGBError = nil
            }
        case .white:
            whiteSelection = selection
            whiteKelvinText = Self.kelvinText(
                HomeBaseColorPickerMapping.kelvin(at: selection)
            )
            whiteKelvinError = nil
        }

        guard isManipulating, let value = wireValue(at: selection) else {
            return
        }
        scheduleInteractiveWrite(value)
    }

    private func commitSelection(_ selection: CGPoint) {
        clearConstituentSelections()
        updateSelection(selection)
        interactiveWriteTask?.cancel()
        interactiveWriteTask = nil
        interactiveWriteGeneration = nil
        pendingInteractiveWrite = nil
        guard let value = wireValue(at: selection) else { return }
        enqueue(value)
    }

    private func commitHTMLRGB() {
        guard let location = HomeBaseColorPickerMapping.chromaticLocation(
            htmlRGB: htmlRGBText
        ) else {
            htmlRGBError = "Enter #RRGGBB or #RGB; black has no color component."
            return
        }

        htmlRGBError = nil
        mode = .color
        commitSelection(location)
        focusedField = nil
        holdLiveUpdatesForUserInteraction()
    }

    private func commitWhiteKelvin() {
        let enteredText = whiteKelvinText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "Kk"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let kelvin = Double(enteredText),
              kelvin >= HomeBaseColorPickerMapping.warmestKelvin,
              kelvin <= HomeBaseColorPickerMapping.coldestKelvin else {
            whiteKelvinError = "Enter a value from 2200 to 6500 K."
            return
        }

        whiteKelvinError = nil
        mode = .white
        commitSelection(
            HomeBaseColorPickerMapping.whiteLocation(kelvin: kelvin)
        )
        focusedField = nil
        holdLiveUpdatesForUserInteraction()
    }

    private func wireValue(at selection: CGPoint) -> HBJSONValue? {
        switch mode {
        case .color:
            HomeBaseColorPickerMapping.chromaticWireValue(
                at: selection,
                supportsXY: capabilities.supportsXY,
                supportsRGB: capabilities.supportsRGB
            )
        case .white:
            HomeBaseColorPickerMapping.whiteWireValue(at: selection)
        }
    }

    private func scheduleInteractiveWrite(_ value: HBJSONValue) {
        pendingInteractiveWrite = value
        guard interactiveWriteTask == nil else { return }

        let generation = UUID()
        interactiveWriteGeneration = generation
        interactiveWriteTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
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

    private func enqueue(_ value: HBJSONValue) {
        pendingWrite = value
        updateError = nil
        guard !isSending else { return }
        isSending = true

        Task { @MainActor in
            while let nextValue = pendingWrite {
                pendingWrite = nil
                do {
                    try await setValue(nextValue)
                    updateError = nil
                } catch is CancellationError {
                    break
                } catch {
                    updateError = error.localizedDescription
                }
            }
            isSending = false
        }
    }

    private func manipulationChanged(_ isManipulating: Bool) {
        self.isManipulating = isManipulating
        if isManipulating {
            focusedField = nil
            beginLocalInteraction()
        } else if focusedField == nil {
            holdLiveUpdatesForUserInteraction()
        }
    }

    private func beginLocalInteraction() {
        resumeLiveUpdatesTask?.cancel()
        resumeLiveUpdatesTask = nil
        liveUpdateDeadline = nil
    }

    private func holdLiveUpdatesForUserInteraction() {
        let deadline = Date().addingTimeInterval(10)
        liveUpdateDeadline = deadline
        resumeLiveUpdatesTask?.cancel()
        resumeLiveUpdatesTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            guard !isManipulating,
                  focusedField == nil,
                  liveUpdateDeadline == deadline else {
                return
            }
            liveUpdateDeadline = nil
            resumeLiveUpdatesTask = nil
            if let deferredLiveObservation {
                self.deferredLiveObservation = nil
                applyLiveObservation(deferredLiveObservation)
            }
        }
    }

    private func monitorLiveValues() async {
        while !Task.isCancelled {
            do {
                for try await observation in liveValues() {
                    try Task.checkCancellation()
                    receiveLiveObservation(observation)
                }
            } catch is CancellationError {
                return
            } catch {
                // The surrounding app already presents connection state. A
                // picker quietly retries so it can resume tracking after the
                // shared session has been rebuilt.
            }

            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }

    private func receiveLiveObservation(
        _ observation: HomeBaseColorPickerObservation
    ) {
        if isManipulating
            || focusedField != nil
            || liveUpdateDeadline.map({ $0 > Date() }) == true {
            deferredLiveObservation = observation
            return
        }

        liveUpdateDeadline = nil
        deferredLiveObservation = nil
        applyLiveObservation(observation)
    }

    private func applyLiveObservation(
        _ observation: HomeBaseColorPickerObservation
    ) {
        if observation.aggregateState == .mixed {
            let selections = Self.constituentSelections(
                observation.aggregateValues
            )
            chromaticConstituentSelections = selections.chromatic
            whiteConstituentSelections = selections.white
            aggregateValueCount = observation.aggregateValueCount
            chromaticSelection = nil
            whiteSelection = nil
            htmlRGBText = ""
            htmlRGBError = nil
            whiteKelvinText = ""
            whiteKelvinError = nil
            mode = Self.initialMode(
                capabilities: capabilities,
                initialValue: nil,
                aggregateValues: observation.aggregateValues
            )
            return
        }

        clearConstituentSelections()
        guard let value = observation.value else { return }
        applyLiveValue(value)
    }

    private func applyLiveValue(_ value: HBJSONValue) {
        if capabilities.supportsWhite,
           let kelvin = HomeBaseColorPickerMapping.whiteKelvin(from: value) {
            whiteSelection = HomeBaseColorPickerMapping.whiteLocation(
                kelvin: kelvin
            )
            if focusedField != .whiteKelvin {
                whiteKelvinText = Self.kelvinText(kelvin)
                whiteKelvinError = nil
            }
            mode = .white
            return
        }

        if capabilities.supportsChromatic,
           let location = HomeBaseColorPickerMapping.chromaticLocation(
            for: value
           ) {
            chromaticSelection = location
            if focusedField != .htmlRGB,
               let htmlRGB = HomeBaseColorPickerMapping.htmlRGB(
                at: location
               ) {
                htmlRGBText = htmlRGB
                htmlRGBError = nil
            }
            mode = .color
        }
    }

    private static func initialMode(
        capabilities: HomeBaseColorPickerCapabilities,
        initialValue: HBJSONValue?,
        aggregateValues: [HBJSONValue]?
    ) -> Mode {
        if capabilities.supportsWhite,
           initialValue.flatMap({ value in
            HomeBaseColorPickerMapping.whiteKelvin(from: value)
           }) != nil {
            return .white
        }

        let aggregateModes = aggregateValues?.compactMap { value in
            value.objectValue?.keys.first?.lowercased()
        } ?? []
        if capabilities.supportsWhite,
           !aggregateModes.isEmpty,
           aggregateModes.allSatisfy({ $0 == "white" }) {
            return .white
        }
        return capabilities.supportsChromatic ? .color : .white
    }

    private static func constituentSelections(
        _ values: [HBJSONValue]?
    ) -> (chromatic: [CGPoint], white: [CGPoint]) {
        guard let values else { return ([], []) }
        var chromatic: [CGPoint] = []
        var white: [CGPoint] = []
        for value in values {
            if let location = HomeBaseColorPickerMapping.chromaticLocation(
                for: value
            ) {
                chromatic.append(location)
            } else if let kelvin = HomeBaseColorPickerMapping.whiteKelvin(
                from: value
            ) {
                white.append(
                    HomeBaseColorPickerMapping.whiteLocation(kelvin: kelvin)
                )
            }
        }
        return (chromatic, white)
    }

    private static func kelvinText(_ kelvin: Double) -> String {
        String(Int(kelvin.rounded()))
    }

    private func clearConstituentSelections() {
        chromaticConstituentSelections = []
        whiteConstituentSelections = []
        aggregateValueCount = nil
    }
}

private struct HomeBaseColorSelectionField: View {
    enum Mode {
        case chromatic
        case white
    }

    let mode: Mode
    let selection: CGPoint?
    let constituentSelections: [CGPoint]
    let selectionChanged: (CGPoint) -> Void
    let selectionCommitted: (CGPoint) -> Void
    let manipulationChanged: (Bool) -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(
                x: proxy.size.width / 2,
                y: proxy.size.height / 2
            )

            ZStack {
                palette
                    .frame(width: side, height: side)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(.primary.opacity(0.16), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.10), radius: 7, y: 3)
                    .position(center)

                ForEach(constituentSelections.indices, id: \.self) { index in
                    let constituent = constituentSelections[index]
                    HomeBaseColorSelectionMarker(
                        color: previewColor(at: constituent),
                        diameter: 20,
                        lineWidth: 2
                    )
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                    .position(
                        screenPoint(
                            for: constituent,
                            side: side,
                            center: center
                        )
                    )
                }

                if let selection {
                    let point = screenPoint(
                        for: selection,
                        side: side,
                        center: center
                    )
                    HomeBaseColorSelectionMarker(
                        color: previewColor(at: selection),
                        diameter: 30,
                        lineWidth: 3
                    )
                    .position(point)

                    if isDragging {
                        HomeBaseColorSelectionMarker(
                            color: previewColor(at: selection),
                            diameter: 50,
                            lineWidth: 4
                        )
                        .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
                        .position(
                            previewPoint(
                                for: point,
                                side: side,
                                center: center
                            )
                        )
                        .zIndex(10)
                    }
                }
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            manipulationChanged(true)
                        }
                        selectionChanged(
                            normalizedLocation(
                                for: value.location,
                                side: side,
                                center: center
                            )
                        )
                    }
                    .onEnded { value in
                        let location = normalizedLocation(
                            for: value.location,
                            side: side,
                            center: center
                        )
                        selectionChanged(location)
                        isDragging = false
                        manipulationChanged(false)
                        selectionCommitted(location)
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                mode == .chromatic ? "Color field" : "White temperature field"
            )
            .accessibilityHint("Touch or drag to choose a value")
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private var palette: some View {
        switch mode {
        case .chromatic:
            if let image = HomeBaseColorPickerMapping.chromaticImage {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.high)
            } else {
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                            center: .center
                        )
                    )
            }

        case .white:
            Circle()
                .fill(
                    LinearGradient(
                        stops: HomeBaseColorPickerMapping.whiteGradient
                            .enumerated()
                            .map { index, color in
                                .init(
                                    color: color.cgColor.map(Color.init(cgColor:))
                                        ?? .secondary,
                                    location: Double(index)
                                        / Double(
                                            HomeBaseColorPickerMapping
                                                .whiteGradient.count - 1
                                        )
                                )
                            },
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    private func previewColor(at selection: CGPoint) -> Color {
        let cgColor: CGColor?
        switch mode {
        case .chromatic:
            cgColor = HomeBaseColorPickerMapping
                .chromaticSample(at: selection)?.color
        case .white:
            cgColor = HomeBaseColorPickerMapping.whiteColor(at: selection)
        }
        return cgColor.map(Color.init(cgColor:)) ?? .secondary
    }

    private func normalizedLocation(
        for location: CGPoint,
        side: CGFloat,
        center: CGPoint
    ) -> CGPoint {
        guard side > 0 else { return .zero }
        return HomeBaseColorPickerMapping.clampedToCircle(
            CGPoint(
                x: (location.x - center.x) / (side / 2),
                y: (location.y - center.y) / (side / 2)
            )
        )
    }

    private func screenPoint(
        for normalizedLocation: CGPoint,
        side: CGFloat,
        center: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: center.x + (normalizedLocation.x * side / 2),
            y: center.y + (normalizedLocation.y * side / 2)
        )
    }

    private func previewPoint(
        for selectionPoint: CGPoint,
        side: CGFloat,
        center: CGPoint
    ) -> CGPoint {
        return CGPoint(
            x: min(
                center.x + (side / 2) - 27,
                max(center.x - (side / 2) + 27, selectionPoint.x)
            ),
            y: selectionPoint.y - 66
        )
    }
}

private struct HomeBaseColorSelectionMarker: View {
    let color: Color
    let diameter: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .overlay {
                Circle()
                    .strokeBorder(.white, lineWidth: lineWidth)
            }
            .overlay {
                Circle()
                    .strokeBorder(.black.opacity(0.22), lineWidth: 1)
            }
    }
}
