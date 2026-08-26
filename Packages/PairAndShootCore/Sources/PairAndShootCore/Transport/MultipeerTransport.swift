import Foundation
import MultipeerConnectivity
import os

/// The production transport: MultipeerConnectivity over Bluetooth, infrastructure Wi-Fi, or peer-to-peer Wi-Fi.
///
/// Multipeer calls its delegates on private queues. This class converts every callback into a
/// `TransportEvent` on a single `AsyncStream` and maps `MCPeerID` (not Sendable) to `Peer` values
/// at the boundary, so nothing above it touches the framework or its threading rules.
public final class MultipeerTransport: NSObject, PeerTransport, @unchecked Sendable {
    public let localPeer: Peer
    public let events: AsyncStream<TransportEvent>

    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let lock = NSLock()
    private let serviceType: String
    private let myPeerID: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var idsByPeerID: [MCPeerID: String] = [:]
    private var peerIDsByID: [String: MCPeerID] = [:]
    private var discoveryInfoByID: [String: [String: String]] = [:]
    private var progressObservations: [String: NSKeyValueObservation] = [:]
    private let inboxDirectory: URL
    private let log = Logger(subsystem: "com.richardnelson.opensourceselfiestick", category: "mc")

    public init(displayName: String, serviceType: String = WireProtocol.serviceType) {
        self.serviceType = serviceType
        let peerID = MCPeerID(displayName: Self.trimmedDisplayName(displayName))
        myPeerID = peerID
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
        inboxDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PairAndShootInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
        localPeer = Peer(id: "local", displayName: peerID.displayName)
        super.init()
        session.delegate = self
    }

    deinit {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session.disconnect()
        continuation.finish()
    }

    /// MCPeerID rejects names longer than 63 UTF-8 bytes; keep whole characters and a safety margin.
    static func trimmedDisplayName(_ name: String) -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "Device" }
        var result = ""
        var bytes = 0
        for character in cleaned {
            let size = character.utf8.count
            if bytes + size > 60 { break }
            result.append(character)
            bytes += size
        }
        return result
    }

    // MARK: PeerTransport

    public var connectedPeers: [Peer] {
        session.connectedPeers.map(peer(for:))
    }

    public func startAdvertising(discoveryInfo: [String: String]) {
        let advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: discoveryInfo, serviceType: serviceType)
        advertiser.delegate = self
        let previous = lock.withLock { () -> MCNearbyServiceAdvertiser? in
            let previous = self.advertiser
            self.advertiser = advertiser
            return previous
        }
        previous?.stopAdvertisingPeer()
        advertiser.startAdvertisingPeer()
        log.notice("advertising as \(self.myPeerID.displayName, privacy: .public)")
        Trace.log("mc: advertising as \(self.myPeerID.displayName)")
    }

    public func stopAdvertising() {
        let previous = lock.withLock { () -> MCNearbyServiceAdvertiser? in
            let previous = self.advertiser
            self.advertiser = nil
            return previous
        }
        previous?.stopAdvertisingPeer()
    }

    public func startBrowsing() {
        let browser = lock.withLock { () -> MCNearbyServiceBrowser in
            if let browser = self.browser { return browser }
            let browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
            browser.delegate = self
            self.browser = browser
            return browser
        }
        browser.startBrowsingForPeers()
        log.notice("browsing for peers")
        Trace.log("mc: browsing for peers")
    }

    public func stopBrowsing() {
        let browser = lock.withLock { self.browser }
        browser?.stopBrowsingForPeers()
    }

    public func invite(_ peer: Peer, context: Data?, timeout: TimeInterval) {
        let (browser, peerID) = lock.withLock { (self.browser, peerIDsByID[peer.id]) }
        guard let browser, let peerID else {
            Trace.log("mc: invite failed — peer \(peer.displayName) no longer in range")
            continuation.yield(.failure("That camera is no longer in range."))
            return
        }
        Trace.log("mc: inviting \(peerID.displayName) (timeout \(Int(timeout))s)")
        browser.invitePeer(peerID, to: session, withContext: context, timeout: timeout)
    }

    public func send(_ data: Data, to peers: [Peer]) throws {
        let peerIDs = lock.withLock { peers.compactMap { peerIDsByID[$0.id] } }
        let connected = Set(session.connectedPeers)
        let targets = peerIDs.filter { connected.contains($0) }
        guard !targets.isEmpty else { throw TransportError.notConnected }
        do {
            try session.send(data, toPeers: targets, with: .reliable)
        } catch {
            throw TransportError.sendFailed(error.localizedDescription)
        }
    }

    public func sendFile(at url: URL, named name: String, to peer: Peer) {
        guard let peerID = lock.withLock({ peerIDsByID[peer.id] }), session.connectedPeers.contains(peerID) else {
            continuation.yield(.fileSendFinished(name: name, error: "Not connected"))
            return
        }
        let continuation = self.continuation
        let key = "send:" + name
        let progress = session.sendResource(at: url, withName: name, toPeer: peerID) { [weak self] error in
            self?.endObservation(key: key)
            continuation.yield(.fileSendFinished(name: name, error: error?.localizedDescription))
        }
        observe(progress, key: key) { fraction in
            continuation.yield(.fileSendProgress(name: name, fraction: fraction))
        }
    }

    public func disconnect() {
        session.disconnect()
    }

    // MARK: Peer bookkeeping

    private func peer(for peerID: MCPeerID) -> Peer {
        lock.withLock {
            let id: String
            if let existing = idsByPeerID[peerID] {
                id = existing
            } else {
                id = UUID().uuidString
                idsByPeerID[peerID] = id
                peerIDsByID[id] = peerID
            }
            return Peer(id: id, displayName: peerID.displayName, discoveryInfo: discoveryInfoByID[id])
        }
    }

    private func observe(_ progress: Progress?, key: String, _ onFraction: @escaping @Sendable (Double) -> Void) {
        guard let progress else { return }
        let observation = progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            onFraction(progress.fractionCompleted)
        }
        lock.withLock { progressObservations[key] = observation }
    }

    private func endObservation(key: String) {
        lock.withLock { progressObservations[key] = nil }
    }
}

