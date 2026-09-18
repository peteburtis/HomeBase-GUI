# Live buffer and NVR history playback

The full-screen player follows normal system orientation behavior. Opening or
closing it does not request rotation or impose an orientation lock. Users can
watch in portrait or rotate the phone for landscape; the system rotation-lock
setting remains authoritative.

The full-screen camera player has a RAM-only live buffer. This is independent
of NVR recording. A separate RAM cache retrieves local NVR history through
HomeBase when playback leaves the live buffer. Neither cache uses media files or S3.
Buffering begins immediately when the full-screen player receives its first
keyframe. It continues in Live, paused, and buffered-playback modes, retaining up
to the most recent five minutes. It fills progressively; footage from before
opening the player is not available in RAM. Grid previews do not retain a buffer.

Opening the full-screen player suspends all camera-grid preview streams (and
the inline preview when opening from device details). Presentation state explicitly
releases those previews' media leases even if SwiftUI keeps the covered views
mounted. The full-screen player's own streams remain independent. Dismissing it
reconnects the visible previews; backgrounded previews remain suspended.

Backgrounding releases live video and history connections. Non-live playback
(the live buffer or NVR history) pauses at its current position, including the
shared timeline in Multiple mode, and stays paused when the screen resumes.
Foregrounding reconnects live collection and history access; it does not press
Play. Live mode instead remains Live and reconnects to the current feed. Other
live-lease unloads/interruption paths use the same pause rule, and an interrupted
pane pauses the whole non-live group. Retained buffers are not discarded; normal
memory limits still apply. Brief inactive states that do not unload video, such
as a system permission dialog, do not restart the stream. Closing the playback
screen still ends its session and releases its buffers.

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
- With advertised NVR history, seeks before the RAM buffer enter history. The gate
  uses available, compatible `cameraPlayback` metadata with a readable store,
  not merely an NVR recording control or an installed NVR. Camera metadata is
  loaded on opening/refreshing the player and updated by metadata events; this is a capability gate, not a
  guarantee of coverage for any requested time range.
- Neither seeking nor playback can pass the newest received frame. Reaching that
  frame during ordinary playback does not automatically exit buffered mode.
- The leading native toolbar always contains Close, the Back 30 / Play-Pause /
  Forward 30 group, and Live. The three shuttles share one system glass capsule;
  Close retains its separation from playback. These are standard SwiftUI toolbar
  items/groups, with system adaptation on narrow screens, not a custom toolbar.
- History lives in a floating bottom-trailing capsule alongside PTZ, not in the
  navigation bar. One selection controls three states: Off, History, and PTZ.
  Off shows History first, then PTZ when available, with neither panel open. Selecting either
  hides the alternate button and tints only the selected icon with the system
  accent color; tapping it again returns Off. The capsule uses Apple's
  `GlassEffectContainer`, shared glass union, and stable effect IDs to morph as
  buttons appear/disappear. There is no red/prominent History state.
  History uses `clock.arrow.trianglehead.counterclockwise.rotate.90` and is
  disabled without advertised NVR history. The capsule keeps its horizontal
  safe-area anchor. With History open, its center aligns vertically with the
  actual timeline bounds, whether the timeline uses the safe area or extends to
  the screen edge; closing History returns it to 12 points inside the bottom
  safe area. This vertical move shares the snappy panel/button
  animation (no animation with Reduce Motion). PTZ sliders always retain their
  safe-area layout. No calendar button is shown.
- PTZ uses the existing four-arrow icon and opens every supported axis together.
  There is no separate zoom toggle. Zoom is at the leading edge, extended down
  to the button baseline and up to the top of the tilt slider; pan remains below
  tilt, to the left of the capsule. Zoom-only cameras also support this panel.
  The PTZ button is shown only for a supported camera in single-camera Live mode.
  It is absent during buffered/history playback and in Multiple mode, even with
  only one camera selected. Returning to Live restores the button, not the sliders.
  Leaving Live, entering Multiple, or losing the capability closes an open PTZ
  panel. Opening either panel never writes camera settings or changes playback.
