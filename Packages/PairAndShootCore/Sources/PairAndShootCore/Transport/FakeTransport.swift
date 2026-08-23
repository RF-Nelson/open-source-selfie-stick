import Foundation

/// An in-memory transport for tests and SwiftUI previews.
///
/// Unlinked, it records what the model asked it to do and lets a test inject events with `emit`.
/// Linked with `linkedPair`, two instances deliver discovery, invitations, messages and files to each other.
public final class FakeTransport: PeerTransport, @unchecked Sendable {
    public struct SentMessage: Sendable, Equatable {
        public let data: Data
        public let peers: [Peer]
    }

    public struct SentFile: Sendable, Equatable {
        public let url: URL
        public let name: String
        public let peer: Peer
    }

    public struct Invitation: Sendable, Equatable {
        public let peer: Peer
        public let context: Data?
    }

    public let localPeer: Peer
    public let events: AsyncStream<TransportEvent>

    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let lock = NSLock()
    private var _sentMessages: [SentMessage] = []
    private var _sentFiles: [SentFile] = []
    private var _invitations: [Invitation] = []
    private var _advertisedInfo: [String: String]?
    private var _isAdvertising = false
    private var _isBrowsing = false
    private var _connected: [Peer] = []
    private weak var link: FakeTransport?

    public init(displayName: String, id: String = UUID().uuidString) {
        localPeer = Peer(id: id, displayName: displayName)
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
    }

    deinit {
        continuation.finish()
    }

    // MARK: Inspection

    public var sentMessages: [SentMessage] { lock.withLock { _sentMessages } }
    public var sentFiles: [SentFile] { lock.withLock { _sentFiles } }
    public var invitations: [Invitation] { lock.withLock { _invitations } }
    public var advertisedInfo: [String: String]? { lock.withLock { _advertisedInfo } }
    public var isAdvertising: Bool { lock.withLock { _isAdvertising } }
    public var isBrowsing: Bool { lock.withLock { _isBrowsing } }

    /// The peer other transports see when they discover this one.
    public var advertisedPeer: Peer {
        Peer(id: localPeer.id, displayName: localPeer.displayName, discoveryInfo: advertisedInfo)
    }

    // MARK: Test injection

    public func emit(_ event: TransportEvent) {
        continuation.yield(event)
    }

    public func simulateConnected(_ peer: Peer) {
        markConnected(peer)
    }

    public func simulateDisconnected(_ peer: Peer) {
        markDisconnected(peer)
    }

    // MARK: PeerTransport

    public var connectedPeers: [Peer] { lock.withLock { _connected } }

    public func startAdvertising(discoveryInfo: [String: String]) {
        lock.withLock {
            _isAdvertising = true
            _advertisedInfo = discoveryInfo
        }
        if let link, link.isBrowsing {
            link.continuation.yield(.peerFound(advertisedPeer))
        }
    }

    public func stopAdvertising() {
        let wasAdvertising = lock.withLock { () -> Bool in
            let was = _isAdvertising
            _isAdvertising = false
            return was
        }
        if wasAdvertising, let link, link.isBrowsing {
            link.continuation.yield(.peerLost(advertisedPeer))
        }
    }

    public func startBrowsing() {
        lock.withLock { _isBrowsing = true }
        if let link, link.isAdvertising {
            continuation.yield(.peerFound(link.advertisedPeer))
        }
    }

    public func stopBrowsing() {
        lock.withLock { _isBrowsing = false }
    }

    public func invite(_ peer: Peer, context: Data?, timeout: TimeInterval) {
        lock.withLock { _invitations.append(Invitation(peer: peer, context: context)) }
        guard let link, peer.id == link.localPeer.id else { return }
        let me = localPeer
        link.continuation.yield(.invitation(from: me, context: context, respond: { [weak self, weak link] accept in
            guard let self, let link else { return }
            if accept {
                link.markConnected(me)
                self.markConnected(link.localPeer)
            } else {
                self.continuation.yield(.disconnected(link.localPeer))
            }
        }))
    }

    public func send(_ data: Data, to peers: [Peer]) throws {
        lock.withLock { _sentMessages.append(SentMessage(data: data, peers: peers)) }
        guard let link else { return }
        guard connectedPeers.contains(where: { $0.id == link.localPeer.id }) else { throw TransportError.notConnected }
        if peers.contains(where: { $0.id == link.localPeer.id }) {
            link.continuation.yield(.message(data, from: localPeer))
        }
    }

    public func sendFile(at url: URL, named name: String, to peer: Peer) {
        lock.withLock { _sentFiles.append(SentFile(url: url, name: name, peer: peer)) }
        guard let link, peer.id == link.localPeer.id else {
            continuation.yield(.fileSendFinished(name: name, error: nil))
            return
        }
        link.continuation.yield(.fileReceiveStarted(name: name, from: localPeer))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            continuation.yield(.fileSendProgress(name: name, fraction: 1))
            link.continuation.yield(.fileReceiveProgress(name: name, fraction: 1))
            link.continuation.yield(.fileReceived(name: name, url: destination, from: localPeer))
            continuation.yield(.fileSendFinished(name: name, error: nil))
        } catch {
            continuation.yield(.fileSendFinished(name: name, error: error.localizedDescription))
            link.continuation.yield(.fileReceiveFailed(name: name, error: error.localizedDescription))
        }
    }

    public func disconnect() {
        let peers = lock.withLock { () -> [Peer] in
            let peers = _connected
            _connected = []
            return peers
        }
        for peer in peers {
            continuation.yield(.disconnected(peer))
            link?.markDisconnected(localPeer)
        }
    }

    // MARK: Linking

    /// Two transports that can see each other, as if on the same network.
    public static func linkedPair(cameraName: String = "Camera", remoteName: String = "Remote") -> (camera: FakeTransport, remote: FakeTransport) {
        let camera = FakeTransport(displayName: cameraName)
        let remote = FakeTransport(displayName: remoteName)
        camera.link = remote
        remote.link = camera
        return (camera, remote)
    }

    private func markConnected(_ peer: Peer) {
        lock.withLock {
            _connected.removeAll { $0.id == peer.id }
            _connected.append(peer)
        }
        continuation.yield(.connected(peer))
    }

    private func markDisconnected(_ peer: Peer) {
        lock.withLock { _connected.removeAll { $0.id == peer.id } }
        continuation.yield(.disconnected(peer))
    }
}
