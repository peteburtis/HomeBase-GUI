#if os(iOS)
import AVKit
import Combine
import HomeBaseProtocol
import MediaPlayer
import SwiftUI

enum CameraPiPAudioPolicy: Equatable {
    case silentVideo
    case audibleVideo

    var options: AVAudioSession.CategoryOptions {
        // Keep this separate from PiP ownership so adding camera audio does not
        // change authorization or restoration. Audible playback can take focus.
        self == .silentVideo ? [.mixWithOthers] : []
    }
}

enum CameraPiPMenuAction: Equatable {
    case start, startLive, swap, stop

    init(isSource: Bool, isActive: Bool, isLive: Bool) {
        self = isSource ? .stop : isActive ? .swap : isLive ? .start : .startLive
    }

    var title: String {
        switch self {
        case .start: "Picture in Picture"
        case .startLive: "Start Live Picture in Picture"
        case .swap: "Swap Picture in Picture"
        case .stop: "Stop Picture in Picture"
        }
    }

    var systemImage: String {
        switch self {
        case .start, .startLive: "pip.enter"
        case .swap: "arrow.triangle.swap"
        case .stop: "pip.exit"
        }
    }
}

struct CameraPiPRestorationPlan: Equatable {
    let viewerID: UUID
    let opensNewViewer: Bool

    init(origin: UUID, cameraID: String, viewers: [UUID: Set<String>]) {
        if viewers[origin]?.contains(cameraID) == true {
            viewerID = origin
            opensNewViewer = false
        } else {
            viewerID = UUID()
            opensNewViewer = true
        }
    }
}

@MainActor
struct CameraPiPViewerRegistry {
    enum Registration: Equatable { case updated, resumesInlinePlayback }

    private struct Viewer {
        weak var owner: AnyObject?
        let cameras: Set<String>
    }
    private var viewers: [UUID: Viewer] = [:]

    var available: [UUID: Set<String>] {
        viewers.compactMapValues { $0.owner == nil ? nil : $0.cameras }
    }

    mutating func register(_ id: UUID, cameras: Set<String>, owner: AnyObject,
                           pictureInPictureCameraID: String?, restoringViewerID: UUID?) -> Registration {
        viewers = viewers.filter { $0.value.owner != nil }
        let previousCameras = viewers[id]?.cameras
        viewers[id] = Viewer(owner: owner, cameras: cameras)
        guard let cameraID = pictureInPictureCameraID,
              cameras.contains(cameraID), previousCameras?.contains(cameraID) != true,
              restoringViewerID != id else { return .updated }
        // Opening the same camera again means returning it to inline playback.
        // Reappearing in the original, still-registered viewer (e.g. after a
        // sheet or foregrounding) is not another open. A native restoration
        // also handles its own PiP stop and must keep its completion callback.
        return .resumesInlinePlayback
    }

    mutating func unregister(_ id: UUID) { viewers.removeValue(forKey: id) }
}

@MainActor
final class CameraPiPSession: Identifiable {
    let id = UUID()
    let camera: CameraVideoDevice
    let quality: CameraLiveQualitySelection
    let client: HomeBaseWebSocketClient
    let originViewerID: UUID
    let authorization: CameraStreamAuthorization
    let model: CameraLiveVideoModel

    init(camera: CameraVideoDevice, quality: CameraLiveQualitySelection,
         client: HomeBaseWebSocketClient, originViewerID: UUID,
         authorization: CameraStreamAuthorization) {
        self.camera = camera; self.quality = quality; self.client = client
        self.originViewerID = originViewerID; self.authorization = authorization
        // Deliberately no history controller, replay buffer, S3 credentials,
        // camera controls, or recording controller. PiP is always live video.
        model = CameraLiveVideoModel(deviceIdentifier: camera.device.addressableName,
            quality: quality, client: client)
    }
}

struct CameraPiPPanePresentation: Equatable {
    let keepsSourceMounted: Bool
    let sourceCoversContent: Bool

    init(attached: Bool, isLive: Bool) {
        keepsSourceMounted = attached
        sourceCoversContent = attached && isLive
    }
}

struct CameraPiPSourceLayer<Content: View, Source: View>: View {
    let presentation: CameraPiPPanePresentation
    let content: Content
    let source: Source
    let sourceDidAppear: () -> Void
    let sourceDidDisappear: () -> Void

