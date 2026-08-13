//
//  SceneControlPickerView.swift
//  HomeBase-GUI
//

import Foundation
import HomeBaseProtocol
import SwiftUI

protocol AutomationControlRepository: Sendable {
    func editableDeviceCatalog() async throws
        -> SceneConfigurationDeviceCatalog
}

extension SceneConfigurationRepository: AutomationControlRepository {}

enum SceneControlSetValueSource: Equatable, Sendable {
    case currentPresentation
    case explicit(HBJSONValue)
}

enum SceneControlPickerValueEntryMode: Equatable, Sendable {
    /// The published value is unambiguous and can be copied immediately.
    case currentPresentation
    /// The type module can ask the user for a value without a usable current
    /// presentation, as with a mixed aggregate color.
    case dedicatedEditor
    /// No registered type module can edit this schema yet.
    case rawJSON
}

struct SceneRawControlValueValidator {
    enum ValidationError: LocalizedError, Equatable {
        case empty
        case invalidJSON(String)
        case notWritable
        case expectedNumber(kind: String)
        case belowMinimum(Double)
        case aboveMaximum(Double)

        var errorDescription: String? {
            switch self {
            case .empty:
                "Enter one complete JSON value."
            case .invalidJSON(let message):
                "The value is not valid JSON: \(message)"
            case .notWritable:
                "This control is not writable."
            case .expectedNumber(let kind):
                "\(kind) requires a JSON number."
            case .belowMinimum(let minimum):
                "The value must be at least \(Self.numberText(minimum))."
            case .aboveMaximum(let maximum):
                "The value must be at most \(Self.numberText(maximum))."
            }
        }

        private static func numberText(_ value: Double) -> String {
            String(format: "%.17g", value)
        }
    }

    let schema: ControlValueSchema

    init(control: HBControlDescriptor) {
        schema = ControlValueSchema(
            kind: control.kind,
            metadata: control.metadata,
            tags: control.tags
        )
    }

    func parse(_ source: String) throws -> HBJSONValue {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }

        let value: HBJSONValue
        do {
            value = try JSONDecoder().decode(
                HBJSONValue.self,
                from: Data(trimmed.utf8)
            )
        } catch {
            throw ValidationError.invalidJSON(error.localizedDescription)
        }
        try validate(value)
        return value
    }

    func validate(_ value: HBJSONValue) throws {
        guard schema.isWritable else {
            throw ValidationError.notWritable
        }
        guard !schema.isStructured else { return }
        guard let number = value.numberValue else {
            throw ValidationError.expectedNumber(kind: schema.kind)
        }
        if let minimum = schema.metadata["minimum"]?.numberValue,
           number < minimum {
            throw ValidationError.belowMinimum(minimum)
        }
        if let maximum = schema.metadata["maximum"]?.numberValue,
           number > maximum {
            throw ValidationError.aboveMaximum(maximum)
        }
    }
}

struct SceneResolvedControl: Equatable, Sendable {
    let path: String
    let descriptor: HBControlDescriptor

    init(path: String, descriptor: HBControlDescriptor) {
        self.path = path
        self.descriptor = descriptor
    }

    init(device: HBDeviceDescriptor, descriptor: HBControlDescriptor) {
        self.init(
            path: "\(device.addressableName):\(descriptor.identifier)",
            descriptor: descriptor
        )
    }

    var schema: ControlValueSchema {
        descriptor.controlValueSchema
    }

    func presentationContext(
        value: HBJSONValue,
        isEnabled: Bool,
        isUpdating: Bool = false,
        commit: @escaping (
            HBJSONValue,
            ControlValueCommitOrigin
        ) async throws -> Void
    ) -> ControlValuePresentationContext {
        presentationContext(
            snapshot: draftSnapshot(value: value),
            isEnabled: isEnabled,
            isUpdating: isUpdating,
            commit: commit
        )
    }

