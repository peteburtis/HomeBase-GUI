# Bluetooth presence

From a connected server's Settings, choose **Bluetooth Presence → Pair This
iPhone** and select its HomeBase accessory. The existing WebSocket CnC session
issues an opaque enrollment credential; there is no second account or PIN.
After enrollment, Bluetooth presence operates independently of the selected
server, Settings screen, Wi-Fi, and VPN. The foreground app can also use an
encrypted Bluetooth control channel when its preferred network connection is
unavailable. Video and recordings still require a network connection.

The iPhone is the BLE central. The Mac advertises the shared HomeBase service,
a readable controller identity, and a recovery-notification characteristic.
AccessorySetupKit authorizes access to the accessory. Before sending a token,
the phone checks the GATT identity against the controller ID obtained over CnC.
It then subscribes to recovery, opens the current L2CAP PSM, and sends one
`bluetooth.presence.open` request using the existing HomeBase envelope and a
bounded four-byte-length frame. The acknowledgement must match the request,
controller, and phone registration. Future capabilities can reuse this framing.

After the presence handshake the channel remains idle unless the foreground
app needs Bluetooth controls. There are no application presence heartbeats or
periodic presence timers. The controller observes stream/radio
loss and applies its departure grace period. Bluetooth-off, an empty battery,
radio interference, and actual departure can all make a phone unreachable;
the Boolean means reachable nearby, not proof that a person left the building.

`BluetoothPresenceService` owns enrollment independently of views. Intent,
token, controller ID, and selected peripheral are saved transactionally in the
device-only Keychain before the token is sent. After a peripheral is selected,
pending enrollment survives a lost acknowledgement or process exit. Dismissing,
timing out, or failing discovery before selection cancels that attempt and
returns Settings to **Pair This iPhone**. An unselected attempt found at launch
is canceled too. Its offer is invalidated immediately over connected CnC; if
that connection is unavailable, a hidden durable cleanup record retries on
reconnection after verifying the controller identity. A new attempt waits for
that cleanup rather than reusing the canceled token. CoreBluetooth restoration is initialized
by the existing application delegate at launch. A freshly retrieved peripheral
always establishes this app's local connection, even when iOS already shows the
accessory as connected. A genuinely restored connection retains its ownership,
but discovery waits for the manager's powered-on callback. Restored peripheral
delegates are reassigned and the current GATT identity/PSM is read again because
streams are not restorable. An out-of-range connection request remains pending in iOS.
A controller recovery notification reopens an absent stream without replacing
a healthy stream. A physical disconnect after an authenticated session immediately
submits another connection request. A disconnect during unfinished setup uses
the failure cooldown. Transient discovery, stream, and setup failures reset the failed local
connection and retry with 1, 2, 4, 8, 16, then at most 30 seconds of delay, without
an attempt limit. The app enforces this cooldown before issuing a plain
`connect` request, so immediate framework rejection cannot bypass the delay.
Retry and setup deadlines use `ContinuousClock`, which advances across device
sleep. Once a connection request is submitted, CoreBluetooth owns the indefinite
out-of-range wait. A short successful session does not reset the backoff; a
connection that lasted at least a minute does. Identity and authentication
rejection remain terminal until an explicit Reconnect, with no token sent to an
unexpected controller.

The enrollment service observes application lifecycle once, independently of
tabs and WebSocket routing. A true background-to-foreground transition refreshes
the presence handshake over an owned Bluetooth connection, or repairs stale
pending state if the peripheral is disconnected. Valid OS-owned connection
requests and unexpired setup attempts are retained. Permission dialogs and other
transient inactivity do not cause refreshes. Pending control callers survive the
refresh; a previously attached Bluetooth control transport reopens normally.
The server's departure grace covers a prompt replacement presence handshake.

GATT/L2CAP/presence setup has one 25-second deadline and a finite UIKit background
task. Success, failure, or expiration ends that task. A separate finite background
task protects a scheduled retry cooldown. If that allowance expires, the app ends
the assertion and retains the retry deadline for foregrounding or a later system
wake; it does not skip the delay or repeatedly request more background time.
These tasks cannot guarantee execution while suspended, and neither is held
waiting for radio range. Foreground reconciliation resumes any due retry.
Unified logs in `io.pjb.HomeBase-GUI` / `BluetoothPresence` record lifecycle,
radio, setup, authentication, retry, and stream transitions with correlation IDs
and framework error codes, excluding credentials and message contents.