    init(presentation: CameraPiPPanePresentation,
         sourceDidAppear: @escaping () -> Void,
         sourceDidDisappear: @escaping () -> Void,
         @ViewBuilder content: () -> Content,
         @ViewBuilder source: () -> Source) {
        self.presentation = presentation
        self.sourceDidAppear = sourceDidAppear
        self.sourceDidDisappear = sourceDidDisappear
        self.content = content()
        self.source = source()
    }

    var body: some View {
        ZStack {
            content
                .zIndex(presentation.sourceCoversContent ? 0 : 1)
            if presentation.keepsSourceMounted {
                source
                    .zIndex(presentation.sourceCoversContent ? 1 : 0)
                    .accessibilityHidden(!presentation.sourceCoversContent)
                    .onAppear(perform: sourceDidAppear)
                    .onDisappear(perform: sourceDidDisappear)
            }
        }
    }
}

@MainActor
final class CameraPictureInPictureController: NSObject, ObservableObject {
    enum Phase: Equatable {
        case stopped, preparing, starting, active, stopping
        var mayContinueInBackground: Bool { self == .active }
    }
    struct Restoration: Identifiable {
        let id = UUID()
        let session: CameraPiPSession
        let plan: CameraPiPRestorationPlan
    }

    @Published private(set) var session: CameraPiPSession?
    @Published private(set) var pendingSwap: CameraPiPSession?
    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var isPaused = false
    @Published private(set) var restoration: Restoration?
    @Published var reopenedViewer: Restoration?
    @Published var errorMessage: String?
    private(set) var audioPolicy: CameraPiPAudioPolicy = .silentVideo
    private var controller: AVPictureInPictureController?
    private var startTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var swapTask: Task<Void, Never>?
    private var swapStreamTask: Task<Void, Never>?
    private var swapSourceIsAttached = false
    private var restorationTask: Task<Void, Never>?
    private var restorationCompletion: ((Bool) -> Void)?
    private var viewers = CameraPiPViewerRegistry()
    var availableViewers: [UUID: Set<String>] {
        viewers.available
    }
    private var remoteCommands: [(MPRemoteCommand, Any)] = []
    private var notifications: Set<AnyCancellable> = []
    private var ownsAudioSession = false
    private var sourceIsAttached = false
    private var appIsBackgrounded = false
    private weak var accessLifecycle: CameraAccessLifecycle?

