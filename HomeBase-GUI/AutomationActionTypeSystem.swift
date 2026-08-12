//
//  AutomationActionTypeSystem.swift
//  HomeBase-GUI
//

import HomeBaseProtocol
import SwiftUI

enum AutomationActionConfigurationContext: Equatable, Sendable {
    case scene
    case trigger(HBTriggerKind)

    var applicability: AutomationActionApplicability {
        switch self {
        case .scene:
            .scene
        case .trigger(.when):
            .whenTrigger
        case .trigger(.while):
            .whileTrigger
        }
    }
}

struct AutomationActionApplicability: OptionSet, Equatable, Sendable {
    let rawValue: Int

    static let scene = Self(rawValue: 1 << 0)
    static let whenTrigger = Self(rawValue: 1 << 1)
    static let whileTrigger = Self(rawValue: 1 << 2)
    static let triggers: Self = [.whenTrigger, .whileTrigger]
    static let all: Self = [.scene, .whenTrigger, .whileTrigger]

    func supports(_ context: AutomationActionConfigurationContext) -> Bool {
        contains(context.applicability)
    }
}

enum AutomationControlResolution: Equatable, Sendable {
    case resolving
    case resolved(SceneResolvedControl)
    case unavailable(String)
}

enum AutomationActionEditingError: LocalizedError {
    case unsupportedMutation

    var errorDescription: String? {
        switch self {
        case .unsupportedMutation:
            "This action is preserved as JSON but is not editable here."
        }
    }
}

struct AutomationActionPluginPresentation: Equatable, Sendable {
    let title: String
    let detail: String?
}

/// The independently discoverable pieces of UI registered for an action.
/// Presentation is mandatory. Editing and creation are optional so adding a
/// readable description never silently adds an unusable item to New Action.
struct AutomationActionUICapabilities: OptionSet, Equatable, Sendable {
    let rawValue: Int

    static let presentation = Self(rawValue: 1 << 0)
    static let editing = Self(rawValue: 1 << 1)
    static let creation = Self(rawValue: 1 << 2)
}

@MainActor
protocol AutomationActionEditingModel: ObservableObject {
    var isBusy: Bool { get }
    var canMutateStructure: Bool { get }
    var supportsGenericActionMutation: Bool { get }

    func controlResolution(for actionIndex: Int) -> AutomationControlResolution
    func isLoadingCurrentValue(actionIndex: Int) -> Bool
    func actionError(for actionIndex: Int) -> String?
    func setControlValue(actionIndex: Int, value: HBJSONValue) async throws
    func useCurrentValue(actionIndex: Int) async
    func removeControlSet(actionIndex: Int)
    func setAction(actionIndex: Int, rawValue: HBJSONValue) async throws
    func removeAction(actionIndex: Int)
}

extension AutomationActionEditingModel {
    var supportsGenericActionMutation: Bool { false }

    func setAction(
        actionIndex: Int,
        rawValue: HBJSONValue
    ) async throws {
        throw AutomationActionEditingError.unsupportedMutation
    }

    func removeAction(actionIndex: Int) {}
}

@MainActor
struct AutomationActionPresentationContext {
    let action: SceneActionConfiguration
    let isBusy: Bool
    let canMutateStructure: Bool
    let supportsGenericActionMutation: Bool

    private let controlResolutionImplementation:
        (Int) -> AutomationControlResolution
    private let isLoadingCurrentValueImplementation: (Int) -> Bool
    private let actionErrorImplementation: (Int) -> String?
    private let setControlValueImplementation:
        (Int, HBJSONValue) async throws -> Void
    private let useCurrentValueImplementation: (Int) async -> Void
    private let removeControlSetImplementation: (Int) -> Void
    private let setActionImplementation:
        (Int, HBJSONValue) async throws -> Void
    private let removeActionImplementation: (Int) -> Void

