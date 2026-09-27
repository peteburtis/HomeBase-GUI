#if os(iOS)
import Combine
import SwiftUI
import UIKit

/// Owned by the phone's camera viewer. A connected window may retain its
/// already-authorized media, but cannot unlock cameras or create a new grant.
@MainActor
final class CameraExternalDisplayPresentation: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private(set) var group: CameraGroupPlayback? {
        didSet { if oldValue !== group { notifyPresentationChanged() } }
    }
    private(set) var isVisible = false {
        didSet { if oldValue != isVisible { notifyPresentationChanged() } }
    }
    private(set) var hasConnectedOutput = false {
        didSet { if oldValue != hasConnectedOutput { notifyPresentationChanged() } }
    }
    var isOutputActive: Bool { isVisible && hasConnectedOutput }
    private weak var lifecycle: CameraAccessLifecycle?
    private var authorizationObservation: AnyCancellable?
    private let owner = UUID()
    private var connectedOutputs: Set<UUID> = []
    private var requestedVisibility = false
    private var isRetaining = false
    private var notificationPending = false

    private func notifyPresentationChanged() {
        // UIKit can attach/dismantle the bridge during a SwiftUI update. Apply
        // security/resource changes synchronously, but coalesce UI invalidation
        // onto the next turn rather than publishing back into that update.
        guard !notificationPending else { return }
        notificationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notificationPending = false
            self.objectWillChange.send()
        }
    }

    // Cleanup is explicit in clear(); UIKit may release this outside a Swift
    // task, so value destruction must not require an executor hop on iOS 26.
    nonisolated deinit {}

    func update(group: CameraGroupPlayback, isVisible: Bool,
                lifecycle: CameraAccessLifecycle? = nil) {
        if self.group !== group || self.lifecycle !== lifecycle {
            releaseRetention()
            self.lifecycle = lifecycle
            authorizationObservation = lifecycle?.session.$isUnlocked.dropFirst().sink { [weak self] unlocked in
                guard !unlocked, let self else { return }
                self.releaseRetention()
                self.group?.suspend()
                self.group?.suspendResources(stopImmediately: true)
                self.group?.sessions.forEach { $0.playback.revokeCameraAccess() }
                self.isVisible = false
            }
        }
        if self.group !== group { self.group = group }
        requestedVisibility = isVisible
        reconcile()
    }

    func outputConnected(_ id: UUID) {
        connectedOutputs.insert(id)
        reconcile()
    }

    func outputDisconnected(_ id: UUID) {
        connectedOutputs.remove(id)
        reconcile()
    }

    private func reconcile() {
        if hasConnectedOutput != !connectedOutputs.isEmpty {
            hasConnectedOutput = !connectedOutputs.isEmpty
        }
        if !requestedVisibility || connectedOutputs.isEmpty { releaseRetention() }
        if requestedVisibility, !connectedOutputs.isEmpty, !isRetaining,
           let group, let lifecycle, lifecycle.externalDisplayStarted(owner: owner) {
            isRetaining = true
            group.setExternalDisplayActive(true, owner: owner, access: lifecycle.session)
        }
        let visible = requestedVisibility && (lifecycle == nil ||
            (lifecycle?.session.isUnlocked == true &&
             (lifecycle?.session.streamsSuspended == false || isRetaining)))
        if isVisible != visible { isVisible = visible }
    }

    private func releaseRetention() {
        guard isRetaining else { return }
        isRetaining = false
        if let lifecycle {
            group?.setExternalDisplayActive(false, owner: owner, access: lifecycle.session)
            lifecycle.externalDisplayStopped(owner: owner)
        }
    }

    func clear() {
        requestedVisibility = false
        releaseRetention()
        connectedOutputs.removeAll()
        hasConnectedOutput = false
        authorizationObservation = nil
        lifecycle = nil
        isVisible = false
        group = nil
    }
}

struct CameraExternalDisplayView: View {
    @ObservedObject var presentation: CameraExternalDisplayPresentation

    var body: some View {
        ZStack {
            Color.black
            if presentation.isVisible, let group = presentation.group {
                CameraGroupVideo(group: group, cameraControlsEnabled: false,
                    controlsVisible: true, isExternalDisplay: true,
                    onSingleTap: {})
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .preferredColorScheme(.dark)
    }
}

/// iOS 26 delivers the external scene before a viewer is open. Keep the scene
/// available and choose the most recently presented camera viewer, if any.
@MainActor
final class CameraExternalDisplayRouter: ObservableObject {
    static let shared = CameraExternalDisplayRouter()
    @Published private(set) var active: CameraExternalDisplayPresentation?
    private var viewers: [(UUID, CameraExternalDisplayPresentation)] = []

    nonisolated deinit {}

    func register(_ presentation: CameraExternalDisplayPresentation, id: UUID) {
        viewers.removeAll { $0.0 == id }
        viewers.append((id, presentation))
        active = presentation
    }

    func unregister(_ id: UUID) {
        viewers.removeAll { $0.0 == id }
        active = viewers.last?.1
    }
}

/// UIKit supplies this scene for AirPlay displays and wired displays. iOS 27
/// uses a scene accessory; iOS 26 uses the application's scene configuration.
@MainActor
final class CameraExternalDisplaySceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    private weak var externalScene: UIWindowScene?
    private var observation: AnyCancellable?
    private let outputID = UUID()
    private var presentation: CameraExternalDisplayPresentation?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard session.role == .windowExternalDisplayNonInteractive,
              let scene = scene as? UIWindowScene else { return }
        externalScene = scene
        if #available(iOS 27.0, *),
           let presentation = connectionOptions.sceneAccessoryUserInfo as? CameraExternalDisplayPresentation {
            show(presentation)
        } else {
            observation = CameraExternalDisplayRouter.shared.$active.sink { [weak self] presentation in
                self?.show(presentation)
            }
        }
    }

