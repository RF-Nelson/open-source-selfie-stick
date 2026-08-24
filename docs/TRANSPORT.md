# Networking & transport

Pair & Shoot talks between the two devices through **MultipeerConnectivity**, behind the
`PeerTransport` protocol in `PairAndShootCore` (only `MultipeerTransport` imports the framework).

## What works, and what doesn't

Confirmed on hardware (iPhone 17 Pro Max + a second iPhone, iOS 26), 23 Aug 2026:

| Both devices' network | Pairing & control | Notes |
|---|---|---|
| Same Wi-Fi network | **Reliable** | The intended setup. Photos/video, flash, timer, send-back all work. |
| Personal Hotspot (one phone hosts, the other joins) | **Expected reliable — untested** | Puts both on a real shared subnet with no router; MultipeerConnectivity should behave like same-network. Worth confirming. |
| Wi-Fi **on**, no network joined (peer-to-peer / AWDL) | **Does not work in practice** | Reached "connected" once, briefly, then dropped; not one photo could be taken. AWDL alone is not usable here. |
| Wi-Fi **off**, Bluetooth on | **Does not connect** | Discovery happens, but the session never forms. |

## Why Bluetooth-only fails

MultipeerConnectivity builds its encrypted data channel with ICE + DTLS over a **Wi-Fi** path —
either an infrastructure network or Apple Wireless Direct Link (AWDL, "peer-to-peer Wi-Fi"). AWDL
needs the **Wi-Fi radio powered on**. On modern iOS the framework does **not** carry the data
session over classic Bluetooth; Bluetooth only ever assisted *discovery*. Device logs from a
Wi-Fi-off attempt show the session looping `connecting -> notConnected`, with
`DTLSState=DTLSNotConnected` and flows falling back to cellular — i.e. no usable path, so the
handshake can't complete. This is an OS limitation, not an app bug.

**Practical guidance:** the only confirmed-reliable setup is a **shared Wi-Fi network**. When there
is no network available, the way to get one without a router is **Personal Hotspot** on one phone,
joined by the other (a manual toggle — iOS has no API for an app to create a Wi-Fi AP). Relying on
peer-to-peer Wi-Fi (AWDL) alone did not work in testing, so it should not be presented as an option.

## If true Bluetooth-only is required (future work)

To control the shutter with Wi-Fi entirely off, the app would need a **Core Bluetooth (BLE)**
transport — a second `PeerTransport` implementation using a GATT service for the command/event
channel. This is feasible because the wire protocol is small typed messages. The catch is
throughput: BLE moves only a few KB/s, so photo/video **send-back would be impractical** — media
would have to stay on the camera (which the app already supports). Scope: a new
`BluetoothTransport`, a small chunking layer for messages, and a transport picker in the UI. Not
built yet; tracked here pending a decision.

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
