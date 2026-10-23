import XCTest
@testable import HomeBase_GUI

@MainActor
final class CameraPlaybackInteractionTests: XCTestCase {
    func testEveryLiveStatusScreenAllowsControlsToToggle() async {
        let states: [CameraLiveVideoModel.State] = [
            .idle, .connecting, .waiting("Reconnecting"),
            .ended("Offline", retryable: true), .ended("Stopped", retryable: false), .failed("Error")
        ]
        for state in states {
            let presentation = CameraPlaybackInteraction(liveState: state, usesHistory: false,
                historyState: .idle, playbackFailed: false)
            assertStatusScreen(presentation)
        }
    }

    func testHistoryStatusScreensIgnoreHealthyBackgroundLiveStream() async {
        for state in [CameraHistoryPlayback.State.idle, .loading, .gap, .failed("Error")] {
            let presentation = CameraPlaybackInteraction(liveState: .playing, usesHistory: true,
                historyState: state, playbackFailed: false)
            assertStatusScreen(presentation)
        }
    }

    func testHistoryVideoStillAllowsTogglingWhenLiveConnectionIsDown() async {
        assertVideo(CameraPlaybackInteraction(liveState: .failed("Offline"), usesHistory: true,
            historyState: .ready, playbackFailed: false))
    }

    func testActualLiveOrBufferedVideoAllowsToggling() async {
        assertVideo(CameraPlaybackInteraction(liveState: .playing, usesHistory: false,
            historyState: .idle, playbackFailed: false))
    }

    func testPlaybackErrorsAllowControlsToToggleForEitherSource() async {
        for history in [true, false] {
            assertStatusScreen(CameraPlaybackInteraction(liveState: .playing, usesHistory: history,
                historyState: .ready, playbackFailed: true))
        }
    }

    private func assertStatusScreen(_ presentation: CameraPlaybackInteraction) {
        XCTAssertFalse(presentation.showsVideo)
        for requested in [true, false] {
            XCTAssertEqual(presentation.controlsVisible(requested: requested), requested)
            XCTAssertEqual(presentation.togglingControls(from: requested), !requested)
        }
    }

    private func assertVideo(_ presentation: CameraPlaybackInteraction) {
        XCTAssertTrue(presentation.showsVideo)
        for requested in [true, false] {
            XCTAssertEqual(presentation.controlsVisible(requested: requested), requested)
            XCTAssertEqual(presentation.togglingControls(from: requested), !requested)
        }
    }
}