    func listedPresentationContext(
        isEnabled: Bool,
        isUpdating: Bool = false,
        commit: @escaping (
            HBJSONValue,
            ControlValueCommitOrigin
        ) async throws -> Void
    ) -> ControlValuePresentationContext {
        presentationContext(
            snapshot: descriptor.listedControlValueSnapshot,
            isEnabled: isEnabled,
            isUpdating: isUpdating,
            commit: commit
        )
    }

    @MainActor
    var valueEntryMode: SceneControlPickerValueEntryMode {
        let context = listedPresentationContext(
            isEnabled: false,
            commit: { _, _ in }
        )
        let plugin = ControlValueTypeRegistry.standard
            .resolve(schema)
            .plugin
        let snapshot = context.snapshot
        let hasUnambiguousCurrentValue = !snapshot.isStale
            && snapshot.aggregateState != .mixed
            && snapshot.aggregateState != .unavailable
            && snapshot.value != nil
            && snapshot.value != .null

        if hasUnambiguousCurrentValue,
           plugin.supportsEditing(context: context) {
            return .currentPresentation
        }
        if plugin.supportsStandaloneEditing(context: context) {
            return .dedicatedEditor
        }
        return .rawJSON
    }

    private func presentationContext(
        snapshot: ControlValueSnapshot,
        isEnabled: Bool,
        isUpdating: Bool = false,
        commit: @escaping (
            HBJSONValue,
            ControlValueCommitOrigin
        ) async throws -> Void
    ) -> ControlValuePresentationContext {
        ControlValuePresentationContext(
            schema: schema,
            snapshot: snapshot,
            interaction: ControlValueInteraction(
                isEnabled: isEnabled,
                isUpdating: isUpdating,
                commit: commit,
                observations: {
                    AsyncThrowingStream { continuation in
                        continuation.finish()
                    }
                }
            ),
            accessibilityLabel: descriptor.name,
            controlPath: path
        )
    }

    func supportsEditing(value: HBJSONValue) -> Bool {
        let context = presentationContext(
            value: value,
            isEnabled: false,
            commit: { _, _ in }
        )
        return ControlValueTypeRegistry.standard
            .resolve(schema)
            .plugin
            .supportsEditing(context: context)
    }

    private func draftSnapshot(value: HBJSONValue) -> ControlValueSnapshot {
        let suffix = descriptor.metadata["unitSuffix"]?.stringValue ?? ""
        return ControlValueSnapshot(
            value: value,
            displayText: value.presentationText + suffix
        )
    }
}

@MainActor
struct SceneControlPickerCatalog {
    struct Device: Identifiable {
        let descriptor: HBDeviceDescriptor
        let supportedControls: [HBControlDescriptor]
        let otherWritableControls: [HBControlDescriptor]

        var id: String {
            descriptor.identifier + "\u{0}" + descriptor.addressableName
        }
    }

    let sourceTopology: HBTopologyListResult
    let topology: HBTopologyListResult
    let devices: [Device]

    private let devicesByIdentifier: [String: Device]
    private let devicesByAddressableName: [String: Device]

    init(
        source: SceneConfigurationDeviceCatalog,
        excludedControlPaths: Set<String>
    ) {
        sourceTopology = source.topology
        let excluded = Set(
            excludedControlPaths.map(Self.normalizedIdentifier)
        )
        let editableDevices = source.devices.compactMap { device -> Device? in
            let writableControls = device.controls.filter { descriptor in
                let resolved = SceneResolvedControl(
                    device: device,
                    descriptor: descriptor
                )
                return !excluded.contains(
                    Self.normalizedIdentifier(resolved.path)
                ) && resolved.schema.isWritable
            }.sorted(by: Self.controlSort)

            let supportedControls = writableControls.filter { descriptor in
                SceneResolvedControl(
                    device: device,
                    descriptor: descriptor
                ).valueEntryMode != .rawJSON
            }
            let supportedIdentifiers = Set(
                supportedControls.map(\.identifier)
            )
            let otherWritableControls = writableControls.filter {
                !supportedIdentifiers.contains($0.identifier)
            }

            guard !writableControls.isEmpty else { return nil }
            return Device(
                descriptor: device,
                supportedControls: supportedControls,
                otherWritableControls: otherWritableControls
            )
        }.sorted(by: Self.deviceSort)
        devices = editableDevices

        var devicesByIdentifier: [String: Device] = [:]
        var devicesByAddressableName: [String: Device] = [:]
        for device in editableDevices {
            devicesByIdentifier[
                Self.normalizedIdentifier(device.descriptor.identifier),
                default: device
            ] = device
            devicesByAddressableName[
                Self.normalizedIdentifier(
                    device.descriptor.addressableName
                ),
                default: device
            ] = device
        }
        self.devicesByIdentifier = devicesByIdentifier
        self.devicesByAddressableName = devicesByAddressableName

        topology = Self.addingMissingTopologyDevices(
            to: source.topology,
            from: editableDevices
        ).includingOtherRoom
    }