    init<Model: AutomationActionEditingModel>(
        action: SceneActionConfiguration,
        model: Model
    ) {
        self.action = action
        isBusy = model.isBusy
        canMutateStructure = model.canMutateStructure
        supportsGenericActionMutation = model.supportsGenericActionMutation
        controlResolutionImplementation = model.controlResolution
        isLoadingCurrentValueImplementation = model.isLoadingCurrentValue
        actionErrorImplementation = model.actionError
        setControlValueImplementation = model.setControlValue
        useCurrentValueImplementation = model.useCurrentValue
        removeControlSetImplementation = model.removeControlSet
        setActionImplementation = model.setAction
        removeActionImplementation = model.removeAction
    }

    func controlResolution(for actionIndex: Int) -> AutomationControlResolution {
        controlResolutionImplementation(actionIndex)
    }

    func isLoadingCurrentValue(actionIndex: Int) -> Bool {
        isLoadingCurrentValueImplementation(actionIndex)
    }

    func actionError(for actionIndex: Int) -> String? {
        actionErrorImplementation(actionIndex)
    }

    func setControlValue(
        actionIndex: Int,
        value: HBJSONValue
    ) async throws {
        try await setControlValueImplementation(actionIndex, value)
    }

    func useCurrentValue(actionIndex: Int) async {
        await useCurrentValueImplementation(actionIndex)
    }

    func removeControlSet(actionIndex: Int) {
        removeControlSetImplementation(actionIndex)
    }

    func setAction(rawValue: HBJSONValue) async throws {
        try await setActionImplementation(action.index, rawValue)
    }

    func removeAction() {
        removeActionImplementation(action.index)
    }
}

struct AnyAutomationControlRepository: AutomationControlRepository {
    private let editableDeviceCatalogImplementation:
        @Sendable () async throws -> SceneConfigurationDeviceCatalog

    init<Repository: AutomationControlRepository>(_ repository: Repository) {
        editableDeviceCatalogImplementation = repository.editableDeviceCatalog
    }

    func editableDeviceCatalog() async throws
        -> SceneConfigurationDeviceCatalog
    {
        try await editableDeviceCatalogImplementation()
    }
}

@MainActor
struct AutomationActionCreationOperations {
    let controlRepository: AnyAutomationControlRepository
    let excludedControlPaths: Set<String>
    let configurationKind: String

    // These callbacks mutate editor models. Preserve their actor contract
    // through type erasure so Swift does not synthesize an `Actor?` argument
    // reabstraction thunk between the picker and the model.
    private let addControlSetImplementation: @MainActor @Sendable (
        String,
        HBControlDescriptor,
        SceneControlSetValueSource
    ) async throws -> Int
    private let appendActionImplementation:
        @MainActor @Sendable (HBJSONValue) async throws -> Int

    init<Repository: AutomationControlRepository>(
        controlRepository: Repository,
        excludedControlPaths: Set<String>,
        configurationKind: String,
        addControlSet: @escaping @MainActor @Sendable (
            String,
            HBControlDescriptor,
            SceneControlSetValueSource
        ) async throws -> Int,
        appendAction: @escaping @MainActor @Sendable (
            HBJSONValue
        ) async throws -> Int
    ) {
        self.controlRepository = AnyAutomationControlRepository(
            controlRepository
        )
        self.excludedControlPaths = excludedControlPaths
        self.configurationKind = configurationKind
        addControlSetImplementation = addControlSet
        appendActionImplementation = appendAction
    }

    func addControlSet(
        deviceAddressableName: String,
        control: HBControlDescriptor,
        valueSource: SceneControlSetValueSource
    ) async throws -> Int {
        try await addControlSetImplementation(
            deviceAddressableName,
            control,
            valueSource
        )
    }

    func appendAction(_ rawValue: HBJSONValue) async throws -> Int {
        try await appendActionImplementation(rawValue)
    }
}

@MainActor
protocol AutomationActionPresentationPlugin {
    var identifier: String { get }
    var actionType: String? { get }
    var displayName: String { get }
    var systemImage: String { get }
    var applicability: AutomationActionApplicability { get }

