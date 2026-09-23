# Live buffer and NVR history playback

The full-screen player follows normal system orientation behavior. Opening or
closing it does not request rotation or impose an orientation lock. Users can
watch in portrait or rotate the phone for landscape; the system rotation-lock
setting remains authoritative.

The full-screen camera player has a RAM-only live buffer. This is independent
of NVR recording. A separate RAM cache retrieves local NVR history through
HomeBase when playback leaves the live buffer, with direct S3 fallback when
credentials are unlocked. Neither cache writes media files to disk.
Buffering begins immediately when the full-screen player receives its first
keyframe. It continues in Live, paused, and buffered-playback modes, retaining up
to the most recent five minutes. It fills progressively; footage from before
opening the player is generally not available in RAM, apart from the arbiter's
small keyframe-led warm-join cache. Camera-grid previews prefer a current HBNVR
JPEG thumbnail and refresh each camera every ten seconds over one serial media
connection. Cameras without thumbnail support or current recording coverage
fall back to their lowest advertised live quality. Thumbnail and live fallback
are mutually exclusive, and grid previews do not retain a playback buffer.

Opening the full-screen player suspends all camera-grid preview work (and
the inline preview when opening from device details). Presentation state explicitly
releases thumbnail polling and any fallback stream subscriptions even if SwiftUI
keeps the covered views mounted. All live views on the same HomeBase client share
a per-camera stream arbiter. Fallback cameras with no viewers close after **two
seconds**. Backgrounded previews remain suspended.

### Shared live connections and quality handoff

The arbiter owns upstream media leases, with normally one connection per camera.
Consumers have independent renderers, playback buffers, and Photos recording
state; encoded frame data is shared. A new consumer is primed with configuration
and the current complete keyframe-led GOP, bounded to **8 MiB / 150 frames**.
If that GOP exceeds the bound, the new consumer waits for the next keyframe.
There are no disk caches or new media-file writes. A stalled consumer has a
bounded queue and is disconnected independently of healthy viewers.

The highest quality requested by active consumers wins. Upgrades begin
immediately; downgrades wait **two seconds** to avoid churn during presentation
handoffs. A quality change warms a second connection while the current stream
keeps playing, then switches at configuration plus keyframe without recreating
the view or blanking its displayed image. Rapid selections supersede pending
warm-ups; at most three workers overlap per camera, including a retiring one.
Newer selections wait if all three slots are occupied. Failed warm-ups retain
the playing stream, show a nonblocking warning, and retry with shared backoff
(2, 4, 8, 16, then 30 seconds). Warm-up has a 20-second deadline.

HomeBase's optional `openCameraLiveStream.isolatedQuality: true` creates a
quality-specific upstream fanout so warming another quality does not restart
the old camera feed. Same-camera/same-quality clients still share the server's
upstream. Legacy requests omit the field and retain highest-viewer-quality
behavior. Old servers ignore the optional field and remain usable, but cannot
guarantee uninterrupted quality changes; deploy the updated HomeBase alongside
this GUI feature. The server permits twelve viewer leases per session to cover
four panes during rapid transitions; isolated upstreams stop once their final
lease closes because the GUI already owns the handoff grace period.

Opt-in `CameraLivePlaybackSmokeTests/testStreamArbiterQualityHandoffKeepsPlayingThroughRealServer`
exercises low → high → low on a real camera, checks that playback never leaves
its playing state and retained buffer is preserved, then joins a warm preview.
Use `TEST_RUNNER_HB_LIVE_PLAYBACK_SMOKE_URL` with the existing smoke procedure
below. It neither changes camera controls nor saves media.