    var rooms: [HBTopologyRoomDescriptor] {
        topology.rooms.filter { room in
            !devices(in: room).isEmpty || !groups(in: room).isEmpty
        }
    }

    var topLevelGroups: [HBTopologyGroupDescriptor] {
        TopologyGroupPlacement(topology: topology).topLevelGroups.filter(
            isSelectable
        )
    }

    var isEmpty: Bool {
        rooms.isEmpty && topLevelGroups.isEmpty
    }

    func groups(
        in room: HBTopologyRoomDescriptor
    ) -> [HBTopologyGroupDescriptor] {
        TopologyGroupPlacement(topology: topology).groups(in: room).filter(
            isSelectable
        )
    }

    func devices(in room: HBTopologyRoomDescriptor) -> [Device] {
        devices(withIdentifiers: room.resolvedDeviceIdentifiers)
    }

    func devices(in group: HBTopologyGroupDescriptor) -> [Device] {
        devices(withIdentifiers: group.resolvedDeviceIdentifiers)
    }

    func controlDevice(for group: HBTopologyGroupDescriptor) -> Device? {
        device(matching: group.controlDeviceIdentifier)
    }

    func technicalName(for room: HBTopologyRoomDescriptor) -> String? {
        sourceTopology.containsRoom(identifier: room.identifier)
            ? room.identifier
            : nil
    }

    private func isSelectable(_ group: HBTopologyGroupDescriptor) -> Bool {
        controlDevice(for: group) != nil || !devices(in: group).isEmpty
    }

    private func devices(withIdentifiers identifiers: [String]) -> [Device] {
        var seen: Set<String> = []
        return identifiers.compactMap { identifier in
            guard let device = device(matching: identifier),
                  seen.insert(device.id).inserted else {
                return nil
            }
            return device
        }.sorted(by: Self.deviceSort)
    }

    private func device(matching identifier: String) -> Device? {
        let normalized = Self.normalizedIdentifier(identifier)
        return devicesByIdentifier[normalized]
            ?? devicesByAddressableName[normalized]
    }

    private static func addingMissingTopologyDevices(
        to topology: HBTopologyListResult,
        from devices: [Device]
    ) -> HBTopologyListResult {
        let topologyDeviceNames = Set(
            topology.devices.flatMap {
                [
                    normalizedIdentifier($0.identifier),
                    normalizedIdentifier($0.addressableName),
                ]
            }
        )
        let groupControlNames = Set(
            topology.groups.map {
                normalizedIdentifier($0.controlDeviceIdentifier)
            }
        )

        var augmented = topology
        for device in devices {
            let identifier = normalizedIdentifier(device.descriptor.identifier)
            let addressableName = normalizedIdentifier(
                device.descriptor.addressableName
            )
            guard !topologyDeviceNames.contains(identifier),
                  !topologyDeviceNames.contains(addressableName),
                  !groupControlNames.contains(identifier),
                  !groupControlNames.contains(addressableName) else {
                continue
            }
            augmented.devices.append(
                HBTopologyDeviceDescriptor(
                    identifier: device.descriptor.identifier,
                    addressableName: device.descriptor.addressableName,
                    displayName: device.descriptor.displayName
                )
            )
        }
        return augmented
    }

