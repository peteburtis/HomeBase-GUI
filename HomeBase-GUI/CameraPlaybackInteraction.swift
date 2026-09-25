/// Video availability controls camera gestures, not whether the surrounding
/// player chrome can be toggled. A status or no-history pane still owns the
/// single-tap gesture used to show and hide that chrome.
struct CameraPlaybackInteraction {
    let showsVideo: Bool

    init(liveState: CameraLiveVideoModel.State, usesHistory: Bool,
         historyState: CameraHistoryPlayback.State, playbackFailed: Bool) {
        showsVideo = !playbackFailed && (usesHistory ? historyState == .ready : liveState.displaysVideo)
    }

    func controlsVisible(requested: Bool) -> Bool { requested }
    func togglingControls(from visible: Bool) -> Bool { !visible }
}