- Live is always alongside the shuttle controls and always shows
  its icon and “Live” label. It uses native toolbar styling: prominent with red tint in Live mode,
  automatic during buffered/history playback. The toolbar supplies Liquid Glass,
  dimensions, padding, typography, and foreground contrast; no custom background,
  fixed button/icon dimensions, or foreground colors are applied. Its label is
  always “Live”: `dot.radiowaves.left.and.right` while live, or
  `chevron.forward.dotted.chevron.forward` during buffered/history playback.
  It never uses the History icon. A composed icon/title label
  currently keeps the text visible: in the tested iOS 26.1 toolbar,
  `.labelStyle(.titleAndIcon)` is ignored. Prefer replacing the composed label
  with that native modifier when it works in this context. This compatibility
  layout does not customize button styling. Tapping Live resumes live playback
  without hiding shuttles or releasing the buffer. While already live, it is a
  no-op. Neither action changes timeline visibility.
- A native speed menu after Live on the leading side shows the current
  **1×, 2×, or 4×** rate. It is hidden, not disabled, in Live mode; pause or
  rewind first to reveal it. Changing speed preserves pause, cursor, and timeline
  visibility. Multiple mode
  uses one shared rate/clock, including newly added panes and transitions back
  to a single pane. Returning explicitly to Live resets speed to 1×.
  Automatically catching up to the newest live-buffer frame resets speed to
  1× **without leaving buffered playback**. NVR history behaves the same, with a
  half-second allowance for its advertised live edge to account for fetch latency.
  Playback continues as new footage becomes available. An ordinary unloaded
  history/cache boundary only buffers; it does not reset the selected speed.
  The existing explicit Forward-30 behavior is unchanged, and skips still mean
  30 seconds of footage at every speed.
- Record to Photos is available only in Live mode. Shuttle/Live controls stay
  visible but disabled while requesting Photos authorization, starting/saving a
  recording, or recording. The status/timer is shown beneath the navigation bar.
  Record remains in the trailing toolbar during buffered/history playback,
  disabled rather than removed. Quality, day/night, and privacy are absent when
  unavailable, including outside Live; invalid/disconnected day/night and privacy
  controls are hidden, and quality is hidden while Photos recording locks stream
  configuration. Pending day/night or privacy writes retain their brief disabled
  state to prevent duplicate actions without making the button disappear mid-use.
  Capability-based omissions still apply, including no Photos recording in Multiple mode.
  Camera switching remains available in history. PTZ sliders and their button are hidden outside
  Live; pan, pinch, and recenter gestures are disabled there,
  including the recenter accessibility action, and pending writes are cancelled.
  The timeline and PTZ slider panel are mutually exclusive. Opening the timeline
  while Live does not disable top-bar camera controls or per-camera gestures.
  Single-tap still toggles all player chrome.
- Loading, connection/waiting, empty-history and error screens always show the
  toolbar, restoring it if video previously hid it. Video tap/PTZ recognizers are
  disabled while these screens are shown; retry and gap-navigation actions cannot
  toggle the toolbar. When actual video returns, controls stay visible until the
  next video tap. The gesture surface remains beneath UI overlays, and each gap
  arrow has an explicit 44-point circular touch target, not just a tappable glyph.
- “No recording at this time” offers round Liquid Glass backward/forward chevrons around “Next
  available.” An optional negotiated `neighbors` query searches all retained local
  history, not repeated one-minute/date probes. It includes RAM and growing files.
  Each arrow jumps to the start of the nearest returned interval, preserves
  play/pause and the shuttles, and stays in History. A direction is omitted entirely
  on a completed response confirming none; a failed lookup offers retry, while
  older servers show an update hint. Results are refreshed as the gap cursor moves
  outside their bounds, after 60 seconds, or after five seconds when no later
  recording exists. No-recording results are snapshots, not permanent archive ends.