    func presentation(
        for action: SceneActionConfiguration
    ) -> AutomationActionPluginPresentation

    func supports(
        action: SceneActionConfiguration,
        in context: AutomationActionConfigurationContext
    ) -> Bool
}

extension AutomationActionPresentationPlugin {
    func presentation(
        for action: SceneActionConfiguration
    ) -> AutomationActionPluginPresentation {
        AutomationActionPluginPresentation(
            title: displayName,
            detail: action.payload?.compactConfigurationJSON
                ?? action.rawValue.compactConfigurationJSON
        )
    }

    func supports(
        action _: SceneActionConfiguration,
        in context: AutomationActionConfigurationContext
    ) -> Bool {
        applicability.supports(context)
    }
}

@MainActor
protocol AutomationActionEditingPlugin: AutomationActionPresentationPlugin {
    associatedtype Rows: View

    func canRemove(context: AutomationActionPresentationContext) -> Bool
    func remove(context: AutomationActionPresentationContext)

    @ViewBuilder
    func makeRows(context: AutomationActionPresentationContext) -> Rows

}

@MainActor
protocol AutomationActionCreationPlugin: AutomationActionPresentationPlugin {
    associatedtype CreationView: View

    @ViewBuilder
    func makeCreationView(
        operations: AutomationActionCreationOperations
    ) -> CreationView
}

@MainActor
struct AnyAutomationActionTypePlugin: Identifiable {
    let identifier: String
    let actionType: String?
    let displayName: String
    let systemImage: String
    let applicability: AutomationActionApplicability
    let capabilities: AutomationActionUICapabilities

    var id: String { identifier }

    private let canRemoveImplementation:
        ((AutomationActionPresentationContext) -> Bool)?
    private let presentationImplementation:
        (SceneActionConfiguration) -> AutomationActionPluginPresentation
    private let supportsImplementation: (
        SceneActionConfiguration,
        AutomationActionConfigurationContext
    ) -> Bool
    private let removeImplementation:
        ((AutomationActionPresentationContext) -> Void)?
    private let makeRowsImplementation:
        ((AutomationActionPresentationContext) -> AnyView)?
    private let makeCreationViewImplementation:
        ((AutomationActionCreationOperations) -> AnyView)?

    private init<Plugin: AutomationActionPresentationPlugin>(
        presentation plugin: Plugin,
        capabilities: AutomationActionUICapabilities,
        canRemove: ((AutomationActionPresentationContext) -> Bool)?,
        remove: ((AutomationActionPresentationContext) -> Void)?,
        makeRows: ((AutomationActionPresentationContext) -> AnyView)?,
        makeCreationView: ((AutomationActionCreationOperations) -> AnyView)?
    ) {
        identifier = plugin.identifier
        actionType = plugin.actionType
        displayName = plugin.displayName
        systemImage = plugin.systemImage
        applicability = plugin.applicability
        self.capabilities = capabilities
        presentationImplementation = plugin.presentation
        supportsImplementation = plugin.supports
        canRemoveImplementation = canRemove
        removeImplementation = remove
        makeRowsImplementation = makeRows
        makeCreationViewImplementation = makeCreationView
    }

    /// Registers a complete module with dedicated presentation, editing, and
    /// creation UI.
    static func full<Plugin>(_ plugin: Plugin) -> Self
        where Plugin: AutomationActionEditingPlugin,
              Plugin: AutomationActionCreationPlugin
    {
        Self(
            presentation: plugin,
            capabilities: [.presentation, .editing, .creation],
            canRemove: plugin.canRemove,
            remove: plugin.remove,
            makeRows: { context in
                AnyView(plugin.makeRows(context: context))
            },
            makeCreationView: { operations in
                AnyView(plugin.makeCreationView(operations: operations))
            }
        )
    }