    init(accessLifecycle: CameraAccessLifecycle? = nil) {
        self.accessLifecycle = accessLifecycle
        super.init()
        NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated {
                self?.accessLifecycle?.protectedDataWillBecomeUnavailable()
                self?.stop()
            } }
            .store(in: &notifications)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      type == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor [weak self] in self?.stop() }
            }.store(in: &notifications)
    }

    static func nowPlayingMetadata(cameraName: String) -> [String: Any] {
        // No artwork, snapshots, URLs, camera identifiers, recording dates, or
        // archived imagery may escape into system metadata/cache surfaces.
        [MPMediaItemPropertyTitle: cameraName]
    }

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    var canStartOrSwap: Bool {
        (phase == .stopped || phase == .active) && pendingSwap == nil && restoration == nil
    }

    func start(camera: CameraVideoDevice, quality: CameraLiveQualitySelection,
               client: HomeBaseWebSocketClient, viewerID: UUID, access: CameraAccessSession) {
        guard isSupported, !appIsBackgrounded, UIApplication.shared.applicationState == .active,
              UIApplication.shared.isProtectedDataAvailable, access.isUnlocked,
              availableViewers[viewerID]?.contains(camera.id) == true,
              camera.artificialFeed == nil, canStartOrSwap else { return }
        if session != nil {
            prepareSwap(camera: camera, quality: quality, client: client,
                viewerID: viewerID, access: access)
            return
        }
        do {
            let authorization = try access.authorizePictureInPicture(camera: camera.device.addressableName)
            let session = CameraPiPSession(camera: camera, quality: quality, client: client,
                originViewerID: viewerID, authorization: authorization)
            self.session = session
            phase = .preparing; isPaused = false; errorMessage = nil
            sourceIsAttached = false
            let controller = makeNativeController(renderer: session.model.renderer)
            self.controller = controller
            try configureAudioSession(policy: audioPolicy)
            streamTask = runStream(session)
            // This bounded attempt originates only in the menu action. Neither
            // foregrounding nor a later readiness change can start PiP by itself.
            startTask = Task { [weak self, weak access] in
                for _ in 0..<400 {
                    guard !Task.isCancelled, let self, self.session?.id == session.id else { return }
                    guard !self.appIsBackgrounded, access?.isUnlocked == true else {
                        self.stop(); return
                    }
                    if self.phase == .preparing, self.sourceIsAttached, session.model.state == .playing,
                       controller.isPictureInPicturePossible {
                        guard UIApplication.shared.applicationState == .active else {
                            self.stop(); return
                        }
                        self.phase = .starting
                        controller.startPictureInPicture()
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                self?.fail("Picture in Picture is not available right now. Please try again.")
            }
        } catch {
            fail("Picture in Picture could not start. Please try again.")
        }
    }

    private func runStream(_ source: CameraPiPSession) -> Task<Void, Never> {
        Task { [weak self] in
            await source.model.run(authorization: source.authorization)
            guard !Task.isCancelled, let self else { return }
            if self.pendingSwap?.id == source.id {
                self.cancelSwap()
                self.errorMessage = "The new camera could not load. Picture in Picture is still showing the previous camera."
            } else if self.session?.id == source.id {
                // The PiP window disappearing is sufficient feedback. Do not
                // queue an alert that only surfaces when a viewer reopens.
                self.stop()
            }
        }
    }

    private func prepareSwap(camera: CameraVideoDevice, quality: CameraLiveQualitySelection,
                             client: HomeBaseWebSocketClient, viewerID: UUID, access: CameraAccessSession) {
        guard phase == .active, controller?.isPictureInPictureActive == true else { return }
        do {
            let authorization = try access.authorizePictureInPicture(camera: camera.device.addressableName)
            let replacement = CameraPiPSession(camera: camera, quality: quality, client: client,
                originViewerID: viewerID, authorization: authorization)
            pendingSwap = replacement
            swapSourceIsAttached = false
            errorMessage = nil
            swapStreamTask = runStream(replacement)
            swapTask = Task { [weak self, weak access] in
                for _ in 0..<400 {
                    guard !Task.isCancelled, let self, self.pendingSwap?.id == replacement.id else { return }
                    guard !self.appIsBackgrounded, access?.isUnlocked == true,
                          replacement.authorization.isValid,
                          self.availableViewers[viewerID]?.contains(camera.id) == true else {
                        self.cancelSwap(); return
                    }
                    // AVKit allows contentSource changes while active, but
                    // stops PiP if the new layer isn't ready for display.
                    // A received packet (.playing) alone is not sufficient.
                    if UIApplication.shared.applicationState == .active,
                       self.swapSourceIsAttached, replacement.model.renderer.layer.isReadyForDisplay {
                        self.commitSwap(replacement)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard let self, self.pendingSwap?.id == replacement.id else { return }
                self.cancelSwap()
                self.errorMessage = "The new camera did not become ready. Picture in Picture is still showing the previous camera."
            }
        } catch {
            errorMessage = "Picture in Picture could not switch cameras. Please try again."
        }
    }

    private func commitSwap(_ replacement: CameraPiPSession) {
        guard pendingSwap?.id == replacement.id, phase == .active,
              let controller, controller.isPictureInPictureActive, let previous = session else {
            cancelSwap(); return
        }
        let previousStreamTask = streamTask
        // Publish the new ownership before AVKit asks its playback delegate
        // about the source. Retain the old lease/layer until the native handoff.
        session = replacement
        streamTask = swapStreamTask; swapStreamTask = nil
        sourceIsAttached = swapSourceIsAttached
        isPaused = false
        controller.contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: replacement.model.renderer.layer, playbackDelegate: self)
        // No stop/start, audio-session reset, or authorization-lifecycle gap.
        // AVKit owns the window transition; we don't snapshot either camera.
        pendingSwap = nil; swapSourceIsAttached = false
        swapTask?.cancel(); swapTask = nil
        previous.authorization.invalidate()
        previousStreamTask?.cancel()
        previous.model.renderer.reset()
        Task { await previous.model.stop(immediately: true) }
        guard session?.id == replacement.id, phase == .active else { return }
        clearNowPlaying()
        publishNowPlaying()
        controller.invalidatePlaybackState()
    }

    private func cancelSwap() {
        swapTask?.cancel(); swapTask = nil
        swapStreamTask?.cancel(); swapStreamTask = nil
        if let replacement = pendingSwap {
            replacement.authorization.invalidate()
            replacement.model.renderer.reset()
            Task { await replacement.model.stop(immediately: true) }
        }
        pendingSwap = nil; swapSourceIsAttached = false
    }

    func makeNativeController(renderer: CameraH264Renderer) -> AVPictureInPictureController {
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: renderer.layer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.requiresLinearPlayback = true
        controller.delegate = self
        return controller
    }

    func sourceAttachmentChanged(sessionID: UUID, attached: Bool) {
        if pendingSwap?.id == sessionID {
            swapSourceIsAttached = attached
            if !attached { cancelSwap() }
            return
        }
        guard session?.id == sessionID else { return }
        sourceIsAttached = attached
        if !attached, phase == .preparing { stop() }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        appIsBackgrounded = phase == .background
        // A replacement is foreground preparation, not a second background
        // camera grant. Keep only the already-active source when leaving.
        if appIsBackgrounded { cancelSwap() }
        // No automatic PiP, including an outstanding preparation request when
        // the user leaves the app before the system has actually started PiP.
        if appIsBackgrounded, !self.phase.mayContinueInBackground { stop() }
    }

    func configureAudioSession(policy: CameraPiPAudioPolicy) throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .moviePlayback, options: policy.options)
        try audio.setActive(true)
        audioPolicy = policy
        ownsAudioSession = true
        controller?.invalidatePlaybackState()
    }

    func setPlaying(_ playing: Bool) {
        guard phase == .active, let session else { return }
        applySystemPlaybackState(playing: playing, renderer: session.model.renderer) {
            controller?.invalidatePlaybackState()
        }
    }

    func applySystemPlaybackState(playing: Bool, renderer: CameraH264Renderer,
                                  invalidate: () -> Void) {
        isPaused = !playing
        // Pausing freezes PiP without changing playback mode. The independent
        // stream keeps decoding, so Play resumes at the current live edge.
        renderer.suppressesDisplay = !playing
        invalidate()
    }

    func stop() {
        completeRestoration(false)
        accessLifecycle?.pictureInPictureStopped()
        cancelSwap()
        startTask?.cancel(); startTask = nil
        session?.authorization.invalidate()
        session?.model.renderer.reset()
        streamTask?.cancel(); streamTask = nil
        if let model = session?.model { Task { await model.stop(immediately: true) } }
        clearNowPlaying()
        if let controller, controller.isPictureInPictureActive || phase == .starting {
            phase = .stopping
            controller.stopPictureInPicture()
            stopTask?.cancel()
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.controller === controller,
                      self.phase == .stopping else { return }
                self.finishStop()
            }
        } else { finishStop() }
    }

    func reset() {
        reopenedViewer = nil
        stop()
    }

    private func fail(_ message: String) { errorMessage = message; stop() }

    private func finishStop() {
        cancelSwap()
        stopTask?.cancel(); stopTask = nil
        startTask?.cancel(); startTask = nil
        session?.authorization.invalidate()
        session?.model.renderer.reset()
        streamTask?.cancel(); streamTask = nil
        if let model = session?.model { Task { await model.stop(immediately: true) } }
        controller?.delegate = nil; controller = nil
        session = nil; phase = .stopped; isPaused = false; sourceIsAttached = false
        clearNowPlaying()
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
        completeRestoration(false)
        accessLifecycle?.pictureInPictureStopped()
    }

    private func publishNowPlaying() {
        guard let session else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = Self.nowPlayingMetadata(cameraName: session.camera.device.displayName)
        let commands = MPRemoteCommandCenter.shared()
        for (command, playing) in [(commands.playCommand, true), (commands.pauseCommand, false)] {
            command.isEnabled = true
            let token = command.addTarget { [weak self] _ in
                Task { @MainActor in self?.setPlaying(playing) }
                return .success
            }
            remoteCommands.append((command, token))
        }
        commands.togglePlayPauseCommand.isEnabled = true
        let token = commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.setPlaying(self.isPaused) }
            return .success
        }
        remoteCommands.append((commands.togglePlayPauseCommand, token))
    }

    private func clearNowPlaying() {
        for (command, token) in remoteCommands { command.removeTarget(token); command.isEnabled = false }
        if !remoteCommands.isEmpty { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
        remoteCommands.removeAll()
    }

    func registerViewer(_ id: UUID, cameras: Set<String>, owner: AnyObject) {
        let registration = viewers.register(id, cameras: cameras, owner: owner,
            pictureInPictureCameraID: session?.camera.id,
            restoringViewerID: restoration?.plan.viewerID)
        if registration == .resumesInlinePlayback {
            // onAppear and the new camera access scope can arrive in either
            // order. Use the existing bounded restoration hold while stopping
            // PiP so the inline stream never loses its retained authorization.
            completeRestoration(false)
            accessLifecycle?.pictureInPictureWillRestore()
            stop()
            accessLifecycle?.pictureInPictureRestorationCompleted(true)
        }
    }

    func unregisterViewer(_ id: UUID) {
        // SwiftUI may retain a dismissed cover's StateObjects. Model lifetime
        // is a fallback, not proof that the viewer is still presented.
        viewers.unregister(id)
        if pendingSwap?.originViewerID == id { cancelSwap() }
    }

    func viewerDidRestore(_ id: UUID) {
        guard restoration?.plan.viewerID == id else { return }
        completeRestoration(true)
    }

    private func completeRestoration(_ success: Bool) {
        restorationTask?.cancel(); restorationTask = nil
        let completion = restorationCompletion
        restorationCompletion = nil; restoration = nil
        if completion != nil { accessLifecycle?.pictureInPictureRestorationCompleted(success) }
        completion?(success)
    }
}

