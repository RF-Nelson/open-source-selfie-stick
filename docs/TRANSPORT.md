# Networking & transport

Pair & Shoot connects the two devices with a **layered transport** (`LayeredTransport` in
`PairAndShootCore`), behind the `PeerTransport` protocol. **Bluetooth (Core Bluetooth) is the
always-on primary** — discovery, the 4-digit pairing, control, and a slow file fallback — and once
it connects, the two devices bootstrap a **Multipeer (Wi-Fi/AWDL) "fast lane"** over the Bluetooth
link and route full-resolution file transfers across it whenever they're reachable (same network).
Wi-Fi Aware (iOS 26) stays as an experimental opt-in.

This replaced the original Multipeer-only design after on-device testing (below) proved peer-to-peer
Wi-Fi can't connect off-network. The transport files:

- `LayeredTransport` — composes the two legs, presents them as one peer, routes control over
  Bluetooth and files over Wi-Fi when up. The default via `TransportFactory`.
- `BluetoothTransport` + `L2CAPStreamHandler` — Core Bluetooth; the camera advertises, the remote
  connects, and they meet on an L2CAP channel framed with `MessageFraming`.
- `MultipeerTransport` — the Wi-Fi fast lane (and the standalone transport the layered one wraps).
- `WiFiAwareTransport` — the iOS 26 opt-in.
- `FakeTransport` — tests/previews.

## What works, confirmed on hardware

| Both devices' network | Result | Notes |
|---|---|---|
| Same Wi-Fi network | **Full speed** | Control over Bluetooth; files over the Wi-Fi fast lane. |
| Different / no network, Bluetooth on | **Works** | Control + slow file transfer over Bluetooth L2CAP — no Wi-Fi at all (verified with the remote in Airplane Mode). |
| Off-network Multipeer alone (no Bluetooth) | **Does not connect** | Discovers the peer but the data channel never forms (`connecting -> notConnected`), even with both Wi-Fi radios free. This is why Bluetooth is the primary. |

## Measured file throughput (≈900 KB HEIC)

| Channel | Time | Throughput |
|---|---|---|
| Bluetooth L2CAP | ~29 s | ~28 KB/s |
| Wi-Fi fast lane (Multipeer) | ~0.6 s | ~1,511 KB/s |

Wi-Fi is ~54× faster, so files use it whenever the fast lane is up and fall back to Bluetooth
otherwise. There is no live video preview in the app, so Bluetooth alone carries the whole experience
(commands, camera state, the pairing handshake, and the small post-shot thumbnail all travel as
messages) — only full-resolution send-back benefits from the Wi-Fi lane.

## How the Wi-Fi fast lane is bootstrapped

1. Bluetooth connects (L2CAP). The model sees one peer, one transport; the 4-digit code is verified
   over the Bluetooth channel.
2. The camera mints a random rendezvous token and sends it to the remote over a **tagged control
   lane** on the Bluetooth message channel (a leading lane byte: 0 = app, 1 = layered control).
3. Both start Multipeer keyed to that token (discovery info + invitation context). The remote invites
   the peer carrying the token; the camera accepts only that token — so the already-paired Bluetooth
   link authenticates the Wi-Fi leg (no second code).
4. If they're on the same network, Multipeer connects in ~2 s and files route over it; otherwise it
   never comes up and files fall back to Bluetooth. The `ChannelPill` in the UI reflects this
   ("Bluetooth" vs "Wi-Fi"), driven by the transport's `fileChannelFast` event.

### A note on threading
All of `LayeredTransport`'s event handling is marshaled to the main actor (`MainActor.run`). The BLE
`L2CAPStreamHandler` streams live on the main run loop, so calling into them from a background stream
task races the outgoing buffer — a real crash we hit and fixed (concurrent `Data` mutation →
`EXC_BREAKPOINT`, camera-only).

### Self-healing
The fast lane also **re-establishes after a drop** (AWDL is flaky): on a Wi-Fi-leg disconnect the
camera re-advertises and the remote re-browses with the same token (3s debounce), so it recovers on
its own and deferred files flush when it returns.

## Smart send-back (deferred delivery)

