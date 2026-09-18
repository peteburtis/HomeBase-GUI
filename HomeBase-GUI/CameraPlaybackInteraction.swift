/// Status/error UI is not a video gesture surface. Its navigation must remain
/// visible even if the preceding video was playing with the toolbar hidden.
struct CameraPlaybackInteraction {
    let showsVideo: Bool

    init(liveState: CameraLiveVideoModel.State, usesHistory: Bool,
         historyState: CameraHistoryPlayback.State, playbackFailed: Bool) {
        showsVideo = !playbackFailed && (usesHistory ? historyState == .ready : liveState.displaysVideo)
    }

    func controlsVisible(requested: Bool) -> Bool { !showsVideo || requested }
    func togglingControls(from visible: Bool) -> Bool { showsVideo ? !visible : true }
}