    /// Registers dedicated presentation and editing without advertising a New
    /// Action entry.
    static func editing<Plugin: AutomationActionEditingPlugin>(
        _ plugin: Plugin
    ) -> Self {
        Self(
            presentation: plugin,
            capabilities: [.presentation, .editing],
            canRemove: plugin.canRemove,
            remove: plugin.remove,
            makeRows: { context in
                AnyView(plugin.makeRows(context: context))
            },
            makeCreationView: nil
        )
    }

    /// Registers a purpose-built creator whose existing values continue to use
    /// the generic lossless JSON editor.
    static func creation<Plugin: AutomationActionCreationPlugin>(
        _ plugin: Plugin
    ) -> Self {
        Self(
            presentation: plugin,
            capabilities: [.presentation, .creation],
            canRemove: nil,
            remove: nil,
            makeRows: nil,
            makeCreationView: { operations in
                AnyView(plugin.makeCreationView(operations: operations))
            }
        )
    }

    /// Registers a readable action whose configuration is still edited using
    /// the lossless raw-JSON path. It intentionally has no creation UI.
    static func presentation<Plugin: AutomationActionPresentationPlugin>(
        _ plugin: Plugin
    ) -> Self {
        Self(
            presentation: plugin,
            capabilities: [.presentation],
            canRemove: nil,
            remove: nil,
            makeRows: nil,
            makeCreationView: nil
        )
    }

    func canRemove(context: AutomationActionPresentationContext) -> Bool {
        if let canRemoveImplementation {
            return canRemoveImplementation(context)
        }
        return context.canMutateStructure
            && context.supportsGenericActionMutation
    }

    func presentation(
        for action: SceneActionConfiguration
    ) -> AutomationActionPluginPresentation {
        presentationImplementation(action)
    }

    func supports(
        action: SceneActionConfiguration,
        in context: AutomationActionConfigurationContext
    ) -> Bool {
        supportsImplementation(action, context)
    }

    func remove(context: AutomationActionPresentationContext) {
        if let removeImplementation {
            removeImplementation(context)
        } else {
            context.removeAction()
        }
    }

    func makeRows(
        context: AutomationActionPresentationContext
    ) -> AnyView? {
        makeRowsImplementation?(context)
    }

    func makeCreationView(
        operations: AutomationActionCreationOperations
    ) -> AnyView {
        precondition(
            capabilities.contains(.creation),
            "Only creation-capable action modules can make creation views."
        )
        return makeCreationViewImplementation!(operations)
    }
}

@MainActor
struct AutomationActionTypeRegistry {
    struct Resolution {
        let plugin: AnyAutomationActionTypePlugin
        let isFallback: Bool
    }

    let plugins: [AnyAutomationActionTypePlugin]
    let fallback: AnyAutomationActionTypePlugin

    init(
        plugins: [AnyAutomationActionTypePlugin],
        fallback: AnyAutomationActionTypePlugin
    ) {
        let identifiers = plugins.map(\.identifier) + [fallback.identifier]
        precondition(
            Set(identifiers).count == identifiers.count,
            "Automation-action plugin identifiers must be unique."
        )
        let actionTypes = plugins.compactMap(\.actionType)
        precondition(
            Set(actionTypes).count == actionTypes.count,
            "Automation-action plugin types must be unique."
        )
        precondition(
            fallback.actionType == nil,
            "The automation-action fallback must not claim an action type."
        )
        self.plugins = plugins
        self.fallback = fallback
    }

    func resolve(_ action: SceneActionConfiguration) -> Resolution {
        guard let type = action.type,
              let plugin = plugins.first(where: { $0.actionType == type }) else {
            return Resolution(plugin: fallback, isFallback: true)
        }
        return Resolution(plugin: plugin, isFallback: false)
    }

    func creationPlugins(
        for context: AutomationActionConfigurationContext
    ) -> [AnyAutomationActionTypePlugin] {
        (plugins + [fallback]).filter {
            $0.capabilities.contains(.creation)
                && $0.applicability.supports(context)
        }
    }
}