Delivery of full-resolution captures is decoupled from the user's intent ("I want copies"), because
the channel is dynamic — a static "send back" setting would strand the user on whichever channel they
happened to be on. The thumbnail (in `CaptureResult.thumbnailJPEG`) always lands instantly on both
channels; the full file is delivered like this:

- **Fast lane up:** the camera sends the original automatically — photo on both phones in ~1–2 s.
- **Bluetooth only:** the camera *holds* the file (doesn't slow-push it). The capture arrives with
  `CaptureResult.fileAvailable == true`, and the remote shows a **Download** button. Tapping it warns
  with the size and estimated seconds over Bluetooth and offers **Full / Reduced / Small** (the camera
  re-encodes photos smaller via ImageIO for the compressed choices). Live progress on both ends; either
  side can cancel (Multipeer `Progress.cancel`; a Bluetooth `fileCancel` frame that stops the paced
  producer on a frame boundary). One download at a time; the shutter is paused during a download.
- **Auto-flush:** when a fast lane appears, everything still pending flushes at full quality —
  "leave on Bluetooth, come back on Wi-Fi, the photos land."
- **Never stranded:** if an automatic Wi-Fi send fails (lane drops mid-transfer), the camera re-offers
  the capture as a Bluetooth download (re-sends the `CaptureResult` with `fileAvailable = true`; the
  remote upserts captures by id).

**Correlation.** Every capture's file transfer is named `<captureID>.<ext>` (`TransferName`), so the
receiver ties an arriving file to its capture regardless of quality; the compressed copy is a separate
temp file so it never clobbers the held original (which is kept for repeat/full downloads and wiped on
disconnect). BLE file send is **paced** — the `L2CAPStreamHandler` pulls one ~16 KB chunk at a time via
`nextChunk`, so memory is bounded and a cancel is clean; completion fires only when the buffer is empty
*and* there's space *and* the producer is exhausted (an empty buffer with a full kernel just waits).

**Protocol (version 3).** `CaptureResult.fileAvailable`; `RemoteCommand.requestFile(id, quality)` and
`.cancelTransfer(id)`; `TransferQuality` (full/high/medium); a `fileChannelFast(Bool)` transport event
(drives the `ChannelPill` and the defer/auto decision); and `PeerTransport.supportsFileTransfer` /
`cancelFileSend()`.

## Historical: why the original Multipeer-only design was abandoned

MultipeerConnectivity builds its encrypted data channel with ICE + DTLS over a **Wi-Fi** path —
infrastructure or AWDL — which needs the Wi-Fi radio on and, in practice, a shared network. On
modern iOS it does **not** carry the data session over classic Bluetooth (Bluetooth only assisted
discovery); off-network attempts loop `connecting -> notConnected`, confirmed on two device pairs.
That OS limitation drove the Core Bluetooth primary + Wi-Fi fast lane design above.

## Wi-Fi Aware transport — implementation design (iOS 26+)

Verified against the iOS 26.5 SDK (`WiFiAware` + the new Swift `Network` API). Entitlement
`com.apple.developer.wifi-aware` (values `Publish`,`Subscribe`) is self-serve (no Apple approval),
enabled on the App ID; `WiFiAwareServices` declared in Info.plist (`_pairandshoot._udp`).

**Data channel.** Use the new Swift Network API with a Codable message protocol — no manual framing:

```
// ApplicationProtocol: JSON-coded frames over TCP
Coder(WAFrame.self, using: .json) { TCP() }
// send:    try await connection.send(frame)          // frame: WAFrame (Codable)
// receive: for try await m in connection.messages { handle(m.content) }
```

`WAFrame` is a transport-level enum carrying opaque app messages and file transfer:
`case message(Data)`, `case fileBegin(id,name,size)`, `case fileChunk(id,Data)`, `case fileEnd(id)`.
(Chunks are base64 in JSON — fine for v1 over fast Wi-Fi Aware; a binary `Framer` can optimise later.)

**Roles → Network API:**
- Camera (`startAdvertising`) → `NetworkListener(for: .wifiAware(.connecting(to: WAPublishableService, from: .allPairedDevices))) { Coder… }`, then `listener.run { connection in … }` — each incoming connection is a remote.
- Remote (`startBrowsing`) → `NetworkBrowser(for: .wifiAware(.connecting(to: .allPairedDevices, from: WASubscribableService)))`, `browser.run { endpoints in … }` → emit `.peerFound` per `WAEndpoint`.
- Remote `invite(peer)` → `NetworkConnection(to: waEndpoint) { Coder… }.start()`; on `.ready` emit `.connected`, start the receive loop.
- Peer identity: `WAEndpoint.device` (`WAPairedDevice`, id: UInt64, name) → our `Peer`.

**Key integration point — pairing is system-level.** Wi-Fi Aware devices must be paired by the OS
first (persistent `WAPairedDevice`); there is no in-app PIN. So on this path our 4-digit
challenge/pair handshake must be SKIPPED — the camera accepts the connection and goes straight to
`connected`. Add `PeerTransport.requiresAppLevelPairing` (Multipeer: true, Wi-Fi Aware: false);
`CameraHostModel`/`RemoteModel` skip the challenge/pair and treat a Wi-Fi Aware connection as paired
(camera sends hello+state immediately; remote is paired on hello). The system pairing UI itself is
presented with `DeviceDiscoveryUI` (a device picker) the first time — requires the "Device Discovery
Pairing Access" capability; pairing then persists.

**Transport selection:** a factory picks `WiFiAwareTransport` when `#available(iOS 26)` AND
`WACapabilities.supportedFeatures.contains(.wifiAware)`, else `MultipeerTransport`. Both phones must
be on iOS 26 to use Wi-Fi Aware; a mixed pair uses Multipeer (and needs Wi-Fi, per the table above).

**Build order:** (1) `WAFrame` + `WiFiAwareTransport` conforming to `PeerTransport` (compile);
(2) `requiresAppLevelPairing` + model skip-pairing; (3) transport-selection factory in the app;
(4) `DeviceDiscoveryUI` pairing screen; (5) on-device test between the two iOS 26 phones.
Steps 1–3 compile and unit-test on this Mac; 4–5 need the devices.

## Wi-Fi Aware — on-device findings & the connection-lifetime fix (2026-08-25)

Tested between two iPhone 17 Pro Max on iOS 26 (Camera + Remote). Discovery, the system pairing
sheet, invite, and the data connection reaching `.ready` all work. The blocker was a
structured-concurrency lifetime bug in our own code, now fixed.

**The bug.** On `.connected`, `CameraHostModel` calls `transport.stopAdvertising()` to stop accepting
further remotes. In `WiFiAwareTransport` the accepted connection is created *inside*
`listener.run { connection in await adopt(connection) }`, so its lifetime is owned by the listener
task. `stopAdvertising()` cancelled that task, which cancelled the live connection →
`NWError 89` (canceled) on the camera's first `send(.hello)`, and a clean EOF ("messages ended") on
the remote. Trace showed every attempt as `preparing → ready → (instant) messages ended →
markDisconnected`.

**The fix.** `stopAdvertising()` now no-ops while a connection is live (`connection != nil`). A
OneToOne `NetworkListener` won't hand us a second peer while the first is being handled, so leaving
the listener task running is safe; discovery restarts on disconnect. The transient
"Turn WiFi on for a reliable link" banner is a `.waiting` hint during `preparing`, not the failure
cause — the data path does reach ready even with Wi-Fi on-but-not-joined.

**Two WA UI adjustments.** (1) The pairing control (`DevicePairingView` / `DevicePicker`) hides once
`WAPairedDevice.allDevices` is non-empty — while visible it publishes/subscribes the same service as
the transport and collides (`NWError -11999` / `-11988`); after pairing, the transport owns the
service. (2) The remote's "You are <name>" hint is shown only on the code-pairing path
(`requiresCode`); on Wi-Fi Aware iOS presents system-assigned device names itself.

**Debugging without syslog.** `idevicesyslog` is unreliable on this hardware, so the app writes a
`Trace` log to `Documents/transport.log`, pulled with
`devicectl device copy from --domain-type appDataContainer --domain-identifier <bundle id>
--source Documents/transport.log`. `Trace.reset()` clears once per launch so reconnect churn
accumulates into one file. Strip or keep the `Trace` calls at release (they no-op if the file can't
be written).
