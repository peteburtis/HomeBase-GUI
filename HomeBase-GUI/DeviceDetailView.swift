//
//  DeviceDetailView.swift
//  HomeBase-GUI
//

import Combine
import Foundation
import HomeBaseProtocol
import SwiftUI

struct DeviceDetailView: View {
    @Environment(\.scenePhase) private var scenePhase

    let device: HBTopologyDeviceDescriptor
    @StateObject private var model: LiveDeviceControlsModel

    init(
        device: HBTopologyDeviceDescriptor,
        client: HomeBaseWebSocketClient
    ) {
        self.device = device
        _model = StateObject(
            wrappedValue: LiveDeviceControlsModel(
                device: device,
                client: client
            )
        )
    }

    var body: some View {
        List {
            LiveDeviceControlSections(
                model: model,
                subjectKind: "device"
            )
        }
        .navigationTitle(device.displayName)
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
}

struct LiveDeviceControlSections: View {
    @ObservedObject var model: LiveDeviceControlsModel
    let subjectKind: String

    @ViewBuilder
    var body: some View {
        Section {
            if model.controls.isEmpty {
                Text(emptyControlsMessage)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.controls) { control in
                    ControlStateRow(
                        control: control,
                        interactionEnabled: model.state == .live,
                        setValue: { value in
                            await model.setNumericValue(value, for: control)
                        },
                        setColorValue: { value in
                            try await model.setColorValue(value, for: control)
                        },
                        colorValues: {
                            model.colorValueStream(for: control)
                        }
                    )
                    .alignmentGuide(.listRowSeparatorLeading) {
                        $0[.leading]
                    }
                    .alignmentGuide(.listRowSeparatorTrailing) {
                        $0[.trailing]
                    }
                }
            }
        } header: {
            Text("Controls")
        }
    }

    private var emptyControlsMessage: String {
        switch model.state {
        case .live:
            "This \(subjectKind) has no readable controls."
        case .failed:
            "Controls could not be loaded."
        case .idle, .loading:
            "Controls will appear when monitoring begins."
        }
    }
}

