import Foundation
import HomeBaseProtocol

/// Intersection by semantic role, not vendor-specific control identifier.
/// The first selected camera supplies displayed state; only explicit user
/// actions fan out. Values are translated into each camera's own wire format.
@MainActor
struct CameraGroupControlSnapshot {
    enum Role { case privacy, dayNight }
    struct Write {
        let model: LiveDeviceControlsModel
        let control: LiveDeviceControl
        let value: HBJSONValue
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    let models: [LiveDeviceControlsModel]
    private(set) var controls: [LiveDeviceControl] = []
    private var routes: [String: (Role, [LiveDeviceControl])] = [:]

    init(models: [LiveDeviceControlsModel]) {
        self.models = models
        guard !models.isEmpty, models.allSatisfy({ $0.state == .live }) else { return }
        let sets = models.map { CameraDetailControlSet(controls: $0.controls) }
        for role in [Role.privacy, .dayNight] {
            let matched: [LiveDeviceControl] = models.indices.compactMap { index in
                switch role {
                case .privacy: return sets[index].privacy
                case .dayNight: return CameraDayNightModeTarget(controls: models[index].controls)?.control
                }
            }
            guard matched.count == models.count, matched.allSatisfy({ $0.valid != false && $0.value != nil }),
                  var lead = matched.first else { continue }
            var metadata = lead.cameraOverlayMetadata
            switch role {
            case .privacy:
                guard matched.allSatisfy({ $0.cameraOverlayBooleanValue != nil }) else { continue }
            case .dayNight:
                let targets = models.compactMap { CameraDayNightModeTarget(controls: $0.controls) }
                guard targets.count == models.count, targets.allSatisfy({ $0.selectedMode != nil }) else { continue }
                let common = targets[0].choices.filter { choice in targets.allSatisfy { $0.wireValue(for: choice.mode) != nil } }
                guard common.count >= 2 else { continue }
                metadata["choices"] = .array(common.map { .object(["label": .string($0.mode.title), "value": $0.wireValue]) })
            }
            var detail = lead.details ?? HBControlDescriptor(identifier: lead.descriptor.controlIdentifier,
                name: lead.displayName, kind: lead.descriptor.kind)
            detail.metadata = metadata; lead.details = detail
            lead.isUpdating = matched.contains { $0.isUpdating }
            controls.append(lead); routes[lead.id] = (role, matched)
        }
    }

    func writes(value: HBJSONValue, control: LiveDeviceControl) throws -> [Write] {
        guard let (role, peers) = routes[control.id], peers.count == models.count else {
            throw Failure(message: "This control is no longer available on every selected camera.")
        }
        return try peers.enumerated().map { index, peer in
            let translated: HBJSONValue
            switch role {
            case .privacy:
                guard let flag = value.boolValue ?? value.numberValue.map({ $0 > 0 }) else {
                    throw Failure(message: "Invalid privacy value.")
                }
                translated = peer.cameraOverlayBooleanWireValue(flag)
            case .dayNight:
                guard let source = CameraDayNightModeTarget(controls: models[0].controls),
                      let mode = source.choices.first(where: { $0.wireValue.isEquivalentControlValue(to: value) })?.mode,
                      let target = CameraDayNightModeTarget(controls: models[index].controls),
                      let wire = target.wireValue(for: mode) else {
                    throw Failure(message: "This day/night mode is not supported by every selected camera.")
                }
                translated = wire
            }
            return Write(model: models[index], control: peer, value: translated)
        }
    }

    static func perform(_ writes: [Write]) async throws {
        // Await every response, including after a failure; do not pretend a
        // distributed camera change is atomic or silently leave partial errors.
        let errors = await withTaskGroup(of: String?.self) { group in
            for write in writes {
                group.addTask { @MainActor in
                    do {
                        try Task.checkCancellation()
                        try await write.model.setPresentedValue(write.value, for: write.control, origin: .inline)
                        return nil
                    } catch { return "\(write.control.descriptor.deviceIdentifier): \(error.localizedDescription)" }
                }
            }
            var errors: [String] = []
            for await error in group { if let error { errors.append(error) } }
            return errors
        }
        if !errors.isEmpty { throw Failure(message: errors.joined(separator: "\n")) }
    }

}