/// Wraps Multipeer's invitation handler so it can cross into a `@Sendable` closure and be called at most once.
private final class InvitationResponder: @unchecked Sendable {
    private let lock = NSLock()
    private let session: MCSession
    private var handler: ((Bool, MCSession?) -> Void)?

    init(session: MCSession, handler: @escaping (Bool, MCSession?) -> Void) {
        self.session = session
        self.handler = handler
    }

    func respond(_ accept: Bool) {
        let handler = lock.withLock { () -> ((Bool, MCSession?) -> Void)? in
            let handler = self.handler
            self.handler = nil
            return handler
        }
        handler?(accept, accept ? session : nil)
    }
}

extension MultipeerTransport: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: any Error) {
        log.error("didNotStartAdvertising: \(error.localizedDescription, privacy: .public)")
        Trace.log("mc: didNotStartAdvertising: \(error.localizedDescription)")
        continuation.yield(.failure("This device can't be discovered right now: \(error.localizedDescription)"))
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                           withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        log.notice("invitation from \(peerID.displayName, privacy: .public) contextBytes=\(context?.count ?? -1)")
        Trace.log("mc: invitation from \(peerID.displayName) contextBytes=\(context?.count ?? -1)")
        let responder = InvitationResponder(session: session, handler: invitationHandler)
        continuation.yield(.invitation(from: peer(for: peerID), context: context, respond: { accept in
            responder.respond(accept)
        }))
    }
}

extension MultipeerTransport: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        var peer = peer(for: peerID)
        lock.withLock { discoveryInfoByID[peer.id] = info }
        peer.discoveryInfo = info
        log.notice("found peer \(peerID.displayName, privacy: .public) info=\(String(describing: info), privacy: .public)")
        Trace.log("mc: found peer \(peerID.displayName)")
        continuation.yield(.peerFound(peer))
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Trace.log("mc: lost peer \(peerID.displayName)")
        continuation.yield(.peerLost(peer(for: peerID)))
    }

    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: any Error) {
        log.error("didNotStartBrowsing: \(error.localizedDescription, privacy: .public)")
        Trace.log("mc: didNotStartBrowsing: \(error.localizedDescription)")
        continuation.yield(.failure("Can't search for cameras: \(error.localizedDescription)"))
    }
}

extension MultipeerTransport: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let peer = peer(for: peerID)
        let name: String
        switch state {
        case .connecting: name = "connecting"
        case .connected: name = "connected"
        case .notConnected: name = "notConnected"
        @unknown default: name = "unknown"
        }
        log.notice("session \(peerID.displayName, privacy: .public) -> \(name, privacy: .public)")
        Trace.log("mc: session \(peerID.displayName) -> \(name)")
        switch state {
        case .connecting: continuation.yield(.connecting(peer))
        case .connected: continuation.yield(.connected(peer))
        case .notConnected: continuation.yield(.disconnected(peer))
        @unknown default: break
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        continuation.yield(.message(data, from: peer(for: peerID)))
    }

    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // Streams are not part of the protocol (yet: a live preview would use one).
    }

    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        continuation.yield(.fileReceiveStarted(name: resourceName, from: peer(for: peerID)))
        let continuation = self.continuation
        observe(progress, key: "recv:" + resourceName) { fraction in
            continuation.yield(.fileReceiveProgress(name: resourceName, fraction: fraction))
        }
    }

    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                        at localURL: URL?, withError error: (any Error)?) {
        endObservation(key: "recv:" + resourceName)
        if let error {
            continuation.yield(.fileReceiveFailed(name: resourceName, error: error.localizedDescription))
            return
        }
        guard let localURL else {
            continuation.yield(.fileReceiveFailed(name: resourceName, error: "The file did not arrive."))
            return
        }
        // Multipeer deletes `localURL` as soon as this method returns, so take ownership now.
        let safeName = resourceName.replacingOccurrences(of: "/", with: "_")
        let destination = inboxDirectory.appendingPathComponent(UUID().uuidString + "-" + safeName)
        do {
            try FileManager.default.moveItem(at: localURL, to: destination)
            continuation.yield(.fileReceived(name: resourceName, url: destination, from: peer(for: peerID)))
        } catch {
            continuation.yield(.fileReceiveFailed(name: resourceName, error: error.localizedDescription))
        }
    }
}