extension CameraPictureInPictureController: AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController, phase == .starting,
              session?.authorization.isValid == true else {
            pictureInPictureController.stopPictureInPicture(); return
        }
        phase = .active
        accessLifecycle?.pictureInPictureStarted()
        startTask?.cancel(); startTask = nil
        publishNowPlaying()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        guard controller === pictureInPictureController else { return }
        errorMessage = "Picture in Picture could not start. Please try again."
        finishStop()
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        // The system's close/full-screen animation can precede didStop by
        // several frames. Never commit a prepared swap into that transition.
        cancelSwap()
        phase = .stopping
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        finishStop()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard controller === pictureInPictureController, let session,
              session.authorization.isValid, UIApplication.shared.isProtectedDataAvailable else {
            completionHandler(false); return
        }
        cancelSwap()
        completeRestoration(false)
        accessLifecycle?.pictureInPictureWillRestore()
        let plan = CameraPiPRestorationPlan(origin: session.originViewerID,
            cameraID: session.camera.id, viewers: availableViewers)
        let request = Restoration(session: session, plan: plan)
        restorationCompletion = completionHandler
        restoration = request
        if plan.opensNewViewer { reopenedViewer = request }
        restorationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.completeRestoration(false)
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        guard controller === pictureInPictureController else { return }
        setPlaying(playing)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { isPaused }
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        // PiP is deliberately live-only and linear.
        completionHandler()
    }
    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        audioPolicy == .silentVideo
    }
}

