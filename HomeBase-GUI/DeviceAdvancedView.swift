//
//  DeviceAdvancedView.swift
//  HomeBase-GUI
//

import Combine
import Foundation
import HomeBaseProtocol
import SwiftUI

struct DeviceAdvancedView: View {
    @Environment(\.scenePhase) private var scenePhase

    private let device: HBTopologyDeviceDescriptor
    private let title: String
    private let client: HomeBaseWebSocketClient
    @StateObject private var model: DeviceAdvancedModel

    init(
        device: HBTopologyDeviceDescriptor,
        client: HomeBaseWebSocketClient
    ) {
        self.device = device
        title = device.addressableName
        self.client = client
        _model = StateObject(
            wrappedValue: DeviceAdvancedModel(
                device: device,
                client: client
            )
        )
    }

    var body: some View {
        List {
            AdvancedDeviceInformationSection(
                device: device,
                details: model.deviceDetails
            )

            AdvancedControlsSection(
                controls: model.controls,
                emptyMessage: emptyMessage,
                client: client,
                overrideClearingEnabled: model.state == .live,
                clearExternalOverride: { control in
                    try await model.clearExternalOverride(
                        for: control.id
                    )
                }
            )
        }
        .navigationTitle(title)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .refreshable {
            await model.restart()
        }
        .connectionStatusOverlay(model.state.connectionStatusPresentation) {
            Task {
                await model.run()
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active {
                await model.run(reactivating: true)
            } else {
                await model.stop()
            }
        }
        .onDisappear {
            Task {
                await model.stop()
            }
        }
    }

    private var emptyMessage: String {
        switch model.state {
        case .idle, .loading:
            "Control details will appear after loading."
        case .live:
            "This device has no controls."
        case .failed:
            "Control details could not be loaded."
        }
    }
}

private struct AdvancedControlsSection: View {
    let controls: [DeviceAdvancedControl]
    let emptyMessage: String
    let client: HomeBaseWebSocketClient
    let overrideClearingEnabled: Bool
    let clearExternalOverride: (DeviceAdvancedControl) async throws -> Void

    var body: some View {
        Section {
            if controls.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controls) { control in
                    DisclosureGroup {
                        if let externalOverride = control.stack?.externalOverride {
                            AdvancedExternalOverrideRow(
                                override: externalOverride,
                                canClear: overrideClearingEnabled
                                    && control.activeHold != nil,
                                clear: {
                                    try await clearExternalOverride(control)
                                }
                            )
                        }

                        ForEach(control.holds, id: \.identifier) { hold in
                            AdvancedRawValueRow(
                                title: "Priority \(hold.priority)",
                                value: hold.value,
                                details: control.holdDetails(hold),
                                prominence:
                                    control.stack?.externalOverride == nil
                                        && hold.active
                                        ? .active
                                        : .inactive
                            )
                        }

                        AdvancedRawValueRow(
                            title: nil,
                            value: control.observedValue,
                            displayValue: control.observedDisplayValue,
                            details: control.observedDetails,
                            prominence: .observed
                        )

                        NavigationLink {
                            ControlHistoryView(
                                control: control.controlPath,
                                displayName: control.descriptor.name,
                                client: client
                            )
                        } label: {
                            Label(
                                "History",
                                systemImage: "clock.arrow.circlepath"
                            )
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(control.descriptor.name)
                            Text(control.descriptor.identifier)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Controls")
                .textCase(nil)
                .font(.headline)
                .foregroundStyle(.primary)
        }
    }
}

private struct AdvancedDeviceInformationSection: View {
    let device: HBTopologyDeviceDescriptor
    let details: HBDeviceDescriptor?

    var body: some View {
        Section {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(row.value)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Device")
                .textCase(nil)
                .font(.headline)
                .foregroundStyle(.primary)
        }
    }

    private var rows: [AdvancedDeviceInformationRow] {
        var identityRows = [
            AdvancedDeviceInformationRow(
                id: "display-name",
                label: "Display name",
                value: details?.displayName ?? device.displayName
            ),
            AdvancedDeviceInformationRow(
                id: "addressable-name",
                label: "Addressable name",
                value: details?.addressableName ?? device.addressableName
            ),
            AdvancedDeviceInformationRow(
                id: "absolute-name",
                label: "Absolute name",
                value: details?.identifier ?? device.identifier
            ),
        ]
        var metadataRows: [AdvancedDeviceInformationRow] = []

        if let details {
            identityRows.append(
                AdvancedDeviceInformationRow(
                    id: "module",
                    label: "Module",
                    value: details.moduleName
                )
            )
            if let moduleInstanceIdentifier = details.moduleInstanceIdentifier,
               !moduleInstanceIdentifier.isEmpty {
                identityRows.append(
                    AdvancedDeviceInformationRow(
                        id: "module-instance",
                        label: "Module instance",
                        value: moduleInstanceIdentifier
                    )
                )
            }
            metadataRows.append(
                contentsOf: details.metadata.keys.sorted().compactMap { key in
                    guard let value = details.metadata[key] else { return nil }
                    return AdvancedDeviceInformationRow(
                        id: "metadata-\(key)",
                        label: "metadata.\(key)",
                        value: value.rawJSONString
                    )
                }
            )
        }

        return identityRows.sorted(by: Self.rowComesBefore)
            + metadataRows.sorted(by: Self.rowComesBefore)
    }

    nonisolated private static func rowComesBefore(
        _ left: AdvancedDeviceInformationRow,
        _ right: AdvancedDeviceInformationRow
    ) -> Bool {
        let order = left.label.localizedCaseInsensitiveCompare(right.label)
        if order != .orderedSame {
            return order == .orderedAscending
        }
        return left.id < right.id
    }
}

private struct AdvancedDeviceInformationRow: Identifiable {
    let id: String
    let label: String
    let value: String
}

private struct AdvancedExternalOverrideRow: View {
    let override: HBExternalControlOverrideDescriptor
    let canClear: Bool
    let clear: () async throws -> Void

    @State private var isClearing = false
    @State private var clearError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("External override")
                        .font(.subheadline)

                    Text(override.observedValue.rawJSONString)
                        .font(.body.monospaced())
                        .textSelection(.enabled)

                    Text(
                        "return: "
                            + override.capturedReturnValue.rawJSONString
                    )
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task {
                        isClearing = true
                        clearError = nil
                        do {
                            try await clear()
                        } catch {
                            clearError = error.localizedDescription
                        }
                        isClearing = false
                    }
                } label: {
                    if isClearing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "xmark.circle")
                            .font(.title2)
                            .frame(width: 28, height: 28)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canClear || isClearing)
                .accessibilityLabel("Clear external override")
            }