Backgrounding, biometric locking, leaving the camera section, and HomeBase
disconnect bypass the warm-join grace. Authorization revocation also rejects
late acquisitions, clears the arbiter's compressed-media cache, and closes
pending replacement streams. Inactive system dialogs only conceal the existing
camera UI; they retain the existing camera-section lifecycle policy.

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
- The leading native toolbar contains Close, the Back 30 / Play-Pause /
  Forward 30 group, and Live. The three shuttles share one system glass capsule;
  Close uses iOS 26's native close button role; a standard toolbar spacer separates
  it from playback. The toolbar owns
  button sizing and glass, with no fixed button frame, custom backing, or padded
  button content. These are standard SwiftUI toolbar items/groups, with system
  adaptation on narrow screens, not a custom toolbar. Live/Record retain only
  their state-dependent native prominence and tint.
  In **compact horizontal size class**, Back 30, Forward 30, Video quality,
  Day and night mode, and Privacy mode use `.secondaryAction` to intentionally
  appear in the system overflow menu. Close, Play-Pause, and Live stay leading.
  Camera selection stays trailing, alongside Record while live or playback speed
  while buffered/in history. In compact width, speed moves from leading to
  trailing and replaces Record rather than going into overflow.
  Compact width makes Live icon-only and omits the extra spacers between the
  playback actions and trailing actions; Close retains its own separation.
  Regular width keeps the full toolbar. This uses size classes, not orientation
  or screen-width thresholds. It is an iOS 26 compatibility policy; when adopting
  iOS 27, use its explicit toolbar overflow and visibility-priority APIs while
  retaining this fallback for iOS 26. Native adaptation still applies if even
  the reduced primary controls cannot fit. Camera capability, recording, and
  live/history availability rules are unchanged. The all-playback ControlGroup
  experiment and temporary removal of the trailing controls have been reverted.
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
  It is absent during buffered/history playback and when two or more cameras are
  selected. One selected camera retains PTZ even with Multiple enabled in the picker.
  Returning to Live restores the button, not the sliders.
  Leaving Live, adding a second camera, or losing the capability closes an open PTZ
  panel. Opening either panel never writes camera settings or changes playback.
- Live is always alongside Play-Pause. It shows only its icon in compact width,
  and its icon and “Live” label in regular width (and on macOS).
  It uses native toolbar styling: prominent with red tint in Live mode,
  automatic during buffered/history playback. The toolbar supplies Liquid Glass,
  dimensions, padding, typography, and foreground contrast; no custom background,
  fixed button/icon dimensions, or foreground colors are applied. Its label is
  always “Live” for accessibility: `dot.radiowaves.left.and.right` while live, or
  `chevron.forward.dotted.chevron.forward` during buffered/history playback.
  It never uses the History icon. A composed icon/title label
  currently keeps the text visible: in the tested iOS 26.1 toolbar,
  `.labelStyle(.titleAndIcon)` is ignored. Prefer replacing the composed label
  with that native modifier when it works in this context. This compatibility
  layout does not customize button styling. Tapping Live resumes live playback
  without hiding shuttles or releasing the buffer. While already live, it is a
  no-op. Neither action changes timeline visibility.
- A native speed menu (trailing in compact width, after Live on the leading side
  in regular width) shows the current
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
  In regular width, Record remains in the trailing toolbar during buffered/history
  playback, disabled rather than removed. In compact width it is hidden while
  playback speed occupies that trailing space. Quality, day/night, and privacy are absent when
  unavailable, including outside Live; invalid/disconnected day/night and privacy
  controls are hidden, and quality is hidden while Photos recording locks stream
  configuration. Pending day/night or privacy writes retain their brief disabled
  state to prevent duplicate actions without making the button disappear mid-use.
  Capability-based omissions still apply, including no Photos recording with two or more cameras selected.
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

The far-right camera-selection button uses the filled-grid `rectangle.grid.3x3.fill`
symbol and stays in its own toolbar group in both Live and History.
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

The camera picker has a highlighted **Multiple** toggle at the bottom trailing edge.
It uses the native button-toggle appearance: tinted text while off and a tinted
background while on, without a forced button border.
It defaults to selected every time the picker opens, with the current cameras
checked. Opening the picker or toggling Multiple with one camera changes only
the selection UI: it does not change clock ownership, controls, or playback.
Choose one through four cameras; the picker stays open for selection. The last selected camera cannot be
deselected. Turning Multiple off keeps the first selected camera and the current
playback instant/pause state. If the group was in NVR history but the surviving
camera has no NVR, it returns Live without restarting its connection.

There is only one single-camera presentation: one selected camera has no camera
label, full-size timeline thumbnails, and the normal recording, quality, day/night,
privacy, and PTZ controls subject to their usual live/capability/recording rules.
The synchronized group clock starts only when a second camera is added. Removing
either camera from a pair returns the survivor to its own playback clock and full
single-camera controls without replacing its session, renderer, or buffers.
Multiple remains selected in the picker so another camera can be added directly.

