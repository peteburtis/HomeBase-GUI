# Rolling live playback buffer

The full-screen camera player has a RAM-only live buffer. This is independent
of NVR recording and does not fetch history from HomeBase, local stores, or S3.
Buffering begins immediately when the full-screen player receives its first
keyframe. It continues in Live, paused, and buffered-playback modes, retaining up
to the most recent five minutes. It fills progressively; footage from before
opening the player is not available in RAM. Grid previews do not retain a buffer.

- Pause freezes the displayed picture while incoming compressed H.264 video
  continues entering the buffer. Play advances through retained footage
  at its original cadence while reception continues.
- Back/Forward move the playback position by 30 seconds. Forward is disabled in
  Live mode. All paused seeks stay paused, including Forward to or beyond the
  newest frame: the position clamps to that frame and stays there as reception
  continues. While playing, Forward to or beyond the newest frame resumes Live
  and leaves the shuttle controls open. Neither path discards the buffer.
  Rewinding directly from Live uses whatever footage has accumulated on-screen.
- Without advertised NVR history for this camera, Back 30 stops at the first
  decodable buffered frame. It stays paused if paused, and is disabled at that
  boundary while paused. Playing forward re-enables it immediately; a full 30
  seconds of footage is not required. Arriving frames alone do not re-enable it.
  If no keyframe has arrived yet, keep the current picture while buffering starts.
- With advertised NVR history, seeks before the RAM buffer remain allowed and
  currently display black. Fetching that history is a future increment. The gate
  uses available, compatible `cameraPlayback` metadata with a readable store,
  not merely an NVR recording control or an installed NVR. Camera metadata is
  loaded on opening/refreshing the player; this is a capability gate, not a
  guarantee of coverage for any requested time range.
- Neither seeking nor playback can pass the newest received frame. Reaching that
  frame during ordinary playback does not automatically exit buffered mode.
- Live is the same capsule button in both states, red only in Live mode and
  neutral while buffered. Its label and size do not change:
  tapping it resumes Live and closes the playback controls without releasing the buffer.
  While already Live it toggles those controls as before.
- Record to Photos is available only in Live mode. Playback controls are unavailable
  while requesting Photos authorization, starting/saving a recording, or recording.
  The entire right-hand toolbar (Record, quality, day/night, and privacy) and the
  PTZ/zoom overlay are hidden while buffered. Pan, pinch, and recenter gestures
  are disabled, including the recenter accessibility action; pending gesture
  writes are cancelled. Single-tap still toggles the player controls.

## Bounds and decoding

The encoded buffer is limited to five minutes, 64 MiB of payloads, and 30,000
frames, whichever is reached first. Decoder/framework memory is additional.
Eviction removes complete keyframe groups. An oversized group is discarded rather
than retained without a bound. iOS memory warnings trim to the newest decodable
keyframe group, but collection continues in every mode.
There are no buffer media files, Photos writes, or NVR API calls.

The first replayable picture is the first received keyframe. Seeks decode from
a retained preceding keyframe without displaying
the preroll pictures. Returning Live also waits for an incoming keyframe to
resynchronize the decoder. A short black interval at either boundary is expected.

Closing the screen releases its buffer. Ending a stream lease, backgrounding,
changing quality/generation, or a backwards source timestamp does not discard
retained footage. Each new stream epoch keeps its own decoder configuration and
starts collecting at a keyframe; monotonic receipt time places the new epoch
after the previous one, including a connection gap. The existing app lifecycle
still stops network reception in the background; it resumes on returning to the
screen. Pausing for longer than the retention window can leave the cursor before
available footage. Without NVR history,
resuming Play starts at the oldest remaining decodable frame; otherwise seek
forward or tap Live until history retrieval is implemented.

## Verification

`CameraLivePlaybackTests` exercises timing, limits, eviction, pause/seek semantics,
decoder preroll, lifecycle, and separation from Photos using synthetic H.264.
It needs no server, camera, or saved footage. Run the full `HomeBase-GUI` scheme's
tests on macOS and an iOS simulator.
`CameraLivePlaybackPresentationTests` also checks stable Live-button geometry and
the native camera gesture recognizers' availability on iOS.

`CameraLivePlaybackSmokeTests` is skipped by default. To explicitly consume live
video, set the test process's `HB_LIVE_PLAYBACK_SMOKE_URL` to the server's pairing
URL, e.g. `homebasews://127.0.0.1:10503`. With `xcodebuild`, use the
`TEST_RUNNER_HB_LIVE_PLAYBACK_SMOKE_URL` environment variable. It checks every
advertised H.264 camera through the real GUI connection/model/renderer, closes
its own leases, and does not alter camera settings or save any video.

Manual phone check: open a camera, tap Live to reveal controls, and pause. Confirm
the Live capsule keeps its shape without clipping and all right-side/overlay
camera controls disappear; dragging, pinching, and two-finger tapping must not
move the camera. After five seconds, Forward 30 should show the newest frame but
remain paused as new frames arrive. Play, then Forward 30: this resumes Live and
leaves the shuttle controls open. Back should immediately replay retained footage.
Tap Live: video resumes and the shuttle controls close, but opening the shuttle
controls and rewinding again must still work. Close and reopen the screen to
start a fresh buffer. Without advertised NVR history, Back beyond
the buffer lands on its first picture and disables Back while paused; Play
re-enables it. With NVR history advertised, Back beyond the buffer still displays
black until history retrieval is implemented.