private struct CameraPiPEnvironmentKey: EnvironmentKey {
    static let defaultValue: CameraPictureInPictureController? = nil
}
private struct CameraPiPViewerIDKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}
extension EnvironmentValues {
    var cameraPictureInPicture: CameraPictureInPictureController? {
        get { self[CameraPiPEnvironmentKey.self] }
        set { self[CameraPiPEnvironmentKey.self] = newValue }
    }
    var cameraPiPViewerID: UUID? {
        get { self[CameraPiPViewerIDKey.self] }
        set { self[CameraPiPViewerIDKey.self] = newValue }
    }
}

struct CameraPictureInPictureHost: ViewModifier {
    @ObservedObject var controller: CameraPictureInPictureController

    func body(content: Content) -> some View {
        content
            .environment(\.cameraPictureInPicture, controller)
            .fullScreenCover(item: $controller.reopenedViewer) { request in
                CameraFullScreenLiveVideoView(device: request.session.camera.device,
                    quality: request.session.quality, client: request.session.client,
                    viewerID: request.plan.viewerID)
                    .environment(\.cameraPictureInPicture, controller)
                    .cameraAccessScope(isActive: true)
            }
    }
}

struct CameraPiPViewerRegistration: ViewModifier {
    @Environment(\.cameraPictureInPicture) private var controller
    let id: UUID
    let cameraIDs: Set<String>
    let owner: CameraScreenSelection
    let showControls: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let controller {
            content.modifier(ObservedCameraPiPViewerRegistration(controller: controller,
                id: id, cameraIDs: cameraIDs, owner: owner, showControls: showControls))
        } else { content }
    }
}

private struct ObservedCameraPiPViewerRegistration: ViewModifier {
    @ObservedObject var controller: CameraPictureInPictureController
    let id: UUID
    let cameraIDs: Set<String>
    let owner: CameraScreenSelection
    let showControls: () -> Void

