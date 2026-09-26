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
    private let client: HomeBaseWebSocketClient
    @StateObject private var model: LiveDeviceControlsModel
    @State private var isShowingFullScreenVideo = false
    @State private var videoRestartRequest = 0

    init(
        device: HBTopologyDeviceDescriptor,
        client: HomeBaseWebSocketClient
    ) {
        self.device = device
        self.client = client
        _model = StateObject(
            wrappedValue: LiveDeviceControlsModel(
                device: device,
                client: client
            )
        )
    }

    var body: some View {
        CameraAccessGate { access in
            detail(access: access)
        }
        .cameraAccessScope(
            isActive: cameraCapability != nil,
            isPresentingCamera: isShowingFullScreenVideo
        )
    }

    private func detail(access: CameraAccessPresentation) -> some View {
        List {
            if let cameraCapability {
                Section {
                    CameraProtectedPreview(access: access) {
                        CameraLiveVideoPlayer(
                            deviceIdentifier: device.addressableName,
                            quality: CameraLiveQualitySelection(cameraCapability.previewQuality),
                            client: client,
                            allowsRetry: false,
                            isStreamEnabled: access.canStream && !isShowingFullScreenVideo,
                            restartRequest: videoRestartRequest
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(9)
                                .cameraGlassBacker(
                                    in: Circle(),
                                    interactive: true
                                )
                                .padding(10)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard access.isUnlocked else { return }
                            isShowingFullScreenVideo = true
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Opens higher-quality live video")
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.black)

                if access.showsUnlockRecovery {
                    Section {
                        CameraUnlockButton(access: access)
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            LiveDeviceControlSections(
                model: model,
                subjectKind: "device"
            )

            Section {
                NavigationLink {
                    DeviceAdvancedView(
                        device: device,
                        client: client
                    )
                } label: {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
            }
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
        .onChange(of: privacyEnabled) { previousValue, currentValue in
            guard CameraPrivacyStreamRecovery.shouldRequestRestart(
                from: previousValue,
                to: currentValue
            ) else { return }
            videoRestartRequest &+= 1
        }
#if os(iOS)
        .fullScreenCover(isPresented: $isShowingFullScreenVideo) {
            fullScreenVideo
        }
#else
        .sheet(isPresented: $isShowingFullScreenVideo) {
            fullScreenVideo
        }
#endif
    }

    private var cameraCapability: CameraLiveVideoCapability? {
        CameraLiveVideoCapability(metadata: model.deviceMetadata)
    }

    private var privacyEnabled: Bool? {
        CameraDetailControlSet(controls: model.controls)
            .observedPrivacyEnabled
    }

    @ViewBuilder
    private var fullScreenVideo: some View {
        if let cameraCapability {
            CameraFullScreenLiveVideoView(
                device: device,
                quality: cameraCapability.fullScreenQuality,
                client: client
            )
        }
    }
}

struct LiveDeviceControlSections: View {
    @ObservedObject var model: LiveDeviceControlsModel
    let subjectKind: String

    @ViewBuilder
    var body: some View {
        Section {
            if visibleControls.isEmpty {
                Text(emptyControlsMessage)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleControls) { control in
                    ControlStateRow(
                        control: control,
                        interactionEnabled: model.state == .live,
                        setValue: { value, origin in
                            try await model.setPresentedValue(
                                value,
                                for: control,
                                origin: origin
                            )
                        },
                        values: {
                            model.valueStream(for: control)
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

    private var visibleControls: [LiveDeviceControl] {
        model.controls.filter { !$0.isHidden }
    }

    private var emptyControlsMessage: String {
        switch model.state {
        case .live:
            "This \(subjectKind) has no visible readable controls."
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
    let setValue:
        (HBJSONValue, ControlValueCommitOrigin) async throws -> Void
    let values: () -> AsyncThrowingStream<
        ControlValueObservation,
        Error
    >

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(control.displayName)
                    Text(control.subtitleText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    ControlValueView(
                        control: control,
                        interactionEnabled: interactionEnabled,
                        setValue: setValue,
                        values: values
                    )
                    if control.valid == false,
                       !control.valuePresentationHandlesStaleness {
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
    private static let primaryControlMetadataKey = "primary-control"

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
        descriptor.metadata[Self.primaryControlMetadataKey]?.boolValue == true
            || details?.metadata[Self.primaryControlMetadataKey]?.boolValue
                == true
    }

    var isHidden: Bool {
        descriptor.metadata.hasHiddenFlag
            || details?.metadata.hasHiddenFlag == true
    }

    var subtitleText: String {
        descriptor.controlIdentifier
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

        var errorDescription: String? {
            "This control is not currently available."
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var controls: [LiveDeviceControl] = []
    @Published private(set) var deviceMetadata: [String: HBJSONValue]

    private let device: HBTopologyDeviceDescriptor?
    private let client: HomeBaseWebSocketClient
    private var subscriptionID: UUID?
    private var metadataTask: Task<Void, Never>?
    private var detailsByIdentifier: [String: HBControlDescriptor] = [:]
    private var controlsByIdentity: [String: LiveDeviceControl] = [:]
    private var suggestedControlOrder = SuggestedControlDisplayOrder()
    private var routedWrite: ((HBJSONValue, LiveDeviceControl, ControlValueCommitOrigin) async throws -> Void)?
    private var routedCanonicalWrite: ((HBJSONValue, String) async throws -> Void)?
    private var aggregateWrites: Set<String> = []

    init(
        device: HBTopologyDeviceDescriptor?,
        client: HomeBaseWebSocketClient
    ) {
        self.device = device
        self.client = client
        deviceMetadata = device?.metadata ?? [:]
    }

    /// A screen-local camera group, not an engine configuration or virtual group.
    /// Installing observations here never sends a write to any camera.
    func installWriteRouting(
        value: @escaping (HBJSONValue, LiveDeviceControl, ControlValueCommitOrigin) async throws -> Void,
        canonical: @escaping (HBJSONValue, String) async throws -> Void
    ) {
        precondition(device == nil)
        routedWrite = value; routedCanonicalWrite = canonical
    }

    func installAggregatePresentation(_ values: [LiveDeviceControl]) {
        precondition(device == nil)
        controlsByIdentity = Dictionary(uniqueKeysWithValues: values.map { control in
            var value = control
            if let previous = controlsByIdentity[control.id], aggregateWrites.contains(control.id) {
                value.pendingValue = previous.pendingValue
                value.isUpdating = true
            }
            return (value.id, value)
        })
        controls = values.map { controlsByIdentity[$0.id]! }
        state = .live
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
            let metadata = try await client.deviceDetailsWithMetadata(for: device)
            let details = metadata.details
            try Task.checkCancellation()
            deviceMetadata = metadata.metadata
            metadataTask?.cancel()
            metadataTask = Task { [weak self] in
                do {
                    for try await values in metadata.events {
                        guard !Task.isCancelled else { return }
                        self?.deviceMetadata = values
                    }
                } catch {} // Control subscription owns connection-error presentation.
            }
            suggestedControlOrder = SuggestedControlDisplayOrder(
                metadata: details.metadata
            )
            detailsByIdentifier = Dictionary(
                uniqueKeysWithValues: details.controls.map {
                    ($0.identifier.lowercased(), $0)
                }
            )

            // A virtual group can describe controls even when none of its
            // standard controls are currently readable. The stream API
            // correctly rejects that selector because it expands to no
            // controls; present it as an ordinary empty state instead of a
            // monitoring failure. Compatibility controls remain available on
            // the Advanced screen, whose subscription explicitly includes
            // them.
            guard Self.hasPotentiallyReadableStandardControl(
                in: details.controls
            ) else {
                install([])
                state = .live
                return
            }

            // Interactive controls present the engine's authoritative target.
            // This makes writes through a derived peer (for example,
            // BinarySwitch -> MultilevelSwitch) update every widget in the
            // device immediately, without pretending that provider feedback
            // has already arrived. The Advanced screen remains observed-state
            // based for physical diagnostics.
            let subscription = try await client.subscribe(
                to: device,
                projection: .model
            )
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

    static func hasPotentiallyReadableStandardControl(
        in descriptors: [HBControlDescriptor]
    ) -> Bool {
        descriptors.contains { descriptor in
            guard descriptor.metadata["compatibility"]?.boolValue != true
            else { return false }

            // Missing metadata is treated as unknown so an older or custom
            // provider still gets a chance to resolve through the stream API.
            return descriptor.metadata["readable"]?.boolValue != false
        }
    }

    func stop() async {
        state = .idle
        await stopSubscription()
    }

    func setPresentedValue(
        _ value: HBJSONValue,
        for control: LiveDeviceControl,
        origin: ControlValueCommitOrigin
    ) async throws {
        ControlWriteDiagnostics.log(
            stage: origin == .inline
                ? "model-inline-entry"
                : "model-editor-entry",
            control: control.descriptor.control,
            value: value
        )
        let identity = control.id
        guard (origin == .editor || state == .live),
              var current = controlsByIdentity[identity],
              !current.isUpdating else {
            throw UpdateError.unavailable
        }

        if routedWrite != nil { aggregateWrites.insert(identity) }
        defer { aggregateWrites.remove(identity) }

        current.pendingValue = value
        current.isUpdating = true
        current.updateError = nil
        controlsByIdentity[identity] = current
        publishControls()

        do {
            if let routedWrite {
                try await routedWrite(value, current, origin)
            } else if origin == .editor {
                do {
                    try await client.setControl(
                        current.descriptor.control,
                        to: value
                    )
                } catch let protocolError as HBProtocolError {
                    throw protocolError
                } catch {
                    // A pushed editor may outlive the source detail view. If
                    // that transition retired its socket, rebuild the session
                    // once and repeat this idempotent value write.
                    try await client.reactivate()
                    try await client.setControl(
                        current.descriptor.control,
                        to: value
                    )
                }
            } else {
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
        } catch is CancellationError {
            if var updated = controlsByIdentity[identity] {
                updated.pendingValue = nil
                updated.isUpdating = false
                controlsByIdentity[identity] = updated
                publishControls()
            }
            throw CancellationError()
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

    func setCanonicalPresentedValue(
        _ value: HBJSONValue,
        controlPath: String
    ) async throws {
        guard state == .live else { throw UpdateError.unavailable }
        if let routedCanonicalWrite {
            try await routedCanonicalWrite(value, controlPath)
            return
        }
        try await client.setControl(controlPath, to: value)
    }

    func valueStream(
        for control: LiveDeviceControl
    ) -> AsyncThrowingStream<ControlValueObservation, Error> {
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
                        to: subscriptionDevice,
                        projection: .model
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
                            ControlValueObservation(
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
        controls = suggestedControlOrder.sorted(
            Array(controlsByIdentity.values),
            identifier: { $0.descriptor.controlIdentifier }
        ) { left, right in
            if left.isPrimary != right.isPrimary {
                return left.isPrimary
            }

            let displayOrder = left.displayName
                .localizedCaseInsensitiveCompare(right.displayName)
            if displayOrder != .orderedSame {
                return displayOrder == .orderedAscending
            }
            return left.descriptor.controlIdentifier
                .localizedCaseInsensitiveCompare(
                    right.descriptor.controlIdentifier
                ) == .orderedAscending
        }
    }

    private func stopSubscription() async {
        metadataTask?.cancel(); metadataTask = nil
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