            if let clearError {
                Label(clearError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AdvancedRawValueRow: View {
    enum Prominence: Equatable {
        case active
        case inactive
        case observed
    }

    let title: String?
    let value: HBJSONValue
    var displayValue: String? = nil
    let details: [String]
    let prominence: Prominence

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title {
                Text(title)
                    .font(.subheadline)
            }

            Text(value.rawJSONString)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let presentedDisplayValue {
                Text(presentedDisplayValue)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            ForEach(details, id: \.self) { detail in
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        .foregroundStyle(prominence == .inactive ? .secondary : .primary)
    }

    private var presentedDisplayValue: String? {
        guard let displayValue else { return nil }
        let trimmed = displayValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty, trimmed != value.rawJSONString else {
            return nil
        }
        return trimmed
    }
}

private struct DeviceAdvancedControl: Identifiable {
    let descriptor: HBControlDescriptor
    var controlPath: String
    var stackAvailable = false
    var stack: HBControlStackResult? = nil
    var observation: DeviceAdvancedObservation? = nil

    var id: String {
        descriptor.identifier
    }

    var holds: [HBHoldDescriptor] {
        stack?.holds ?? []
    }

    var activeHold: HBHoldDescriptor? {
        holds.first { $0.active }
    }

    var observedValue: HBJSONValue {
        observation?.value ?? descriptor.value ?? .null
    }

    var observedDisplayValue: String? {
        observation?.displayValue
            ?? descriptor.metadata["displayValue"]?.stringValue
    }

    var isDerived: Bool {
        descriptor.metadata["derived"]?.boolValue == true
    }

    var observedDetails: [String] {
        var ordinaryDetails = ["kind: \(descriptor.kind)"]
        if let valid = observation?.valid
            ?? descriptor.metadata["valid"]?.boolValue {
            ordinaryDetails.append("valid: \(valid)")
        }
        let metadataDetails = descriptor.metadata.keys.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }.compactMap { key -> String? in
            guard let value = descriptor.metadata[key] else { return nil }
            return "metadata.\(key): \(value.rawJSONString)"
        }
        return ordinaryDetails.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        } + metadataDetails
    }

    func holdDetails(_ hold: HBHoldDescriptor) -> [String] {
        var details: [String] = []
        if let sourceName = hold.sourceName {
            details.append("source: \(sourceName)")
        }
        if let timing = hold.timing {
            details.append(
                "timing: {\"delay\":\(timing.delay.rawJSONString),"
                    + "\"duration\":\(timing.duration.rawJSONString)}"
            )
        }
        return details
    }
}

private struct DeviceAdvancedObservation {
    var value: HBJSONValue?
    var displayValue: String?
    var valid: Bool?
}

@MainActor
private final class DeviceAdvancedModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case live
        case failed(String)
    }

