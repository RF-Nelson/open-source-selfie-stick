import Foundation

/// Bluetooth-primary, Wi-Fi-accelerated transport. Core Bluetooth is the always-on base — discovery,
/// the 4-digit pairing, control messages, and a slow file fallback — so a remote can drive a camera
/// with no Wi-Fi at all. Once the BLE link is up, the two devices bootstrap a Multipeer (Wi-Fi/AWDL)
/// "fast lane" over that very link and route full-resolution file transfers across it whenever it
/// comes up (i.e. when they're on the same network); otherwise files fall back to Bluetooth.
///
/// The model above sees ONE peer and one `PeerTransport`. The Wi-Fi leg is internal plumbing: it never
/// surfaces as a second connection, and it carries no control — only files. Both devices must run this
/// transport (it multiplexes an app/control lane byte over the BLE message channel).
public final class LayeredTransport: PeerTransport, @unchecked Sendable {
    public let localPeer: Peer
    public let events: AsyncStream<TransportEvent>
    public var supportsFileTransfer: Bool { true }   // BLE always; Wi-Fi accelerates when reachable

    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let ble: BluetoothTransport
    private let wifi: MultipeerTransport
    private let lock = NSLock()

    private enum Role { case none, camera, remote }
    /// First byte of every BLE message payload: the app's own bytes vs. our internal control.
    private enum Lane: UInt8 { case app = 0, control = 1 }
    /// The one internal control message: the camera hands the remote the Wi-Fi rendezvous token.
    private struct Control: Codable { let token: String }
    /// Key under which the token travels in the Multipeer discovery info + invitation context.
    private static let tokenKey = "lt"

    private var role: Role = .none
    private var primaryPeer: Peer?   // the BLE peer shown to the model
    private var token: String?       // Wi-Fi rendezvous token for this connection
    private var wifiPeer: Peer?      // the Multipeer peer once its leg connects
    private var wifiUp = false

    public init(displayName: String) {
        ble = BluetoothTransport(displayName: displayName)
        wifi = MultipeerTransport(displayName: displayName)
        localPeer = ble.localPeer
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
        let bleEvents = ble.events
        let wifiEvents = wifi.events
        // Handle both legs' events on the main actor. The BLE transport's L2CAP streams and Core
        // Bluetooth managers all run on the main run loop, so calling into them (send, advertise) from
        // these background stream tasks would race the model's own main-thread sends on the same
        // buffer. Marshaling here keeps every transport call single-threaded.
        Task.detached { [weak self] in for await event in bleEvents { await MainActor.run { self?.handleBLE(event) } } }
        Task.detached { [weak self] in for await event in wifiEvents { await MainActor.run { self?.handleWiFi(event) } } }
    }

    // MARK: PeerTransport

    public var connectedPeers: [Peer] {
        lock.withLock { primaryPeer.map { [$0] } ?? [] }
    }

    public func startAdvertising(discoveryInfo: [String: String]) {
        lock.withLock { role = .camera }
        ble.startAdvertising(discoveryInfo: discoveryInfo)
    }

    public func stopAdvertising() {
        // Only the primary (BLE) discoverability; the Wi-Fi leg manages its own advertising internally.
        ble.stopAdvertising()
    }

    public func startBrowsing() {
        lock.withLock { role = .remote }
        ble.startBrowsing()
    }

    public func stopBrowsing() {
        ble.stopBrowsing()
    }

    public func invite(_ peer: Peer, context: Data?, timeout: TimeInterval) {
        ble.invite(peer, context: context, timeout: timeout)
    }

    public func send(_ data: Data, to peers: [Peer]) throws {
        // The app's own bytes travel on the app lane over the reliable BLE channel.
        try ble.send(laned(.app, data), to: peers)
    }

    public func sendFile(at url: URL, named name: String, to peer: Peer) {
        let (up, wifiPeer) = lock.withLock { (wifiUp, self.wifiPeer) }
        if up, let wifiPeer {
            Trace.log("layered: sending \(name) over Wi-Fi")
            wifi.sendFile(at: url, named: name, to: wifiPeer)
        } else {
            Trace.log("layered: sending \(name) over Bluetooth (no Wi-Fi leg)")
            ble.sendFile(at: url, named: name, to: peer)
        }
    }

    public func disconnect() {
        ble.disconnect()
        teardownWiFi()
    }

    // MARK: BLE (primary) events