Remove Pairing disables the local transport immediately and stores a removal
tombstone. Server deletion is retried when that saved server's CnC connection
returns. The tombstone is retained until both the server and AccessorySetupKit
have completed removal; a delayed system activation or error cannot silently
discard pending accessory cleanup. Simply viewing or dismissing Settings does not create, rename, or
remove a registration. Phone display-name changes preserve registration IDs.
Forgetting a saved server also disables its Bluetooth registration. If the
server is added again under a new local ID, queued removal is reconciled only
after its CnC controller identity matches the original registration.
On macOS the Settings section explains that enrollment is performed on iPhone;
the GUI does not start a Bluetooth manager there.

## Encrypted control fallback

An existing paired phone automatically obtains an independent random 32-byte
control credential through `bluetooth-control cnc enroll` on its working
WebSocket session. New presence enrollment triggers the same upgrade when it
finishes. The credential, key ID, controller ID, registration ID, and persistent
client ID remain in the device-only Keychain. The WebSocket credential response
is acknowledged before that logical session can resume over Bluetooth. Viewing
Settings does not enroll a new phone or change remote configuration.

The phone proves the new credential with
`Noise_NNpsk0_25519_ChaChaPoly_SHA256`, bound to the controller, registration, and
key IDs. The client confirmation is the first encrypted record. Only then can
ordinary HomeBase envelopes use the channel. The presence bearer cannot open
this control channel. A restored background presence link never creates control
demand on its own.

The WebSocket client remains the sole owner of requests, subscription state,
and delivery checkpoints. Startup gives a responsive network connection up to
one second of preference; an immediate network error lets ready Bluetooth
proceed immediately. Readiness probes race, but only one selected route resumes
the logical session. During handover, the old reader stops before the checkpoint
is captured. Pending requests retain their IDs and order and are replayed only
after that same session successfully resumes. A rejected/expired session fails
uncertain work instead of repeating it in a new session. All resume paths,
including foreground route recovery and network failback, then automatically
open a fresh session. Live monitoring reloads its snapshots and subscriptions;
commands and configuration writes are never repeated in the replacement session.
Requests built before a handover are also prevented from crossing into a new
session. Request deadlines remain absolute across route changes.

While the app is in the foreground on Bluetooth, a network-path change or a
15-second retry checks WebSocket availability. Failback requires a successful
probe session and another successful response at least one second later. The
network-path health check has a two-second deadline. A failed probe leaves the
working Bluetooth session intact. These are foreground control checks; none
measure presence or wake the background app periodically.

Backgrounding or changing away from a control connection detaches its logical
Bluetooth session while retaining Noise and idle physical presence. A later
foreground attachment starts with session.open/resume. Attachment IDs fence old
detach events, and old queued deliveries are discarded until the matching new
attachment response arrives. A fresh physical stream uses a fresh Noise
handshake. Each negotiation has one finite timeout.

The application uses one FIFO logical command lane, fragmented into bounded
16 KiB encrypted records, with a 16 MiB message maximum and 32 MiB/4,096-message
outgoing queue limits. Attachment changes cannot overtake a partially sent
command. The framing supports future independent lanes, but this implementation
preserves request and delivery order. The UI identifies Bluetooth routing and
explains that camera video and recordings require the network.

## Connection feedback

The server's tab container owns one connection indicator, centered above the
native tab bar across the full window. `ConnectionStatusController` combines the
actual transport state with loading and failure reports from visible screens.
Hidden tabs and dismissed views remove their reports, so an old screen cannot
leave a stale indicator behind. The connected state uses green radio waves for
WebSocket and a blue Bluetooth symbol for Bluetooth. Bluetooth loading shows a
gray Bluetooth symbol before the spinner; network loading has no transport icon.

On return to the foreground, connection and monitoring failures have a fixed
two-second grace period showing Connecting. Successful recovery is displayed
immediately; a failure that remains when the grace period ends is shown with its
normal retry action. New reports do not extend the deadline, and pending work
continues to show its loading state. Background teardown errors stay concealed
while the app is inactive. Active control screens also report loading while
waiting for their monitoring task to start or finish cleanup from the prior run.
An expired session stays in Connecting while the app opens a fresh connection;
it is not itself a user-facing failure. If that fresh connection fails, its
actual connection error and retry action are shown. Session recovery details
remain in diagnostic logs rather than asking the user to rebuild subscriptions.

Screens use `connectionStatusReport` to contribute status and reserve scroll-end
room, or `connectionStatusClearance` when they only need the spacing. The clearance
tracks the rendered indicator height, including larger text and error messages.
Fixed footers use `ConnectionStatusSpacer` to leave the same room below their controls.
Sheets and full-screen content disable the scope because they cover the tab host.

## Validation boundaries