    private enum OverrideReleaseError: LocalizedError {
        case unavailable
        case noRetainedValue

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "The override is no longer available."
            case .noRetainedValue:
                "The control has no active retained value to return to."
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var deviceDetails: HBDeviceDescriptor?
    @Published private(set) var controls: [DeviceAdvancedControl] = []

    private let device: HBTopologyDeviceDescriptor
    private let client: HomeBaseWebSocketClient
    private var controlSubscriptionID: UUID?
    private var stackSubscriptionID: UUID?
    private var stackMonitorTask: Task<Void, Never>?
    private var controlsByIdentifier: [String: DeviceAdvancedControl] = [:]

    init(
        device: HBTopologyDeviceDescriptor,
        client: HomeBaseWebSocketClient
    ) {
        self.device = device
        self.client = client
    }

    func run(reactivating: Bool = false) async {
        guard state != .loading, state != .live else { return }
        state = .loading

        do {
            if reactivating {
                try await client.reactivate()
            } else {
                try await client.connect()
            }
            let details = try await client.deviceDetails(for: device)
            try Task.checkCancellation()
            deviceDetails = details

            let controlSubscription = try await client.subscribe(
                to: device,
                includeCompatibility: true,
                projection: .observed
            )
            if Task.isCancelled {
                try? await client.cancelSubscription(
                    controlSubscription.identifier
                )
                throw CancellationError()
            }
            controlSubscriptionID = controlSubscription.identifier
            install(
                details.controls,
                streamedControls: controlSubscription.controls
            )

            await startStackMonitoringIfAvailable(in: details.controls)
            try Task.checkCancellation()
            state = .live

            for try await event in controlSubscription.events {
                try Task.checkCancellation()
                applyControlEvent(event)
            }

            if !Task.isCancelled, state == .live {
                state = .failed("The live control subscription ended.")
            }
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }

        await stopSubscriptions()
    }

    func restart() async {
        await stop()
        await run(reactivating: true)
    }

    func stop() async {
        state = .idle
        await stopSubscriptions()
    }

    func clearExternalOverride(for identifier: String) async throws {
        guard state == .live,
              let control = controlsByIdentifier[identifier.lowercased()],
              let stack = control.stack,
              stack.externalOverride != nil else {
            throw OverrideReleaseError.unavailable
        }
        guard let activeHold = control.activeHold else {
            throw OverrideReleaseError.noRetainedValue
        }

        // External-override writes matching the current retained intent are
        // the protocol's release operation. The historical captured return
        // value is deliberately not used because automation may have changed
        // the retained stack since the override began.
        try await client.setControl(
            stack.control,
            to: activeHold.value
        )
    }

    private func install(
        _ descriptors: [HBControlDescriptor],
        streamedControls: [HBControlWatchStreamControl]
    ) {
        let previous = controlsByIdentifier
        let pathsByIdentifier = Dictionary(
            uniqueKeysWithValues: streamedControls.map {
                ($0.controlIdentifier.lowercased(), $0.control)
            }
        )
        controlsByIdentifier = Dictionary(
            uniqueKeysWithValues: descriptors.map { descriptor in
                let identifier = descriptor.identifier.lowercased()
                let prior = previous[identifier]
                return (
                    identifier,
                    DeviceAdvancedControl(
                        descriptor: descriptor,
                        controlPath: pathsByIdentifier[identifier]
                            ?? previous[identifier]?.controlPath
                            ?? "\(device.addressableName):\(descriptor.identifier)",
                        stackAvailable: false,
                        stack: prior?.stack,
                        observation: prior?.observation
                            ?? DeviceAdvancedObservation(
                                value: descriptor.value,
                                displayValue: descriptor.metadata["displayValue"]?
                                    .stringValue,
                                valid: descriptor.metadata["valid"]?.boolValue
                            )
                    )
                )
            }
        )
        publishControls()
    }

    private func startStackMonitoringIfAvailable(
        in descriptors: [HBControlDescriptor]
    ) async {
        let writableIdentifiers = descriptors.compactMap { descriptor in
            descriptor.metadata["writable"]?.boolValue == true
                ? descriptor.identifier
                : nil
        }
        guard !writableIdentifiers.isEmpty else { return }

        do {
            let subscription = try await client.subscribeToControlStacks(
                for: device,
                controlIdentifiers: writableIdentifiers,
                includeCompatibility: true
            )
            if Task.isCancelled {
                try? await client.cancelSubscription(subscription.identifier)
                return
            }
            stackSubscriptionID = subscription.identifier
            installStackAvailability(subscription.controls)
            stackMonitorTask = Task { [weak self] in
                do {
                    for try await event in subscription.events {
                        try Task.checkCancellation()
                        self?.applyStackEvent(event)
                    }
                } catch {
                    // Observed-value monitoring is the required half of this
                    // hybrid screen. A stack stream ending must not discard it.
                }
            }
        } catch {
            // A stack is supplemental. Devices with no matching writable
            // stacks still have a complete Advanced screen through the normal
            // observed-value subscription.
        }
    }