    private func handleBLE(_ event: TransportEvent) {
        switch event {
        case .connected(let peer):
            lock.withLock { primaryPeer = peer }
            continuation.yield(.connected(peer))
            continuation.yield(.fileChannelFast(false))   // starts on Bluetooth; the Wi-Fi leg may upgrade it
            startWiFiLeg()
        case .disconnected(let peer):
            teardownWiFi()
            lock.withLock { primaryPeer = nil }
            continuation.yield(.disconnected(peer))
        case .message(let data, let from):
            routeIncoming(data, from: from)
        default:
            // peerFound/peerLost/connecting, file events, fileSend*, failure — pass straight through.
            continuation.yield(event)
        }
    }

    private func routeIncoming(_ data: Data, from peer: Peer) {
        guard let lane = data.first.flatMap({ Lane(rawValue: $0) }) else { return }
        let body = Data(data.dropFirst())
        switch lane {
        case .app:
            continuation.yield(.message(body, from: peer))
        case .control:
            handleControl(body)
        }
    }

    private func handleControl(_ body: Data) {
        guard let control = try? JSONDecoder().decode(Control.self, from: body) else { return }
        lock.withLock { token = control.token }
        Trace.log("layered: received Wi-Fi token — browsing for the fast lane")
        wifi.startBrowsing()
    }

    /// Bootstrap the Wi-Fi leg once the BLE link is up. The camera mints the token, hands it to the
    /// remote over BLE, and advertises it; the remote waits for the token, then browses (in handleControl).
    private func startWiFiLeg() {
        let role = lock.withLock { self.role }
        guard role == .camera else { return }
        let token = UUID().uuidString
        lock.withLock { self.token = token }
        if let data = try? JSONEncoder().encode(Control(token: token)) {
            try? ble.send(laned(.control, data), to: connectedPeers)
        }
        var info = Pairing.advertisingInfo()
        info[Self.tokenKey] = token
        Trace.log("layered: BLE connected — advertising Wi-Fi fast lane")
        wifi.startAdvertising(discoveryInfo: info)
    }

    private func teardownWiFi() {
        lock.withLock {
            wifiPeer = nil
            wifiUp = false
            token = nil
        }
        wifi.stopAdvertising()
        wifi.stopBrowsing()
        wifi.disconnect()
    }

    // MARK: Wi-Fi (fast lane) events — internal, never surfaced as a second connection

    private func handleWiFi(_ event: TransportEvent) {
        switch event {
        case .peerFound(let peer):
            // Remote: invite only the peer carrying our token.
            let (role, token) = lock.withLock { (self.role, self.token) }
            guard role == .remote, let token, peer.discoveryInfo?[Self.tokenKey] == token else { return }
            Trace.log("layered: Wi-Fi fast lane found — inviting")
            wifi.invite(peer, context: Data(token.utf8), timeout: 15)
        case .invitation(_, let context, let respond):
            // Camera: accept only an invitation bearing our token (BLE already authenticated the pair).
            let token = lock.withLock { self.token }
            let ok = token != nil && context == Data((token ?? "").utf8)
            Trace.log("layered: Wi-Fi invitation \(ok ? "accepted" : "rejected")")
            respond(ok)
        case .connected(let peer):
            lock.withLock { wifiPeer = peer; wifiUp = true }
            wifi.stopAdvertising()
            wifi.stopBrowsing()
            Trace.log("layered: Wi-Fi fast lane UP — files will use Wi-Fi")
            continuation.yield(.fileChannelFast(true))
        case .disconnected(let peer):
            let dropped = lock.withLock { () -> Bool in
                guard wifiPeer?.id == peer.id else { return false }
                wifiPeer = nil
                wifiUp = false
                return true
            }
            if dropped {
                Trace.log("layered: Wi-Fi fast lane down — files fall back to Bluetooth")
                continuation.yield(.fileChannelFast(false))
            }
        case .fileReceiveStarted, .fileReceiveProgress, .fileReceived, .fileReceiveFailed,
             .fileSendProgress, .fileSendFinished:
            continuation.yield(event)   // a file arrived/left over the fast lane
        case .failure(let message):
            Trace.log("layered: Wi-Fi leg reported \(message)")   // optional leg; never surface
        case .connecting, .message, .peerLost, .fileChannelFast:
            break
        }
    }

    private func laned(_ lane: Lane, _ body: Data) -> Data {
        var out = Data([lane.rawValue])
        out.append(body)
        return out
    }
}
