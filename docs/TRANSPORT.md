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