    private static func controlSort(
        _ left: HBControlDescriptor,
        _ right: HBControlDescriptor
    ) -> Bool {
        let leftDerived = left.metadata["derived"]?.boolValue == true
        let rightDerived = right.metadata["derived"]?.boolValue == true
        if leftDerived != rightDerived {
            return !leftDerived
        }
        let nameOrder = left.name.localizedCaseInsensitiveCompare(right.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return left.identifier.localizedCaseInsensitiveCompare(
            right.identifier
        ) == .orderedAscending
    }

    private static func deviceSort(_ left: Device, _ right: Device) -> Bool {
        let displayOrder = left.descriptor.displayName
            .localizedCaseInsensitiveCompare(right.descriptor.displayName)
        if displayOrder != .orderedSame {
            return displayOrder == .orderedAscending
        }
        return left.descriptor.addressableName.localizedCaseInsensitiveCompare(
            right.descriptor.addressableName
        ) == .orderedAscending
    }

    private static func normalizedIdentifier(_ identifier: String) -> String {
        identifier.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

private typealias SceneControlPickerChoose = @MainActor @Sendable (
    String,
    HBControlDescriptor,
    SceneControlSetValueSource
) -> Void

private typealias SceneControlPickerChooseRawValue = @MainActor @Sendable (
    String,
    HBControlDescriptor,
    HBJSONValue
) async throws -> Void

private struct SceneControlPickerSelection: Sendable {
    let deviceAddressableName: String
    let control: HBControlDescriptor
    let valueSource: SceneControlSetValueSource
}

@MainActor
struct SceneControlPickerView<Repository: AutomationControlRepository>: View {
    private struct PresentedError: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Environment(\.dismiss) private var dismiss

    let repository: Repository
    let configurationKind: String
    let excludedControlPaths: Set<String>
    let onSelect:
        @MainActor @Sendable (
            String,
            HBControlDescriptor,
            SceneControlSetValueSource
        ) async throws -> Void

    init(
        repository: Repository,
        excludedControlPaths: Set<String>,
        configurationKind: String = "scene",
        onSelect: @escaping @MainActor @Sendable (
            String,
            HBControlDescriptor,
            SceneControlSetValueSource
        ) async throws -> Void
    ) {
        self.repository = repository
        self.excludedControlPaths = excludedControlPaths
        self.configurationKind = configurationKind
        self.onSelect = onSelect
    }

    @State private var catalog: SceneControlPickerCatalog?
    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var loadingError: String?
    @State private var submittingPath: String?
    @State private var presentedError: PresentedError?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add Control")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Label("Cancel", systemImage: "xmark")
                                .labelStyle(.iconOnly)
                        }
                        .disabled(submittingPath != nil)
                    }
                }
        }
        .interactiveDismissDisabled(submittingPath != nil)
        .task {
            await loadIfNeeded()
        }
        .alert(item: $presentedError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
#if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
#endif
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading devices…")
                .foregroundStyle(.secondary)
        } else if let loadingError {
            ContentUnavailableView {
                Label(
                    "Controls Could Not Be Loaded",
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(loadingError)
            } actions: {
                Button("Try Again") {
                    Task {
                        await load()
                    }
                }
            }
        } else if hasLoaded, catalog?.isEmpty != false {
            ContentUnavailableView {
                Label("No Controls to Add", systemImage: "slider.horizontal.3")
            } description: {
                Text(
                    "Every writable control is already in the \(configurationKind), or no writable controls are available."
                )
            }
        } else if let catalog {
            SceneControlPickerTopologyList(
                catalog: catalog,
                submittingPath: submittingPath,
                choose: choose,
                chooseRawValue: chooseRawValue
            )
        }
    }

    private func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        loadingError = nil
        defer { isLoading = false }

        do {
            let source = try await repository.editableDeviceCatalog()
            try Task.checkCancellation()
            catalog = SceneControlPickerCatalog(
                source: source,
                excludedControlPaths: excludedControlPaths
            )
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch {
            loadingError = error.localizedDescription
        }
    }

    private func choose(
        deviceAddressableName: String,
        control: HBControlDescriptor,
        valueSource: SceneControlSetValueSource
    ) {
        let selection = SceneControlPickerSelection(
            deviceAddressableName: deviceAddressableName,
            control: control,
            valueSource: valueSource
        )

        Task { @MainActor [selection] in
            do {
                try await submit(selection: selection)
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                presentedError = PresentedError(
                    title: "Control Could Not Be Added",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func chooseRawValue(
        deviceAddressableName: String,
        control: HBControlDescriptor,
        value: HBJSONValue
    ) async throws {
        try await submit(
            deviceAddressableName: deviceAddressableName,
            control: control,
            valueSource: .explicit(value)
        )
        dismiss()
    }

    private func submit(
        selection: SceneControlPickerSelection
    ) async throws {
        try await submit(
            deviceAddressableName: selection.deviceAddressableName,
            control: selection.control,
            valueSource: selection.valueSource
        )
        withExtendedLifetime(selection) {}
    }

    private func submit(
        deviceAddressableName: String,
        control: HBControlDescriptor,
        valueSource: SceneControlSetValueSource
    ) async throws {
        let path = "\(deviceAddressableName):\(control.identifier)"
        guard submittingPath == nil else { throw CancellationError() }
        submittingPath = path
        defer { submittingPath = nil }
        try await onSelect(deviceAddressableName, control, valueSource)
    }
}

private struct SceneControlPickerTopologyList: View {
    let catalog: SceneControlPickerCatalog
    let submittingPath: String?
    let choose: SceneControlPickerChoose
    let chooseRawValue: SceneControlPickerChooseRawValue

    var body: some View {
        List {
            Section("Rooms") {
                ForEach(catalog.rooms, id: \.identifier) { room in
                    NavigationLink {
                        SceneControlPickerRoomView(
                            room: room,
                            catalog: catalog,
                            submittingPath: submittingPath,
                            choose: choose,
                            chooseRawValue: chooseRawValue
                        )
                    } label: {
                        TopologyRowLabel(
                            title: room.displayName,
                            technicalName: catalog.technicalName(for: room),
                            detail: TopologyRowLabel.deviceCountDescription(
                                room.resolvedDeviceIdentifiers.count
                            )
                        )
                    }
                }
            }

            if !catalog.topLevelGroups.isEmpty {
                Section("Groups") {
                    ForEach(
                        catalog.topLevelGroups,
                        id: \.identifier
                    ) { group in
                        NavigationLink {
                            SceneControlPickerGroupView(
                                group: group,
                                catalog: catalog,
                                submittingPath: submittingPath,
                                choose: choose,
                                chooseRawValue: chooseRawValue
                            )
                        } label: {
                            TopologyGroupRow(group: group)
                        }
                    }
                }
            }
        }
    }
}

private struct SceneControlPickerRoomView: View {
    let room: HBTopologyRoomDescriptor
    let catalog: SceneControlPickerCatalog
    let submittingPath: String?
    let choose: SceneControlPickerChoose
    let chooseRawValue: SceneControlPickerChooseRawValue

    private var devices: [SceneControlPickerCatalog.Device] {
        catalog.devices(in: room)
    }

    private var groups: [HBTopologyGroupDescriptor] {
        catalog.groups(in: room)
    }

    var body: some View {
        List {
            Section("Devices") {
                SceneControlPickerDeviceRows(
                    devices: devices,
                    emptyMessage:
                        "No devices with writable controls are available in this room.",
                    submittingPath: submittingPath,
                    choose: choose,
                    chooseRawValue: chooseRawValue
                )
            }

            if !groups.isEmpty {
                Section("Groups") {
                    ForEach(groups, id: \.identifier) { group in
                        NavigationLink {
                            SceneControlPickerGroupView(
                                group: group,
                                catalog: catalog,
                                submittingPath: submittingPath,
                                choose: choose,
                                chooseRawValue: chooseRawValue
                            )
                        } label: {
                            TopologyGroupRow(group: group)
                        }
                    }
                }
            }
        }
        .navigationTitle(room.displayName)
    }
}

private struct SceneControlPickerGroupView: View {
    let group: HBTopologyGroupDescriptor
    let catalog: SceneControlPickerCatalog
    let submittingPath: String?
    let choose: SceneControlPickerChoose
    let chooseRawValue: SceneControlPickerChooseRawValue

    var body: some View {
        List {
            if let controlDevice = catalog.controlDevice(for: group) {
                SceneControlPickerControlSections(
                    deviceAddressableName:
                        controlDevice.descriptor.addressableName,
                    supportedControls: controlDevice.supportedControls,
                    otherWritableControls:
                        controlDevice.otherWritableControls,
                    submittingPath: submittingPath,
                    choose: choose,
                    chooseRawValue: chooseRawValue
                )
            }

            Section("Devices") {
                SceneControlPickerDeviceRows(
                    devices: catalog.devices(in: group),
                    emptyMessage:
                        "No member devices with writable controls are available in this group.",
                    submittingPath: submittingPath,
                    choose: choose,
                    chooseRawValue: chooseRawValue
                )
            }
        }
        .navigationTitle(group.displayName)
    }
}

private struct SceneControlPickerDeviceRows: View {
    let devices: [SceneControlPickerCatalog.Device]
    let emptyMessage: String
    let submittingPath: String?
    let choose: SceneControlPickerChoose
    let chooseRawValue: SceneControlPickerChooseRawValue

    var body: some View {
        if devices.isEmpty {
            Text(emptyMessage)
                .foregroundStyle(.secondary)
        } else {
            ForEach(devices) { device in
                NavigationLink {
                    SceneControlPickerControlList(
                        device: device.descriptor,
                        supportedControls: device.supportedControls,
                        otherWritableControls:
                            device.otherWritableControls,
                        submittingPath: submittingPath,
                        choose: choose,
                        chooseRawValue: chooseRawValue
                    )
                } label: {
                    TopologyRowLabel(
                        title: device.descriptor.displayName,
                        technicalName: device.descriptor.addressableName,
                        detail: device.supportedControls.isEmpty
                            ? "Raw JSON controls available"
                            : nil
                    )
                }
            }
        }
    }
}

private struct SceneControlPickerControlList: View {
    let device: HBDeviceDescriptor
    let supportedControls: [HBControlDescriptor]
    let otherWritableControls: [HBControlDescriptor]
    let submittingPath: String?
    let choose: SceneControlPickerChoose
    let chooseRawValue: SceneControlPickerChooseRawValue

    var body: some View {
        List {
            SceneControlPickerControlSections(
                deviceAddressableName: device.addressableName,
                supportedControls: supportedControls,
                otherWritableControls: otherWritableControls,
                submittingPath: submittingPath,
                choose: choose,
                chooseRawValue: chooseRawValue
            )
        }
        .navigationTitle(device.displayName)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}

private struct SceneControlPickerControlSections: View {
    let deviceAddressableName: String
    let supportedControls: [HBControlDescriptor]
    let otherWritableControls: [HBControlDescriptor]
    let submittingPath: String?
    let choose: SceneControlPickerChoose
    let chooseRawValue: SceneControlPickerChooseRawValue

    @State private var showsAllWritableControls = false

    var body: some View {
        Group {
            if supportedControls.isEmpty {
                Section {
                    Text(
                        "This device has no remaining controls with a dedicated editor."
                    )
                    .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(supportedControls, id: \.identifier) { control in
                        supportedControlRow(control)
                    }
                } header: {
                    Text("Controls")
                }
            }

            if !otherWritableControls.isEmpty {
                if showsAllWritableControls {
                    Section {
                        ForEach(
                            otherWritableControls,
                            id: \.identifier
                        ) { control in
                            NavigationLink {
                                SceneRawControlValueEditor(
                                    control: control,
                                    initialValue: control.value,
                                    actionLabel: "Add"
                                ) { value in
                                    try await chooseRawValue(
                                        deviceAddressableName,
                                        control,
                                        value
                                    )
                                }
                            } label: {
                                controlLabel(control, showsSchema: true)
                            }
                            .disabled(submittingPath != nil)
                        }
                    } header: {
                        Text("Other Writable Controls")
                    } footer: {
                        Text(
                            "These controls use raw JSON because the app does not have a dedicated editor for their schemas yet."
                        )
                    }
                }

                Section {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showsAllWritableControls.toggle()
                        }
                    } label: {
                        Label(
                            showsAllWritableControls
                                ? "Show Standard Controls Only"
                                : "Show All Writable Controls",
                            systemImage: showsAllWritableControls
                                ? "eye.slash"
                                : "eye"
                        )
                    }
                }
            }
        }
    }

    private func controlPath(_ control: HBControlDescriptor) -> String {
        "\(deviceAddressableName):\(control.identifier)"
    }

    @ViewBuilder
    private func supportedControlRow(
        _ control: HBControlDescriptor
    ) -> some View {
        let target = SceneResolvedControl(
            path: controlPath(control),
            descriptor: control
        )

        switch target.valueEntryMode {
        case .currentPresentation:
            Button {
                choose(
                    deviceAddressableName,
                    control,
                    .currentPresentation
                )
            } label: {
                controlLabel(control, showsSchema: false)
            }
            .buttonStyle(.plain)
            .disabled(submittingPath != nil)

        case .dedicatedEditor:
            NavigationLink {
                SceneControlValueCreationEditor(
                    target: target,
                    actionLabel: "Add"
                ) { value in
                    try await chooseRawValue(
                        deviceAddressableName,
                        control,
                        value
                    )
                }
            } label: {
                controlLabel(control, showsSchema: false)
            }
            .disabled(submittingPath != nil)

        case .rawJSON:
            NavigationLink {
                SceneRawControlValueEditor(
                    control: control,
                    initialValue: control.value,
                    actionLabel: "Add"
                ) { value in
                    try await chooseRawValue(
                        deviceAddressableName,
                        control,
                        value
                    )
                }
            } label: {
                controlLabel(control, showsSchema: true)
            }
            .disabled(submittingPath != nil)
        }
    }

    private func controlLabel(
        _ control: HBControlDescriptor,
        showsSchema: Bool
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(control.name)
                    .foregroundStyle(.primary)
                Text(
                    showsSchema
                        ? "\(control.identifier) · \(control.kind)"
                        : control.identifier
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if submittingPath == controlPath(control) {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .contentShape(Rectangle())
    }
}

@MainActor
private struct SceneControlValueCreationEditor: View {
    @Environment(\.dismiss) private var dismiss

    let target: SceneResolvedControl
    let actionLabel: String
    let onCommit: @MainActor @Sendable (HBJSONValue) async throws -> Void

    @State private var selectedValue: HBJSONValue?
    @State private var isSubmitting = false
    @State private var submissionError: String?

    var body: some View {
        Group {
            if let editor = plugin.makeStandaloneEditor(context: context) {
                editor
            } else {
                ContentUnavailableView(
                    "Editor Unavailable",
                    systemImage: "slider.horizontal.3"
                )
            }
        }
        .navigationTitle(target.descriptor.name)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .disabled(isSubmitting)
            }

            ToolbarItem(placement: .primaryAction) {
                if isSubmitting {
                    ProgressView()
                        .accessibilityLabel("Adding control")
                } else {
                    Button {
                        submit()
                    } label: {
                        Label(actionLabel, systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(selectedValue == nil)
                }
            }
        }
        .alert(
            "Control Could Not Be Added",
            isPresented: Binding(
                get: { submissionError != nil },
                set: { isPresented in
                    if !isPresented { submissionError = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(submissionError ?? "")
        }
    }

    private var plugin: AnyControlValueTypePlugin {
        ControlValueTypeRegistry.standard.resolve(target.schema).plugin
    }

    private var context: ControlValuePresentationContext {
        if let selectedValue {
            return target.presentationContext(
                value: selectedValue,
                isEnabled: !isSubmitting,
                commit: select
            )
        }
        return target.listedPresentationContext(
            isEnabled: !isSubmitting,
            commit: select
        )
    }

    private func select(
        _ value: HBJSONValue,
        _ origin: ControlValueCommitOrigin
    ) async throws {
        guard !isSubmitting else { throw CancellationError() }
        selectedValue = value
        submissionError = nil
    }

    private func submit() {
        guard !isSubmitting, let selectedValue else { return }
        isSubmitting = true
        submissionError = nil

        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                try await onCommit(selectedValue)
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                submissionError = error.localizedDescription
            }
        }
    }
}

struct SceneRawControlValueEditor: View {
    @Environment(\.dismiss) private var dismiss

    let control: HBControlDescriptor
    let actionLabel: String
    let onCommit: (HBJSONValue) async throws -> Void

    @State private var source: String
    @State private var isSubmitting = false
    @State private var submissionError: String?
    @FocusState private var valueIsFocused: Bool

    init(
        control: HBControlDescriptor,
        initialValue: HBJSONValue?,
        actionLabel: String,
        onCommit: @escaping (HBJSONValue) async throws -> Void
    ) {
        self.control = control
        self.actionLabel = actionLabel
        self.onCommit = onCommit
        _source = State(
            initialValue: initialValue?.prettyConfigurationJSON ?? ""
        )
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $source)
                    .font(.body.monospaced())
                    .frame(minHeight: 150)
                    .focused($valueIsFocused)
                    .autocorrectionDisabled()
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif

                if let validationMessage {
                    Label(
                        validationMessage,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                }

                if let submissionError {
                    Label(
                        submissionError,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            } header: {
                Text("JSON Value")
            }

            Section {
                LabeledContent("Schema", value: control.kind)
                LabeledContent("Validation", value: validationSummary)
                Text(validationExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(control.name)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .disabled(isSubmitting)
            }

            ToolbarItem(placement: .primaryAction) {
                if isSubmitting {
                    ProgressView()
                        .accessibilityLabel("Adding control")
                } else {
                    Button {
                        submit()
                    } label: {
                        Label(actionLabel, systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(parsedValue == nil)
                }
            }
        }
        .onChange(of: source) {
            submissionError = nil
        }
        .task {
            if source.isEmpty {
                valueIsFocused = true
            }
        }
    }

    private var validator: SceneRawControlValueValidator {
        SceneRawControlValueValidator(control: control)
    }

    private var parsedValue: HBJSONValue? {
        try? validator.parse(source)
    }

    private var validationMessage: String? {
        do {
            _ = try validator.parse(source)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var validationSummary: String {
        validator.schema.isStructured
            ? "JSON syntax"
            : scalarValidationSummary
    }

    private var scalarValidationSummary: String {
        guard let minimum = validator.schema.metadata["minimum"]?.numberValue,
              let maximum = validator.schema.metadata["maximum"]?.numberValue else {
            return "JSON number"
        }
        return "Number from \(numberText(minimum)) to \(numberText(maximum))"
    }

    private var validationExplanation: String {
        if validator.schema.isStructured {
            return "The app can validate JSON syntax and writability. HomeBase will validate the structured value against \(control.kind) when the scene reloads."
        }
        return "The app validates that this is a writable numeric value within the control's published bounds."
    }

    private func numberText(_ value: Double) -> String {
        String(format: "%.17g", value)
    }

    private func submit() {
        guard !isSubmitting, let value = parsedValue else { return }
        isSubmitting = true
        submissionError = nil

        Task {
            defer { isSubmitting = false }
            do {
                try await onCommit(value)
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                submissionError = error.localizedDescription
            }
        }
    }
}