## Switching cameras

The far-right list button stays in its own toolbar group in both Live and History.
Its popover lists the server's viewable cameras by display name, with a checkmark
on the current camera. Selecting that camera is a no-op. The picker is disabled
while requesting Photos access, recording, or saving. The underlying switch path
also finishes an outstanding Photos recording before replacing its camera.

Switching keeps the existing full-screen presentation and timeline visibility.
Only camera-scoped resources are replaced: old subscriptions and media leases are
closed, old buffers discarded, gestures stopped, and a fresh live buffer begins.
Live switches to Live. Buffered/history playback carries its frozen canonical
timestamp and paused/playing state to the new camera's NVR history. With no
readable NVR history on the destination, it switches to Live instead.

A first live-buffer transfer resolves the source camera's NVR clock through a
small availability query (falling back to the NVR's `now` if it has no live anchor).
This retains the same approximate live/NVR mapping used by rewind, compensating
for time spent performing the lookup rather than using the phone's wall clock.
Already-resolved history transfers use their canonical timestamp directly. A
failed clock lookup leaves the original camera selected and reports the error;
missing footage on the destination uses the existing gap-navigation UI.

## Multiple cameras

The camera picker has a highlighted **Multiple** toggle at the bottom left.
It uses the native button-toggle appearance: tinted text while off and a tinted
background while on, without a forced button border.
Turning it on starts with the current camera checked; the picker stays open for
selection. Choose one through four cameras. The last selected camera cannot be
deselected. Turning Multiple off keeps the first selected camera and the current
playback instant/pause state. If the group was in NVR history but the surviving
camera has no NVR, it returns Live without restarting its connection.

Quality starts at **High** (or the camera's highest supported quality) and its
toolbar control remains available in Multiple mode. A quality change applies to
all selected cameras; cameras added later open directly at the selected quality.
The menu offers qualities supported by every selected camera. Adding a camera
that cannot use the selected quality reports that incompatibility instead of
silently changing the existing cameras. Multiple mode hides Photos recording
controls. In compact width with non-compact height, two, three, or four cameras
form a single centered vertical column, in selection order. The 16:9 panes touch
edge to edge. They use the full width when the whole column fits; otherwise the
column scales down uniformly to fit the full height, leaving black bars on both
sides. There is no scrolling, cropping, or offscreen top/bottom overflow.
Other size-class combinations retain two panes side by side or a 2×2 grid for
three/four, leaving the fourth cell black for three. Single-camera presentation
is unchanged. Trait changes only relayout the existing panes; they do not replace
camera sessions, stream connections, buffers, or playback state. The grid ignores safe
areas, while video is aspect-fit inside each cell, never cropped or oversized.
Camera labels stay inside the screen's safe area without moving or shrinking
the video panes; interior grid edges do not gain extra safe-area padding. In
side-by-side two-up they touch the bottom of the actual video rectangle from immediately
below it; in the column and four-up grid they sit inside the video's bottom-left corner.
If there is too little space below a two-up video, the label moves inside rather
than overlapping the home indicator or rounded corners.
Labels hide and reappear with the player controls on a single tap; they remain
visible with the controls on loading, gap, and error screens.

Toggling Multiple is only a selection/layout change. The surviving camera keeps
its mounted player, live connection, renderer, quality, five-minute buffer,
history cache/request, and pause state. Adding/removing a camera opens/closes only
that camera; leaving Multiple retains the first selected camera and expands its
existing pane. No clock lookup or media reload is performed for that transition.
Explicit quality changes still replace stream leases, retaining the screen's
buffer across the resulting media epochs.

One playback clock drives every pane: all are Live, or all follow the same paused
or playing cursor. Live-buffer mapping uses a shared monotonic receive clock;
separate camera feeds still have inherently approximate alignment. NVR history
uses one canonical timestamp. Unknown/unloaded history holds the shared clock;
confirmed gaps can advance, and failed readers show an error without moving to a
different instant. Each pane has its own gap navigation, but either arrow seeks
the whole group. A camera without NVR shows unavailable in history, not live.
Joining/removing a camera retains the group cursor. Readers have independent
connections and caches; the existing buffer limits below apply **per camera**.

Privacy and day/night controls are shown only when every selected
camera advertises the corresponding valid, writable capability. PTZ buttons and
sliders are hidden in Multiple mode. Drag, pinch, and two-finger recenter operate
only on the touched pane's camera, according to that camera's capabilities; they
do not require support from the other cameras. Each pane remembers its own initial
recenter position and cancels pending gestures on removal, backgrounding, or leaving
Live. The shared toolbar's choices are intersected. The first selected camera supplies displayed
state; selecting cameras never aligns or writes settings. Explicit changes fan
out to every camera, translating vendor-specific day/night values. Per-pane
pan/tilt preserves that camera's zoom. Selecting the displayed day/night
mode again deliberately aligns the others. Partial failures are reported; these
multi-camera writes are not atomic. As with one camera, leaving Live disables
camera controls and their gestures; opening the timeline has no such effect.

## Bounds and decoding

The encoded buffer is limited to five minutes, 64 MiB of payloads, and 30,000
frames, whichever is reached first. Decoder/framework memory is additional.
Eviction removes complete keyframe groups. An oversized group is discarded rather
than retained without a bound. iOS memory warnings trim to the newest decodable
keyframe group, but collection continues in every mode.
There are no buffer media files or implicit Photos writes. Merely viewing Live
prepares the media connection but does not request recorded frames.

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
resuming Play starts at the oldest remaining decodable frame; with NVR history,
playback can instead retrieve that older position.

## History and its persistent connection

Screen entry immediately prepares a second physical WebSocket when this camera
advertises compatible local history. It opens a fresh logical session using the
control endpoint and client identity, then upgrades with `nvr.media.open`. It never
replaces the ordinary control connection. The screen keeps it prepared while Live,
paused, or playing. A negotiated `supportsKeepalive` heartbeat every 20 seconds
keeps idle IPC alive without reading files or fetching video. Older servers get an
idle reconnect every 40 seconds, before their 60-second timeout. Screen close
releases the connection and caches; backgrounding suspends networking and
foregrounding prepares it again. Canceling an obsolete in-flight seek closes only
this media connection, then prepares a replacement.

The initial history request is up to **one minute centered on the target**, clipped
at the live edge. Handoff is approximate because live and NVR use separate camera
streams. The first relative-to-live request supplies the NVR's canonical anchor;
if no live anchor exists, NVR's `now` is used instead. The phone clock never sets
this mapping. Once a Begin record resolves the range, all subsequent requests and
retries use that absolute canonical timeline, including after a failed read.
If the first history action is an absolute-time jump, a one-second availability query
resolves that same server anchor without fetching unrelated video. A stopped
camera falls back to the NVR's `now`. The chosen instant stays absolute;
the resulting minute-sized video request and later refills reuse the existing
history path. No Homebase or NVR protocol change is required.

While playing at 1×, forward knowledge below **20 seconds** triggers a **30-second**
refill. At 2× these become 40/60 seconds of footage, and at 4×, 80/120 seconds,
preserving roughly the same real-time runway. Larger refill goals are split into
requests of at most 60 seconds. Only missing intervals are requested, with one request at a time. Pausing
finishes the current/initial fill but does not continuously fetch. New seeks cancel
obsolete work and reject late replies. History stays selected even when it overlaps
live RAM. Explicit Live returns to live and leaves shuttles open; playing Forward past
the live edge returns live without hiding shuttles. Paused Forward stays paused.

Loading freezes the clock; confirmed recording gaps show black with an explicit
message while time advances. Errors have a retry action and are never cached as
gaps. One short retry handles read/rotation races; subsequent playing retries are
paced at five seconds. Gaps are reconsidered after five seconds near the live
edge, one minute otherwise. H.264/H.265 frames decode directly, with invisible
keyframe preroll and separate decoder epochs across response segments.

The history-loading overlay includes the selected video's canonical timestamp
as `yyyy-MM-dd HH:mm:ss` (Gregorian, 24-hour), in the same time zone as the picker.
Homebase advertises an optional IANA `timeZoneIdentifier` in camera playback
metadata; omitted/invalid identifiers fall back to the viewer's local zone.
The zone's daylight-saving rules apply at the recording date, not today's date.
A first relative seek shows the timestamp as soon as the NVR's Begin record
resolves its anchor, without waiting for all video bytes. It never substitutes
the phone's current time or the beginning of the surrounding fetched minute.
Live connection loading has no recorded-video timestamp and is unchanged.

History is bounded by five minutes of fetched range, 64 MiB, 30,000 frames and 64
batches, evicting whole decoder pieces furthest from the cursor. Its in-flight
response has a separate 64 MiB/30,000-frame cap; the live cache retains its own
64 MiB limit. Decoder/framework memory is additional. No MP4 is downloaded,
written or remuxed. Memory warnings clear history and trim live RAM to its latest
GOP. Only normally completed responses become cached coverage.

## Thumbnail timeline (first pass)

When NVR history is advertised, History in the bottom capsule shows a horizontal
thumbnail strip at the bottom of the player. It starts hidden on each screen
entry, independently of Live/buffered/history playback. Only the History button
shows or hides it: there is no grab handle, vertical reveal/dismiss gesture, or
slide transition. The timeline appears beneath the floating capsule, which centers
vertically on the timeline while keeping its horizontal safe-area anchor;
horizontal scrolling still scrubs time. The timeline and PTZ panel cannot both
be open. Hiding the timeline closes its thumbnail
connection and stops follow/fetch work. It also hides with all player chrome,
preserving its chosen visibility when chrome returns. A fixed center marker is the
playback position. With a **compact vertical size class**, the timeline itself
extends through the side and bottom safe areas to the screen edges; regular
height keeps its safe-area layout. Compact width alone does not mean portrait.
The playhead reaches the bottom edge, with no bottom container padding;
the numeric label row leaves just two physical pixels below its text baseline.
The playhead and timeline labels are yellow, with semibold monospaced digits
for the current playback timestamp and thumbnail interval times.
The toolbar and camera-label safe areas are unchanged. The
past is left, future is right. Each thumbnail cell
represents 20 minutes, but scrolling seeks continuously, not in 20-minute steps.
Thumbnail frames are 16:9, normally 112×63 points. Ordinary single-camera mode
always uses that full size, including in compact height. In Multiple mode with
compact height, reserve the
space below a hypothetical full-canvas two-up 16:9 video and its camera-label row,
then subtract the time-label row and a two-point gap. Clamp thumbnail height to
36…63 points (width 64…112). Both label rows use their actual font metrics, including
Dynamic Type for camera names. The minimum keeps the strip usable in unusually
short windows even when there is insufficient room to guarantee label clearance.
This same reference determines the size in Multiple-with-one, two-up, three-up,
and four-up views, in Live and History. Within Multiple mode, camera selection, aspect ratio,
and toolbar visibility cannot resize it; window/size-class and font-metric changes
can; leaving Multiple mode restores full size. Resizing preserves the centered timestamp without seeking, and all scroll,
snap, haptic, and visible-thumbnail calculations use the resulting cell width.
Images proportionally fill the frame,
cropping overflow from other aspect ratios instead of letterboxing or stretching.

Player layout uses size classes for adaptive policy, not orientation, screen-model
tables, or screen bounds. The camera preview grid uses horizontal size class;
the timeline uses vertical size class. Video aspect-fit, per-pane gesture coordinates,
safe-area label placement, and bounded PTZ slider lengths remain geometric
calculations, not orientation guesses. Camera count and the combined width/height
size classes choose the column or two/four-up grid; this does not change the
timeline's hypothetical two-up sizing reference within Multiple mode. Native toolbars/popovers retain system adaptation (with
the explicitly requested popover behavior in compact layouts).

Each interval label is left-aligned to its interval's start, but is hidden in
full if it touches or crosses the playhead or lies to its right. The current
playback timestamp owns the bottom label row just to the right of the playhead,
on the same baseline as the remaining interval labels. It stays visible during
scrubbing, with no fade mask. It shows `HH:mm:ss` within the last 24 elapsed hours
of the NVR-derived live edge, and `HH:mm:ss yyyy-MM-dd` further back, keeping the
time anchored beside the playhead as the date appears to its right, always in
the server's time zone. There is no separate timestamp row above the thumbnails.
User scrubbing gives light system selection feedback as a time mark crosses
the center. Feedback has a two-point re-arm distance and is rate-limited during
fast flicks; ordinary playback and programmatic alignment are silent. Settling
within three points of a mark nudges to that exact time with a short animation
(without animation when Reduce Motion is enabled). It never snaps into the future
or forces a seek elsewhere in an interval onto the twenty-minute grid.
At Live the right half is empty; future seeks are clamped at the server-derived
edge. That edge advances from the NVR's anchor using monotonic elapsed time.

Dragging pauses advancement so the target stays under the marker. When scrolling
and inertia stop, the player seeks once and restores its prior playing/paused
state. Merely following playback or laying out the strip never seeks. Scrolling
uses canonical time; labels use Homebase's time zone, with the existing local-zone
fallback. VoiceOver's adjustable action moves twenty minutes in either direction.
Multi-camera uses the first selected camera for previews and moves every selected
camera together on the shared timeline.

Only the visible cells plus a small margin are requested, nearest first, as
320×180-bounded JPEGs over a separate media WebSocket. This does not compete with
the playback connection's request/reply framing. Requests are serial, previews
are memory-only (48 cached images maximum), and obsolete work is cancelled when
the strip closes or the app backgrounds. The native scroll view represents a
bounded 24-hour window, rebasing near its ends after scrolling stops; this is not
a 24-hour archive limit. Missing previews are not evidence that the entire
twenty-minute interval lacks video: a cell samples one point near its midpoint.
The existing playback gap/error UI remains authoritative after a seek.

Recent and missing previews refresh after a minute when visible; older images
cache for an hour and errors retry after thirty seconds. Older Homebase/NVR
versions without thumbnail capability show a quiet update hint while still
allowing ordinary history seeks. This is deliberately a coarse, fixed-scale
first pass, without zoom, coverage bands, or automatic archive-wide scanning.

## Verification

`CameraLivePlaybackTests` exercises timing, limits, eviction, pause/seek semantics,
decoder preroll, lifecycle, and separation from Photos using synthetic H.264.
Injected-clock tests also check 1×/2×/4× pacing, rate changes while paused,
live-edge slowdown without switching modes, shared multi-camera pacing, and
speed-aware bounded history refills versus ordinary cache exhaustion.
It needs no server, camera, or saved footage. Run the full `HomeBase-GUI` scheme's
tests on macOS and an iOS simulator.
`CameraLivePlaybackPresentationTests` also checks the separate History and Live
symbols, the collapsed non-live History indicator, Live's no-op action while live,
its always-visible label, and the production toolbar's expanded/collapsed order
and symmetric conditional separation inside a real toolbar, plus the native camera
gesture recognizers' availability on iOS.
`CameraHistoryTests` adds cache/refill, paused seeks, stale responses, stable time
anchoring, protocol bounds, H.264/HEVC decoding, metadata ordering, WebSocket reuse,
timeouts and cancellation tests with injected transports.
`CameraTimelineTests` covers scroll/time mapping, future clamping, NVR anchoring,
bounded visible-only preview loading, cancellation, compatibility, strict JPEG
message framing, native centered layout, and an opt-in simultaneous real thumbnail
and playback read. Thumbnail smoke requires HBNVR 0.15.0 and the matching relay;
it uses the existing `HB_HISTORY_PLAYBACK_SMOKE_URL` opt-in.
`CameraSwitchingTests` covers selection identity, capability fallback, preserved
pause/timestamps, delayed initial connections, clock resolution/cancellation,
and read-only picker refresh. The opt-in history smoke also transfers a paused
live buffer between two cameras and switches back through playing NVR history.

`CameraLivePlaybackSmokeTests` is skipped by default. To explicitly consume live
video, set the test process's `HB_LIVE_PLAYBACK_SMOKE_URL` to the server's pairing
URL, e.g. `homebasews://127.0.0.1:10503`. With `xcodebuild`, use the
`TEST_RUNNER_HB_LIVE_PLAYBACK_SMOKE_URL` environment variable. It checks every
advertised H.264 camera through the real GUI connection/model/renderer, closes
its own leases, and does not alter camera settings or save any video.
On macOS this also exercises mounted previews being covered and uncovered,
checks that the independent full-screen feed keeps receiving without reopening,
and tests dismissal while backgrounded and rapid presentation changes.
`HB_HISTORY_PLAYBACK_SMOKE_URL` independently opts into NVR-history reads and the
live/history handoff (use `TEST_RUNNER_HB_HISTORY_PLAYBACK_SMOKE_URL` with xcodebuild).
The history smoke suite requires HBNVR 0.14.0 and the corresponding Homebase relay.
It also checks both archive boundaries and a paused jump from an empty date to the
first retained recording, including actual frame rendering at the returned target.

Manual phone check: open a camera. Close, one shuttle capsule, and Live are
present immediately; speed, the timeline, and PTZ sliders are absent. At bottom
right, History precedes PTZ in one neutral glass capsule. Tap PTZ: only its tinted
icon remains, supported sliders appear together, and no camera setting changes.
Tap again: both icons return. Tap History: only its tinted icon remains and the
timeline appears underneath the capsule, which animates to the timeline's vertical
center without changing its horizontal anchor. Tap History again to hide it and
animate the capsule back to its bottom safe-area anchor in the same panel transition.
There is no separate handle or vertical show/hide gesture. Top-bar camera
controls and gestures remain usable while Live. Horizontal timeline scrubbing
still seeks. Verify full-size thumbnails in ordinary single-camera mode and
compact sizing in Multiple mode, even with one selected camera. Toggle visibility while paused and
playing, confirming no playback state changes. In portrait, allow the system's
native navigation-bar adaptation; there is no bespoke row layout.
Seek to an empty time and use the gap arrows to find the preceding/following
recording; missing directions are absent and paused jumps remain paused.
Pause: speed appears beside Live; Record stays visible but disabled, while quality,
day/night, privacy, and PTZ controls disappear. Camera gestures do not move the camera. Camera
switching remains usable. After five seconds, Forward 30 should show the newest
frame but remain paused as new frames arrive. Play, then Forward 30: this resumes
Live and hides speed without changing the timeline. Back immediately replays
retained footage. Tap Live: video resumes without changing timeline visibility.
Tap again: nothing changes. Close and reopen the screen to
start a fresh buffer. Without advertised NVR history, Back beyond
the buffer lands on its first picture and disables Back while paused; Play
re-enables it. With NVR history advertised, Back beyond the buffer should show
Loading briefly, then recorded footage or an explicit gap/error. Play across a
minute boundary, pause and seek both ways, then return Live. Camera controls and
gestures must remain unavailable throughout historical playback.
Open the camera list in Live and History; confirm its independent toolbar group
and current-camera checkmark. Switch while Live, paused in the live buffer, and
playing History. The screen and timeline visibility should stay put; historical time
and pause state should carry across. With no destination NVR, expect Live instead.
Start a Photos recording and confirm the list button stays visible but disabled
until the recording finishes saving. The shuttles stay visible but disabled too,
and the recording timer/save status appears beneath the navigation bar.