    func body(content: Content) -> some View {
        content.environment(\.cameraPiPViewerID, id)
            .onAppear { controller.registerViewer(id, cameras: cameraIDs, owner: owner); restoreIfNeeded() }
            .onChange(of: cameraIDs) { _, ids in controller.registerViewer(id, cameras: ids, owner: owner) }
            .onChange(of: controller.restoration?.id) { _, _ in restoreIfNeeded() }
            // A covering sheet can disappear this view without closing the
            // viewer. Track the stable screen model's lifetime weakly instead.
            .alert("Picture in Picture", isPresented: Binding(
                get: { controller.errorMessage != nil },
                set: { if !$0 { controller.errorMessage = nil } }
            )) { Button("OK") { controller.errorMessage = nil } }
            message: { Text(controller.errorMessage ?? "") }
    }

    private func restoreIfNeeded() {
        guard controller.availableViewers[id] != nil,
              controller.restoration?.plan.viewerID == id else { return }
        showControls()
        // Active PiP retains the existing access session through this handoff.
        // The normal gate still applies if that authorization was revoked.
        controller.viewerDidRestore(id)
    }
}

struct CameraPiPPane: ViewModifier {
    @Environment(\.cameraPictureInPicture) private var controller
    @Environment(\.cameraPiPViewerID) private var viewerID
    let session: CameraGroupSession
    let alignment: Alignment
    let isLive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if let controller, let viewerID {
            content.modifier(ObservedCameraPiPPane(controller: controller, viewerID: viewerID,
                cameraSession: session,
                alignment: alignment, isLive: isLive))
        } else { content }
    }
}

private struct ObservedCameraPiPPane: ViewModifier {
    @ObservedObject var controller: CameraPictureInPictureController
    let viewerID: UUID
    let cameraSession: CameraGroupSession
    let alignment: Alignment
    let isLive: Bool

    private var isSource: Bool {
        controller.session?.originViewerID == viewerID
            && controller.session?.camera.id == cameraSession.camera.id
    }

    private var attachedSource: CameraPiPSession? {
        if let pending = controller.pendingSwap, pending.originViewerID == viewerID,
           pending.camera.id == cameraSession.camera.id { return pending }
        return isSource ? controller.session : nil
    }

    func body(content: Content) -> some View {
        let session = attachedSource
        let presentation = CameraPiPPanePresentation(
            attached: session != nil,
            isLive: isLive
        )
        CameraPiPSourceLayer(
            presentation: presentation,
            sourceDidAppear: {
                if let session {
                    controller.sourceAttachmentChanged(sessionID: session.id, attached: true)
                }
            },
            sourceDidDisappear: {
                if let session {
                    controller.sourceAttachmentChanged(sessionID: session.id, attached: false)
                }
            }
        ) {
            content
        } source: {
            if let session {
                // Keep the live source attached while History is in front. In
                // Live, putting it in front exposes AVKit's native PiP message.
                CameraLiveVideoSurface(model: session.model, allowsRetry: false,
                    usesHistory: false, retry: {})
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .id(session.id)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Menu actions are separate from AVKit's inline attachment so the shared
/// camera menu also works when PiP is unavailable (including artificial feeds).
struct CameraPiPMenuItems: View {
    @Environment(\.cameraPictureInPicture) private var controller
    @Environment(\.cameraPiPViewerID) private var viewerID
    @Environment(\.cameraAccessSession) private var access
    let session: CameraGroupSession
    let isLive: Bool
    let canStart: Bool

    var body: some View {
        if let controller, let viewerID, let access {
            ObservedCameraPiPMenuItems(controller: controller, viewerID: viewerID,
                access: access, cameraSession: session, isLive: isLive, canStart: canStart)
        }
    }
}

private struct ObservedCameraPiPMenuItems: View {
    @ObservedObject var controller: CameraPictureInPictureController
    let viewerID: UUID
    let access: CameraAccessSession
    let cameraSession: CameraGroupSession
    let isLive: Bool
    let canStart: Bool

    var body: some View {
        let isSource = controller.session?.originViewerID == viewerID
            && controller.session?.camera.id == cameraSession.id
        let action = CameraPiPMenuAction(isSource: isSource, isActive: controller.phase == .active, isLive: isLive)
        if isSource {
            Button(action.title, systemImage: action.systemImage) { controller.stop() }
        } else if controller.isSupported, canStart, cameraSession.camera.artificialFeed == nil {
            Button(action.title, systemImage: action.systemImage) {
                controller.start(camera: cameraSession.camera, quality: cameraSession.quality,
                    client: cameraSession.client, viewerID: viewerID, access: access)
            }
            .disabled(!controller.canStartOrSwap)
            .accessibilityHint("Shows this camera's live video in Picture in Picture")
        }
    }
}
#endif