Quality starts at **High** (or the camera's highest supported quality) and its
toolbar control remains available in Multiple mode. A quality change applies to
all selected cameras; cameras added later open directly at the selected quality.
The menu offers qualities supported by every selected camera. Adding a camera
that cannot use the selected quality reports that incompatibility instead of
silently changing the existing cameras. Two or more selected cameras hide Photos recording
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
Labels appear only with two or more selected cameras. They hide and reappear with the player controls on a single tap; they remain
visible with the controls on loading, gap, and error screens.

Toggling Multiple is only a selection/layout change. The surviving camera keeps
its mounted player, live connection, renderer, quality, five-minute buffer,
history cache/request, and pause state. Adding/removing a camera opens/closes only
that camera; leaving Multiple retains the first selected camera and expands its
existing pane. No clock lookup or media reload is performed for that transition.
Explicit quality changes use the make-before-break arbiter handoff, retaining
the screen's buffer and paused position across the resulting media epochs.

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
sliders are hidden with two or more selected cameras. Drag, pinch, and two-finger recenter operate
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
Thumbnail frames are 16:9, normally 112×63 points. One selected camera
always uses that full size, including in compact height and with Multiple selected in the picker. With two or more cameras and
compact height, reserve the
space below a hypothetical full-canvas two-up 16:9 video and its camera-label row,
then subtract the time-label row and a two-point gap. Clamp thumbnail height to
36…63 points (width 64…112). Both label rows use their actual font metrics, including
Dynamic Type for camera names. The minimum keeps the strip usable in unusually
short windows even when there is insufficient room to guarantee label clearance.
This same reference determines the size in two-up, three-up,
and four-up views, in Live and History. While two or more cameras are selected, camera selection, aspect ratio,
and toolbar visibility cannot resize it; window/size-class and font-metric changes
can; returning to one camera restores full size. Resizing preserves the centered timestamp without seeking, and all scroll,
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
versions without thumbnail capability and without an unlocked S3 preview source show a quiet update hint while still
allowing ordinary history seeks. This is deliberately a coarse, fixed-scale
first pass, without zoom, coverage bands, or automatic archive-wide scanning.

## Camera access and S3 credential setup

The camera section opens with named chips containing plain black previews during
authentication: no padlocks, progress spinners, or Unlock button. Only a cancelled
or failed attempt reveals padlocks and an Unlock retry; retrying immediately
returns to plain black until the attempt completes. The same quiet concealment
applies in fullscreen, device details, and temporary system-UI interruptions.
Unauthorized chips do nothing when tapped and do not create preview streams.
The S3 setup padlock on missing footage is a separate action and is unchanged. The same
gate covers camera video opened from device details; fullscreen players cannot
bypass it. One session spans the camera list, fullscreen player, and camera
switches. Leaving the section or backgrounding locks the session and releases
its credential references. Inactive transitions conceal imagery for system
snapshots, but do not cancel the authentication prompt itself. History stays
paused at its existing position after backgrounding, behind the lock.

Authentication follows the system on every entry, without a saved consent flag:

- Camera-page access and S3-credential access are independent. One successful
  biometric prompt satisfies the UI lock and is reused for a protected Keychain
  read. If the read fails, live/local camera viewing remains authorized; S3 stays
  locked with a separate credential error. No second prompt is necessary.
- The UI policy also allows entry on `biometryNotAvailable`, whether caused by
  missing hardware or denied/revoked Face ID permission, even when saved S3
  credentials exist. Protected or unknown credentials are never read through
  that exception. Explicitly legacy-unprotected items can still be read.
- Cancellation, lockout, unenrolled biometrics, and other authentication failures
  leave the camera page locked. Cancellation never starts another prompt
  automatically; Unlock retries. There is no passcode fallback in this policy.
- A noninteractive Keychain inspection returning `errSecInteractionNotAllowed`
  (-25308) means "authenticate before reading," not "missing credentials" and
  not a fatal page-lock error. Other inspection failures also allow the UI gate
  to run, but never authorize a credential read without successful biometrics.
  This physical-device behavior is explicitly simulated by regression tests;
  the simulator's real Keychain can return attributes without authentication.

When video is missing and an S3 destination is advertised, a closed padlock at
bottom leading offers credential setup, opposite and vertically aligned with
the History/PTZ capsule. It makes no claim that S3 has recordings. It is absent
during Live, loading, or visible video, and absent once that destination's
credentials are unlocked. Multi-camera mode offers it if any selected camera
has a missing-video state with an advertised destination.
If the credentials could not be unlocked, the form offers **Unlock saved
credentials** to retry with a fresh biometric context without rewriting them.
Failure or cancellation of this S3-only retry does not relock camera viewing.
Backgrounding or leaving Cameras still invalidates attempts and clears both
authorization and unlocked credentials, including late read completions.

The native S3 form shows the advertised bucket, region, and prefix and accepts
a **separate read-only** access key ID, secret access key, and optional encryption
password. It never pre-fills secrets or sends them to Homebase/NVR. Explicit Save
requires biometrics even if the camera page was admitted without authentication.
The single client-wide Keychain bundle uses device-only accessibility, biometric
access control, and no iCloud synchronization. Replacing another store requires
confirmation. Credentials bind to store ID and exact destination, not camera
names, daemon process IDs, or encryption toggles. Password text is preserved
verbatim. Neither an app preference nor credential metadata contains the secrets.

The form links to a suggested IAM identity policy with selectable JSON, Copy JSON,
and Share JSON actions. It grants only `s3:GetObject` on the advertised bucket and
exact prefix (including future predictable manifest objects). It does not grant
bucket listing, writes, deletes, lifecycle changes, or KMS access; the supported
recorder uses SSE-S3 and optional app-side encryption. Use a dedicated IAM user
without console access and no other policies. JSON generation rejects IAM
wildcards/variables in advertised destinations instead of broadening access.
An explicitly empty prefix grants reads throughout that bucket and is labeled so.

The reader does not interpret every HTTP 403 as invalid credentials:
without `s3:ListBucket`, a missing object also returns 403, not 404. Predictable
manifest names avoid listing, but do not remove that ambiguity. See the
[AWS GetObject permission rules](https://docs.aws.amazon.com/AmazonS3/latest/API/API_GetObject.html).

Saving credentials only verifies the Keychain save, not AWS access. Once saved
or unlocked, the current history cursor is retried using the same buffer and
pause state. Older servers without `playbackManifestVersion: 1` retain local-only
behavior. Homebase advertises at most one local and one S3 store; HBNVR pins local
reads to that selected first local store. Reader credentials remain bound to one
exact S3 destination, never tried against other stores.

### Local-first S3 playback

The existing history buffer, one-minute initial window, 30-second refills and
20-second runway are unchanged. Each retrieval first tries local NVR history.
Only missing intervals or failed local reads go to S3, directly from the app over
HTTPS. Local frames win in overlaps, including S3 keyframe preroll.

Timeline previews use the same local-first policy with a separate, serial thumbnail
connection. A missing/failed local preview falls back directly to the advertised S3
store only when matching credentials are already unlocked. No additional prompt,
bucket listing, manifest fetch, video download, or IAM permission is required for a
preview. Without matching unlocked credentials, behavior remains local-only.

S3 previews use predictable UTC `:10/:30/:50` midpoint keys under
`<prefix>.hbnvr/playback/v1/<lowercase-camera-UUID>/thumbnails/YYYY-MM-DD/HH-mm.jpg`,
with `.hbnvr` appended for encrypted images. An encrypted store requires the encrypted
object and never downgrades to plaintext. A currently plaintext store tries `.jpg`,
then an older encrypted `.jpg.hbnvr` only for missing/denied GETs.
Without `ListBucket`, absent objects may return 403: an all-denied result remains an
error, never proof of missing footage. Decryption or validation failures do not fall
through to an alternate plaintext object. Future midpoint slots are not requested.

The optional HBNVR-PBE envelope is authenticated/decrypted in RAM. The JPEG's embedded
IPTC caption must identify the expected store, camera and UTC slot, with a frame time
at or before that slot and at most 120 seconds earlier. Reads are bounded to 8 MiB plus
envelope overhead; JPEG dimensions are bounded to the recorder's 1280×720 maximum.
ImageIO downsamples to the requested bounding box without upscaling before the existing
48-image RAM cache. Hiding the timeline, backgrounding, changing camera/destination or
changing unlocked credentials cancels obsolete work and clears previews. No decrypted
image is written to disk. Missing previews retain the existing "No preview" appearance;
their absence says nothing about the availability of video in the surrounding interval.

HBNVR 0.16.0 begins publishing prospective, per-camera playback indexes under
`<prefix>.hbnvr/playback/v1/<lowercase-camera-UUID>/`. `catalog.json` names known
UTC days; `days/YYYY-MM-DD.json` indexes the open day, while
`months/YYYY-MM.json` contains complete shard entries for closed days. Today is
excluded from the monthly aggregate. Late backlog uploads update the affected
day and month. The phone uses monthly entries for older footage, not a rolling
24-hour/30-day window. Catalog publication follows the referenced period updates;
short session caches are refreshed to discover late uploads.

Only confirmed video uploads enter the recorder's durable private metadata
journal. Cloud publication is serialized, coalesced, retryable and independent
of video upload success. Shards crossing UTC midnight appear in both relevant
days and are deduplicated by identity. Indexes are encrypted with the same
HBNVR-PBE format when client encryption is enabled. Losing the recorder's journal
loses its previous searchable cloud history; neither app nor recorder lists the
bucket or reconstructs old indexes. **Already uploaded, unindexed recordings are
not automatically backfilled.** Old spool entries without timing remain safely
uploadable but cannot enter this new index.

The app verifies each object's frozen size and SHA-256, authenticates the entire
AES-GCM envelope (PBKDF2-HMAC-SHA256, exactly 600,000 iterations), then demuxes
compressed H.264/H.265 samples in RAM. Embedded timing/identity must match the
index. There are no temporary MP4s, decrypted disk caches, AWS environment
credentials, reads through Homebase, or additional IAM permissions. The AWS SDK
for Swift is pinned to 1.7.78. Requests have a 45-second deadline, bounded bodies,
no automatic retries or redirects, and sanitized diagnostics.

Playback limits: catalog 4 MiB, individual period manifest 64 MiB / 100,000
entries, individual shard 256 MiB, response 64 MiB / 30,000 samples. Very dense
monthly indexes or unusually large/long shards may exceed these mobile bounds
and produce an explicit error. The existing five-minute history-buffer bound
still applies. One decrypted shard of at most 16 MiB may be retained for adjacent
refills; closing or authorization loss cancels readers and clears keys, object
caches and media buffers. Backgrounding preserves the paused cursor, not cloud
credentials. Transient system UI concealment does not restart authentication.

An AWS error is not evidence of a recording gap. Missing/expired objects, a
missing initial catalog, bad credentials, wrong passwords and corrupt objects
report retrieval errors. Successfully read local intervals remain usable while
failed cloud intervals remain unknown and retryable. S3 Access remains reachable
from an error state for credential repair. Only successful index reads can
establish that no indexed footage covers a requested time. Indexes may refer to
objects already expired by bucket lifecycle; the recorder does not delete cloud
objects or claim authoritative expiration knowledge.

Relative Live-minus requests still resolve on the NVR; the latest S3 upload is
never treated as Live. An absolute seek can fall back with NVR offline: its
selected UTC timestamp and embedded frame timing remain exact, while the phone
wall clock supplies only an approximate forward-play ceiling until a server
anchor is available. This does not synchronize unrelated live camera feeds.

Opt-in real-AWS smoke (use an explicitly designated test store; no permissions
are broadened): install HBNVR 0.16.0 and the updated Homebase, then the app. Record
new synthetic/test-camera footage and wait for manifest publication. Unlock a
separate GetObject-only reader key in the app. Seek to a time outside the first
local store but present in S3; verify video, timestamp, pause, refills and camera
switching. For a mixed local/cloud window verify local pictures are preserved.
Repeat with network interruption, incorrect password and denied object access;
expect retryable errors, not fabricated gaps. Restore credentials, retry, then
background/relock and ensure no cloud read resumes until camera access is
authorized. Administrative/read tooling may separately verify manifests and
objects; never add ListBucket or GetObject to the recorder's write-only key.

On-device authentication smoke checks:

- With no saved S3 credentials, enter Cameras: chips stay black until the system
  authentication decision. Cancel should leave them locked; Unlock retries.
- Background and return, and leave/re-enter Cameras. Each starts a fresh lock
  session. Opening fullscreen and switching cameras should not ask again.
- With HBNVR 0.15.1 advertising S3, seek to missing local video. Check the leading
  padlock and credential sheet. Cancel must save nothing. Saving a test reader
  key requires biometrics and reports only a Keychain save, not AWS validation.
- After saving credentials, leave and re-enter Cameras. Face ID should appear
  instead of immediately repeating a Keychain -25308 error. Success should
  unlock both the page and readable credentials without deleting/re-entering them.
- Cancel the entry prompt: the page stays locked. Revoke Face ID access in
  Settings: the normal unavailable-biometry UI policy permits camera viewing,
  but protected S3 credentials stay locked. Restore permission and use Unlock
  saved credentials from the S3 padlock. A failed retry must not lock cameras.
- Injected tests cover Keychain inspection/read failures after successful Face
  ID: local camera access remains available, with S3 still locked and retryable.

## Verification

The S3 tests cover scoped SDK-signed GETs, bounded/cancellable responses,
authenticated decryption (including an independent known-answer fixture),
synthetic H.264/H.265 MP4 demuxing, daily/monthly index selection, local-first
gap filling, offline absolute seeks, credential replacement, and clearing media
on authorization loss. These are synthetic tests, not a real-AWS validation;
use the opt-in smoke procedure above for an explicitly designated bucket.

`CameraLivePlaybackTests` exercises timing, limits, eviction, pause/seek semantics,
decoder preroll, lifecycle, and separation from Photos using synthetic H.264.
Injected-clock tests also check 1×/2×/4× pacing, rate changes while paused,
live-edge slowdown without switching modes, shared multi-camera pacing, and
speed-aware bounded history refills versus ordinary cache exhaustion.
It needs no server, camera, or saved footage. Run the full `HomeBase-GUI` scheme's
tests on macOS and an iOS simulator.
`CameraLivePlaybackPresentationTests` also checks History and Live symbols,
Live's no-op action while live and its size-class-dependent label, native shuttle
grouping and separation, and Close sizing against an unmodified system button.
It verifies UIKit's secondary item groups and captures compact- and regular-width
toolbar adaptation in both Live and History, including wide windows with compact
traits to avoid orientation-based assumptions, and checks
the native camera gesture recognizers' availability on iOS.
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

Manual phone check: open a camera. Close, Play-Pause, and Live are present
immediately; speed, the timeline, and PTZ sliders are absent. In regular width,
the two 30-second shuttles share the Play-Pause capsule and Live has its title.
In compact width, the shuttles and camera settings are in the system overflow,
Live is icon-only, and Record and camera selection remain trailing. At bottom
right, History precedes PTZ in one neutral glass capsule. Tap PTZ: only its tinted
icon remains, supported sliders appear together, and no camera setting changes.
Tap again: both icons return. Tap History: only its tinted icon remains and the
timeline appears underneath the capsule, which animates to the timeline's vertical
center without changing its horizontal anchor. Tap History again to hide it and
animate the capsule back to its bottom safe-area anchor in the same panel transition.
There is no separate handle or vertical show/hide gesture. Top-bar camera
controls and gestures remain usable while Live. Horizontal timeline scrubbing
still seeks. Verify full-size thumbnails with one camera, whether Multiple is on
or off, and compact sizing with two or more cameras. Open the picker: Multiple
starts selected at the trailing edge without changing the one-camera controls
or adding a label. Add a second camera, then remove either one: the survivor's
full controls return with no stream reload or lost pause/cursor/buffer state.
Toggle visibility while paused and
playing, confirming no playback state changes. In portrait, allow the system's
native navigation-bar adaptation; there is no bespoke row layout.
Seek to an empty time and use the gap arrows to find the preceding/following
recording; missing directions are absent and paused jumps remain paused.
Pause: in compact width, speed replaces Record on the trailing side. In regular
width, speed appears beside Live and Record stays visible but disabled. Quality,
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