Unit tests use injected transport, storage, and CnC commands to check enrollment
ordering, automatic discovery cancellation, offline offer cleanup and migration,
selected-peripheral restart recovery, fresh-process connection ownership,
restoration-before-radio-readiness, pending connection deduplication, radio power
cycling, healthy session preservation, stale callbacks after removal or retry,
offline deletion, unchanged renames, controller identity rejection, and
acknowledgement matching. Control tests cover preferred-route selection,
same-session recovery, mutation receipt replay and absolute deadlines, ordered
pending requests, stable failback, preserved subscriptions, credential upgrade,
attachment generations, bounded mailboxes, and encrypted queue ordering.
Foreground regressions cover expired retained sockets, expired Bluetooth
attachments, concurrent parent/child recovery, unavailable fallback, failed
fresh connections, cancellation during recovery, and live updates after a new
session.
Simulator/build results cannot establish radio range, battery cost, suspended
L2CAP behavior, or AccessorySetupKit relaunch behavior.

Before relying on this for automations, test on a physical Mac and iPhone:

1. Pair over CnC, then disable Wi-Fi and VPN; verify presence remains available.
2. Lock the phone, leave it idle overnight, walk out of range, and return. Check
   the Boolean transitions and record detection latency and battery consumption.
3. Repeat after iOS terminates the app and after manually force-quitting it.
   After force-quit, manually reopen the app while iOS still shows the accessory
   connected; presence must return without toggling Bluetooth or reopening Settings.
   Check AccessorySetupKit/CoreBluetooth restoration on the supported iOS release.
4. Restart both devices, unlock the phone once, toggle Bluetooth, and restart
   the controller process while still nearby. Check stream and PSM recovery.
5. Pair two phones, move them independently, rename one, and remove one while
   CnC is offline. Check the other registration remains unaffected.
6. Dismiss or time out discovery before selection; verify Settings returns to
   Pair This iPhone, including after relaunch with CnC offline. Interrupt setup
   after accessory selection and server acknowledgement; relaunch and resume,
   ensuring no duplicate phone controls and preservation of the selected token.
7. Select a different nearby HomeBase controller during setup. Verify identity
   mismatch is shown and no registration token is sent to that controller.
8. With WebSocket available, leave and return while presence is disconnected,
   then foreground the app without force-quitting. Confirm presence recovers;
   repeat with only Bluetooth available and with several setup failures. Check
   that retries continue after the old attempt limit and capture both devices'
   `BluetoothPresence` logs if recovery stalls.

Presence retains its prototype bearer-token enrollment rooted in the existing
CnC connection. The separate control upgrade never accepts that bearer
as authority for ordinary CnC commands.

## Physical-device observations (2026-10-25)

The installed initial client reports Not Nearby when the phone's Bluetooth is
turned off and Nearby after it is turned back on. Force-quitting the app drops
presence while iOS may retain the accessory's system connection. Manually reopening
that client did not recover presence until a Bluetooth power cycle. Subsequent
fixes distinguish local connection ownership from system connectivity and defer
restored discovery until CoreBluetooth is ready; relaunch now restores presence.

A later outing exposed an earlier connection failure: the Mac logged link loss
at 18:13:19, presence became Not Nearby at 18:13:30, the door opened on return at
19:00:53, and relaunch restored presence at 19:08:17. Phone diagnostics were not
available to identify the stalled branch. Foreground reconciliation, native
connection requests with app-enforced retry cooldowns, bounded setup/retry
activity, and lifecycle logging address the known recovery gaps. A full outing
and return with the updated client still needs device validation.

A device test of the first recovery implementation connected initially with a
zero `CBConnectPeripheralOptionStartDelayKey` value. After the daemon restarted,
subsequent connection requests failed immediately with `CBErrorDomain` code 1
(`invalidParameters`), bypassing the requested native delay and producing a rapid
retry loop. The implementation now omits that option and enforces cooldowns in
the app. This removes the dependency on CoreBluetooth applying a delay before
rejecting a request. With the corrected build on Parkaboy, a controller restart
at 19:45:19 restored authenticated presence at 19:45:22 without restarting the
phone app (about 2.5 seconds after advertising resumed). The precise reason the
framework rejected the earlier connect options is not established.

A second restart at 19:45:54, after iOS suspended the app, did not restore
presence during the next roughly 36 seconds. Phone logs showed no intervening
app recovery callbacks. Bringing the same process forward at 19:46:30 restored
authenticated presence at 19:46:31, without force-quitting or Bluetooth cycling.
This verifies foreground recovery but leaves daemon-restart wakeup while fully
suspended as a known limitation; it does not establish out-of-range return
behavior. The installed app includes the `bluetooth-central` background mode.