private struct ControlStateRow: View {
    let control: LiveDeviceControl
    let interactionEnabled: Bool
    let setValue: (Double) async -> Void
    let setColorValue: (HBJSONValue) async throws -> Void
    let colorValues: () -> AsyncThrowingStream<
        HomeBaseColorPickerObservation,
        Error
    >

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(control.displayName)
                    Text(control.detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    ControlValueView(
                        control: control,
                        interactionEnabled: interactionEnabled,
                        setValue: setValue,
                        setColorValue: setColorValue,
                        colorValues: colorValues
                    )
                    if control.valid == false,
                       !control.valuePresentation.presentsStaleness {
                        Label(
                            "Stale",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }

            if let updateError = control.updateError {
                Label(
                    updateError,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
    }
}

struct LiveDeviceControl: Identifiable {
    private static let primaryControlTag = "primary-control"

    let descriptor: HBControlWatchStreamControl
    var details: HBControlDescriptor? = nil
    var value: HBJSONValue? = nil
    var displayValue: String? = nil
    var valid: Bool? = nil
    var aggregateState: HBControlAggregateState? = nil
    var aggregateValues: [HBJSONValue]? = nil
    var aggregateValueCount: Int? = nil
    var hasAcceptedObservation = false
    var pendingValue: HBJSONValue? = nil
    var isUpdating = false
    var updateError: String? = nil

    var id: String {
        Self.identity(for: descriptor)
    }

    var displayName: String {
        descriptor.displayName
    }

    var isPrimary: Bool {
        descriptor.tags.contains(Self.primaryControlTag)
            || details?.tags.contains(Self.primaryControlTag) == true
    }

    var detailText: String {
        var parts = [descriptor.kind]
        if let writable = details?.metadata["writable"]?.boolValue {
            parts.append(writable ? "Read and write" : "Read only")
        }
        return parts.joined(separator: " · ")
    }

    var presentedValue: String {
        if pendingValue == nil,
           let displayValue,
           !displayValue.isEmpty {
            return displayValue
        }
        guard let value = pendingValue ?? value else { return "—" }
        let suffix = details?.metadata["unitSuffix"]?.stringValue ?? ""
        return value.presentationText + suffix
    }

    static func identity(
        for descriptor: HBControlWatchStreamControl
    ) -> String {
        descriptor.deviceIdentifier + "\u{0}" + descriptor.controlIdentifier
    }
}

@MainActor
final class LiveDeviceControlsModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case live
        case failed(String)
    }

    private enum UpdateError: LocalizedError {
        case unavailable
        case unsupportedColor

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "This control is not currently available."
            case .unsupportedColor:
                "This color value is not supported by the control."
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var controls: [LiveDeviceControl] = []

    private let device: HBTopologyDeviceDescriptor?
    private let client: HomeBaseWebSocketClient
    private var subscriptionID: UUID?
    private var detailsByIdentifier: [String: HBControlDescriptor] = [:]
    private var controlsByIdentity: [String: LiveDeviceControl] = [:]

    init(
        device: HBTopologyDeviceDescriptor?,
        client: HomeBaseWebSocketClient
    ) {
        self.device = device
        self.client = client
    }

    func run(reactivating: Bool = false) async {
        guard state != .loading, state != .live else { return }
        guard let device else { return }
        state = .loading

        do {
            if reactivating {
                try await client.reactivate()
            } else {
                try await client.connect()
            }
            let details = try await client.deviceDetails(for: device)
            try Task.checkCancellation()
            detailsByIdentifier = Dictionary(
                uniqueKeysWithValues: details.controls.map {
                    ($0.identifier.lowercased(), $0)
                }
            )

            let subscription = try await client.subscribe(to: device)
            if Task.isCancelled {
                try? await client.cancelSubscription(
                    subscription.identifier
                )
                throw CancellationError()
            }
            subscriptionID = subscription.identifier
            install(subscription.controls)
            state = .live

            for try await event in subscription.events {
                try Task.checkCancellation()
                apply(event)
            }

            if !Task.isCancelled, state == .live {
                state = .failed("The live subscription ended.")
            }
        } catch is CancellationError {
            state = .idle
            return
        } catch {
            state = .failed(error.localizedDescription)
        }

        await stopSubscription()
    }

    func stop() async {
        state = .idle
        await stopSubscription()
    }

    func setNumericValue(
        _ value: Double,
        for control: LiveDeviceControl
    ) async {
        ControlWriteDiagnostics.logNumeric(
            stage: "model-numeric-entry",
            control: control.descriptor.control,
            value: value
        )
        guard value.isFinite else { return }

        let protocolValue: HBJSONValue
        switch control.descriptor.kind.lowercased() {
        case "binaryswitch":
            protocolValue = .integer(value > 0 ? 1 : 0)
        case "unitinterval":
            protocolValue = .number(value)
        default:
            return
        }

        await setValue(protocolValue, for: control)
    }

    func setColorValue(
        _ value: HBJSONValue,
        for control: LiveDeviceControl
    ) async throws {
        guard let capabilities = HomeBaseColorPickerCapabilities(
            controlKind: control.descriptor.kind
        ),
        let key = value.objectValue?.keys.first?.lowercased(),
        (key == "xy" && capabilities.supportsXY)
            || (key == "rgb" && capabilities.supportsRGB)
            || (key == "white" && capabilities.supportsWhite) else {
            throw UpdateError.unsupportedColor
        }

        ControlWriteDiagnostics.log(
            stage: "model-color-entry",
            control: control.descriptor.control,
            value: value
        )
        let identity = control.id
        guard var current = controlsByIdentity[identity],
              !current.isUpdating else {
            throw UpdateError.unavailable
        }

        current.pendingValue = value
        current.isUpdating = true
        current.updateError = nil
        controlsByIdentity[identity] = current
        publishControls()

        do {
            do {
                try await client.setControl(
                    current.descriptor.control,
                    to: value
                )
            } catch let protocolError as HBProtocolError {
                throw protocolError
            } catch {
                // A picker remains useful as a pushed screen even though the
                // originating detail view may no longer be monitoring. If its
                // session went away during that transition, rebuild it once
                // and repeat this idempotent color write.
                try await client.reactivate()
                try await client.setControl(
                    current.descriptor.control,
                    to: value
                )
            }

            guard var updated = controlsByIdentity[identity] else { return }
            updated.value = value
            updated.displayValue = nil
            updated.pendingValue = nil
            updated.isUpdating = false
            updated.updateError = nil
            controlsByIdentity[identity] = updated
            publishControls()
        } catch {
            if var updated = controlsByIdentity[identity] {
                updated.pendingValue = nil
                updated.isUpdating = false
                updated.updateError =
                    "Could not update: \(error.localizedDescription)"
                controlsByIdentity[identity] = updated
                publishControls()
            }
            throw error
        }
    }

    func colorValueStream(
        for control: LiveDeviceControl
    ) -> AsyncThrowingStream<HomeBaseColorPickerObservation, Error> {
        let client = client
        let deviceIdentifier = control.descriptor.deviceIdentifier
        let controlIdentifier = control.descriptor.controlIdentifier
        let subscriptionDevice = HBTopologyDeviceDescriptor(
            identifier: deviceIdentifier,
            addressableName: deviceIdentifier,
            displayName: control.displayName
        )

        return AsyncThrowingStream { continuation in
            let producer = Task {
                var subscriptionID: UUID?
                do {
                    try await client.reactivate()
                    let subscription = try await client.subscribe(
                        to: subscriptionDevice
                    )
                    subscriptionID = subscription.identifier

                    for try await event in subscription.events {
                        try Task.checkCancellation()
                        guard event.kind == .initial
                                || event.kind == .change
                                || event.kind == .controlAdded,
                              let descriptor = event.control,
                              descriptor.deviceIdentifier
                                .caseInsensitiveCompare(deviceIdentifier)
                                == .orderedSame,
                              descriptor.controlIdentifier
                                .caseInsensitiveCompare(controlIdentifier)
                                == .orderedSame,
                              event.valid != false,
                              event.aggregateState != .unavailable else {
                            continue
                        }
                        continuation.yield(
                            HomeBaseColorPickerObservation(
                                value: event.value,
                                aggregateState: event.aggregateState,
                                aggregateValues: event.aggregateValues,
                                aggregateValueCount: event.aggregateValueCount
                            )
                        )
                    }

                    if let subscriptionID {
                        try? await client.cancelSubscription(subscriptionID)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    if let subscriptionID {
                        try? await client.cancelSubscription(subscriptionID)
                    }
                    continuation.finish()
                } catch {
                    if let subscriptionID {
                        try? await client.cancelSubscription(subscriptionID)
                    }
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }

    private func setValue(
        _ value: HBJSONValue,
        for control: LiveDeviceControl
    ) async {
        ControlWriteDiagnostics.log(
            stage: "model-entry",
            control: control.descriptor.control,
            value: value
        )
        let identity = control.id
        guard state == .live,
              var current = controlsByIdentity[identity],
              !current.isUpdating else {
            return
        }

        current.pendingValue = value
        current.isUpdating = true
        current.updateError = nil
        controlsByIdentity[identity] = current
        publishControls()

        do {
            try await client.setControl(
                current.descriptor.control,
                to: value
            )
            guard var updated = controlsByIdentity[identity] else { return }
            // Preserve the accepted value while the live subscription catches
            // up. Otherwise clearing the optimistic value can briefly restore
            // the pre-write state and make a slider or toggle jump backward.
            updated.value = value
            updated.displayValue = nil
            updated.pendingValue = nil
            updated.isUpdating = false
            controlsByIdentity[identity] = updated
        } catch is CancellationError {
            guard var updated = controlsByIdentity[identity] else { return }
            updated.pendingValue = nil
            updated.isUpdating = false
            controlsByIdentity[identity] = updated
        } catch {
            guard var updated = controlsByIdentity[identity] else { return }
            updated.pendingValue = nil
            updated.isUpdating = false
            updated.updateError =
                "Could not update: \(error.localizedDescription)"
            controlsByIdentity[identity] = updated
        }

        publishControls()
    }

    private func install(
        _ descriptors: [HBControlWatchStreamControl]
    ) {
        let previousControls = controlsByIdentity
        controlsByIdentity = Dictionary(
            uniqueKeysWithValues: descriptors.map { descriptor in
                let details = detailsByIdentifier[
                    descriptor.controlIdentifier.lowercased()
                ]
                let identity = LiveDeviceControl.identity(for: descriptor)
                var installed = LiveDeviceControl(
                    descriptor: descriptor,
                    details: details,
                    value: details?.value,
                    displayValue:
                        details?.metadata["displayValue"]?.stringValue,
                    valid: details?.metadata["valid"]?.boolValue,
                    aggregateState: details?.aggregateState,
                    aggregateValues: details?.aggregateValues,
                    aggregateValueCount: details?.aggregateValueCount
                )
                installed.hasAcceptedObservation = installed.value != nil
                    && installed.valid != false
                    && installed.aggregateState != .unavailable

                // Reconnection can begin while providers are temporarily
                // invalid. Preserve an observation this view accepted before
                // reconnecting rather than replacing it with the aggregate
                // control's retained, non-authoritative value.
                if (installed.valid == false
                    || installed.aggregateState == .unavailable),
                   let previous = previousControls[identity],
                   previous.hasAcceptedObservation {
                    installed.value = previous.value
                    installed.displayValue = previous.displayValue
                    installed.aggregateState = previous.aggregateState
                    installed.aggregateValues = previous.aggregateValues
                    installed.aggregateValueCount =
                        previous.aggregateValueCount
                    installed.valid = false
                    installed.hasAcceptedObservation = true
                }
                return (
                    identity,
                    installed
                )
            }
        )
        publishControls()
    }

    private func apply(_ event: HBControlWatchStreamEvent) {
        switch event.kind {
        case .initial, .change, .controlAdded:
            guard let descriptor = event.control else { return }
            let identity = LiveDeviceControl.identity(for: descriptor)
            var control = controlsByIdentity[identity]
                ?? LiveDeviceControl(
                    descriptor: descriptor,
                    details: detailsByIdentifier[
                        descriptor.controlIdentifier.lowercased()
                    ]
                )
            let eventIsUsable = event.valid != false
                && event.aggregateState != .unavailable

            if eventIsUsable || !control.hasAcceptedObservation {
                control.value = event.value
                control.displayValue = event.displayValue
                control.aggregateState = event.aggregateState
                control.aggregateValues = event.aggregateValues
                control.aggregateValueCount = event.aggregateValueCount
            }
            if eventIsUsable {
                control.hasAcceptedObservation = event.value != nil
                    || event.aggregateValues != nil
            }
            // Invalid provider state is still useful status information, but
            // its retained value is explicitly not a new observation.
            control.valid = eventIsUsable ? event.valid : false
            controlsByIdentity[identity] = control
            publishControls()

        case .controlRemoved:
            guard let descriptor = event.control else { return }
            controlsByIdentity.removeValue(
                forKey: LiveDeviceControl.identity(for: descriptor)
            )
            publishControls()

        case .heartbeat:
            break
        }
    }

    private func publishControls() {
        controls = controlsByIdentity.values.sorted {
            if $0.isPrimary != $1.isPrimary {
                return $0.isPrimary
            }

            let displayOrder = $0.displayName
                .localizedCaseInsensitiveCompare($1.displayName)
            if displayOrder != .orderedSame {
                return displayOrder == .orderedAscending
            }
            return $0.descriptor.controlIdentifier
                .localizedCaseInsensitiveCompare(
                    $1.descriptor.controlIdentifier
                ) == .orderedAscending
        }
    }

    private func stopSubscription() async {
        guard let subscriptionID else { return }
        self.subscriptionID = nil
        try? await client.cancelSubscription(subscriptionID)
    }
}

extension LiveDeviceControlsModel.State {
    var connectionStatusPresentation: ConnectionStatusPresentation {
        switch self {
        case .idle:
            .disconnected("Not Monitoring", systemImage: "pause.circle")
        case .loading:
            .pending("Loading controls…")
        case .live:
            .connected
        case .failed(let message):
            .failed(title: "Monitoring Failed", message: message)
        }
    }
}

private extension HBControlDescriptor {
    var aggregateState: HBControlAggregateState? {
        guard let value = metadata["aggregateState"]?.stringValue else {
            return nil
        }
        return HBControlAggregateState(rawValue: value)
    }

    var aggregateValues: [HBJSONValue]? {
        metadata["aggregateValues"]?.arrayValue
    }

    var aggregateValueCount: Int? {
        guard let value = metadata["aggregateValueCount"]?.integerValue else {
            return nil
        }
        return Int(exactly: value)
    }
}

private extension HBJSONValue {
    var presentationText: String {
        switch self {
        case .null:
            "null"
        case .bool(let value):
            value ? "True" : "False"
        case .integer(let value):
            String(value)
        case .number(let value):
            value.formatted(
                .number.precision(.fractionLength(0 ... 6))
            )
        case .string(let value):
            value
        case .array, .object:
            compactJSONString
        }
    }

    private var compactJSONString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else {
            return "—"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