    private func installStackAvailability(_ controlPaths: [String]) {
        let identifiers = Set(
            controlPaths.compactMap(Self.controlIdentifier).map {
                $0.lowercased()
            }
        )
        for identifier in identifiers {
            if var control = controlsByIdentifier[identifier] {
                control.stackAvailable = true
                controlsByIdentifier[identifier] = control
            }
        }
        publishControls()
    }

    private func applyControlEvent(_ event: HBControlWatchStreamEvent) {
        switch event.kind {
        case .initial, .change, .controlAdded:
            guard let streamedControl = event.control else { return }
            let identifier = streamedControl.controlIdentifier.lowercased()
            if var control = controlsByIdentifier[identifier] {
                control.controlPath = streamedControl.control
                control.observation = DeviceAdvancedObservation(
                    value: event.value,
                    displayValue: event.displayValue,
                    valid: event.valid
                )
                controlsByIdentifier[identifier] = control
            } else {
                controlsByIdentifier[identifier] = DeviceAdvancedControl(
                    descriptor: HBControlDescriptor(
                        identifier: streamedControl.controlIdentifier,
                        name: streamedControl.displayName,
                        kind: streamedControl.kind,
                        value: event.value,
                        projection: event.projection,
                        metadata: streamedControl.metadata
                    ),
                    controlPath: streamedControl.control,
                    stackAvailable: false,
                    observation: DeviceAdvancedObservation(
                        value: event.value,
                        displayValue: event.displayValue,
                        valid: event.valid
                    )
                )
            }
            publishControls()

        case .controlRemoved:
            guard let streamedControl = event.control else { return }
            let identifier = streamedControl.controlIdentifier.lowercased()
            controlsByIdentifier.removeValue(forKey: identifier)
            publishControls()

        case .heartbeat:
            break
        }
    }

    private func applyStackEvent(_ event: HBControlStackWatchStreamEvent) {
        guard event.kind != .heartbeat,
              let path = event.control,
              let identifier = Self.controlIdentifier(path)?.lowercased()
        else { return }

        switch event.kind {
        case .initial, .change, .controlAdded:
            guard let snapshot = event.snapshot else { return }
            if var control = controlsByIdentifier[identifier] {
                control.controlPath = path
                control.stackAvailable = true
                control.stack = snapshot.stack
                controlsByIdentifier[identifier] = control
            } else {
                let rawIdentifier = Self.controlIdentifier(path) ?? path
                controlsByIdentifier[identifier] = DeviceAdvancedControl(
                    descriptor: HBControlDescriptor(
                        identifier: rawIdentifier,
                        name: rawIdentifier,
                        kind: "Unknown"
                    ),
                    controlPath: path,
                    stackAvailable: true,
                    stack: snapshot.stack
                )
            }
            publishControls()

        case .controlRemoved:
            if var control = controlsByIdentifier[identifier] {
                control.stackAvailable = false
                control.stack = nil
                controlsByIdentifier[identifier] = control
                publishControls()
            }

        case .heartbeat:
            break
        }
    }

    private func publishControls() {
        controls = controlsByIdentifier.values.sorted { left, right in
            if left.isDerived != right.isDerived {
                return !left.isDerived
            }
            let order = left.descriptor.identifier
                .localizedCaseInsensitiveCompare(right.descriptor.identifier)
            if order != .orderedSame {
                return order == .orderedAscending
            }
            return left.descriptor.identifier < right.descriptor.identifier
        }
    }

    private func stopSubscriptions() async {
        stackMonitorTask?.cancel()
        stackMonitorTask = nil

        let identifiers = [controlSubscriptionID, stackSubscriptionID]
            .compactMap { $0 }
        controlSubscriptionID = nil
        stackSubscriptionID = nil
        for identifier in identifiers {
            try? await client.cancelSubscription(identifier)
        }
    }

    private static func controlIdentifier(_ path: String) -> String? {
        guard let separator = path.lastIndex(of: ":") else { return nil }
        return String(path[path.index(after: separator)...])
    }
}

private extension DeviceAdvancedModel.State {
    var connectionStatusPresentation: ConnectionStatusPresentation {
        switch self {
        case .idle:
            .disconnected("Not Loaded", systemImage: "pause.circle")
        case .loading:
            .pending("Loading control stacks…")
        case .live:
            .connected
        case .failed(let message):
            .failed(title: "Loading Failed", message: message)
        }
    }
}

private extension HBJSONValue {
    var rawJSONString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else {
            return "null"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private extension Double {
    var rawJSONString: String {
        String(describing: self)
    }
}
