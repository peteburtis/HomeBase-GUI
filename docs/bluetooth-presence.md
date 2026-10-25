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
a healthy stream. Immediate stream retries are bounded, with at most three
recovery attempts per five minutes on a connected link even if a short session
successfully opens between failures. The budget is checked only when events
arrive, using monotonic time; it has no wakeup timer. An explicit Reconnect
button resets this budget and permits recovery without CnC. A single setup deadline is canceled
after acknowledgement and is not used to measure presence.

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
uncertain work instead of repeating it in a new session. Request deadlines
remain absolute across route changes.

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

Presence retains its prototype bearer-token enrollment rooted in the existing
CnC connection. The separate control upgrade below never accepts that bearer
as authority for ordinary CnC commands.

## Physical-device observations (2026-10-25)

The installed initial client reports Not Nearby when the phone's Bluetooth is
turned off and Nearby after it is turned back on. Force-quitting the app drops
presence while iOS may retain the accessory's system connection. Manually reopening
that client did not recover presence until a Bluetooth power cycle. Source fixes
now distinguish local connection ownership from system connectivity and defer
restored discovery until CoreBluetooth is ready; this relaunch fix still needs
installation and verification on the physical phone.