    private func show(_ presentation: CameraExternalDisplayPresentation?) {
        guard let scene = externalScene else { return }
        guard let presentation else {
            releaseWindow()
            return
        }
        if self.presentation !== presentation {
            self.presentation?.outputDisconnected(outputID)
            self.presentation = presentation
            presentation.outputConnected(outputID)
        }
        let window = self.window ?? UIWindow(windowScene: scene)
        window.backgroundColor = .black
        window.rootViewController = UIHostingController(
            rootView: CameraExternalDisplayView(presentation: presentation))
        window.isHidden = false
        // The phone remains the key window and keeps all input/controls.
        self.window = window
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        observation = nil
        releaseWindow()
        externalScene = nil
    }

    private func releaseWindow() {
        presentation?.outputDisconnected(outputID)
        presentation = nil
        window?.isHidden = true
        window?.rootViewController = nil
        window?.windowScene = nil
        window = nil
    }
}

@MainActor
final class CameraExternalDisplayAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Return a fresh configuration: returning the primary session's
        // SwiftUI delegate makes the adaptor recursively wrap that delegate.
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            configuration.sceneClass = UIWindowScene.self
            configuration.delegateClass = CameraExternalDisplaySceneDelegate.self
        }
        return configuration
    }
}

struct CameraExternalDisplayBridge: UIViewControllerRepresentable {
    @Environment(\.cameraAccessLifecycle) private var lifecycle
    let group: CameraGroupPlayback
    let isVisible: Bool
    let presentation: CameraExternalDisplayPresentation
    var retainWhenCovered = false

    func makeUIViewController(context: Context) -> CameraExternalDisplayViewController {
        CameraExternalDisplayViewController(presentation: presentation)
    }

    func updateUIViewController(_ controller: CameraExternalDisplayViewController, context: Context) {
        controller.retainWhenCovered = retainWhenCovered
        controller.update(group: group, isVisible: isVisible, lifecycle: lifecycle)
    }

    static func dismantleUIViewController(_ controller: CameraExternalDisplayViewController, coordinator: ()) {
        controller.stopPresenting()
    }
}

@MainActor
final class CameraExternalDisplayViewController: UIViewController {
    let presentation: CameraExternalDisplayPresentation
    private let id = UUID()
    private var isPresenting = false
    var retainWhenCovered = false
    private weak var group: CameraGroupPlayback?
    private var isVisible = false
    private weak var lifecycle: CameraAccessLifecycle?
    // Stored as AnyObject to keep the iOS 26 deployment path available.
    private var accessoryRegistration: AnyObject?

    init(presentation: CameraExternalDisplayPresentation? = nil) {
        self.presentation = presentation ?? CameraExternalDisplayPresentation()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isPresenting else { return }
        isPresenting = true
        refreshPresentation()
        if #available(iOS 27.0, *) {
            let configuration = UISceneConfiguration()
            configuration.delegateClass = CameraExternalDisplaySceneDelegate.self
            accessoryRegistration = registerSceneAccessory(.externalNonInteractive(
                sceneConfiguration: configuration, userInfo: presentation))
        } else {
            CameraExternalDisplayRouter.shared.register(presentation, id: id)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // A retained viewer can be underneath another phone presentation while
        // its accessory still belongs to this scene. Removal is always cleaned
        // up by dismantleUIViewController, independently of appearance callbacks.
        if !retainWhenCovered { stopPresenting() }
    }

    func update(group: CameraGroupPlayback, isVisible: Bool,
                lifecycle: CameraAccessLifecycle? = nil) {
        self.group = group
        self.isVisible = isVisible
        self.lifecycle = lifecycle
        refreshPresentation()
    }

    private func refreshPresentation() {
        guard isPresenting, let group else { return }
        presentation.update(group: group, isVisible: isVisible, lifecycle: lifecycle)
    }

    func stopPresenting() {
        if #available(iOS 27.0, *), let registration = accessoryRegistration as? UISceneAccessoryRegistration {
            unregisterSceneAccessory(registration)
        }
        accessoryRegistration = nil
        if isPresenting { CameraExternalDisplayRouter.shared.unregister(id) }
        isPresenting = false
        presentation.clear()
    }
}
#endif
