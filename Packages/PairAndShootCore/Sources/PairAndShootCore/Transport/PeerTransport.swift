import Foundation

/// Another device, as seen through a transport. `id` is stable for the life of the transport.
public struct Peer: Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public var discoveryInfo: [String: String]?

    public init(id: String, displayName: String, discoveryInfo: [String: String]? = nil) {
        self.id = id
        self.displayName = displayName
        self.discoveryInfo = discoveryInfo
    }
}

public enum TransportEvent: Sendable {
    case peerFound(Peer)
    case peerLost(Peer)
    /// Another peer wants to join. Exactly one call to `respond` decides it.
    case invitation(from: Peer, context: Data?, respond: @Sendable (Bool) -> Void)
    case connecting(Peer)
    case connected(Peer)
    case disconnected(Peer)
    case message(Data, from: Peer)
    case fileReceiveStarted(name: String, from: Peer)
    case fileReceiveProgress(name: String, fraction: Double)
    /// The file at `url` belongs to the receiver now; delete it when done.
    case fileReceived(name: String, url: URL, from: Peer)
    case fileReceiveFailed(name: String, error: String)
    case fileSendProgress(name: String, fraction: Double)
    case fileSendFinished(name: String, error: String?)
    case failure(String)
}

public enum TransportError: Error, Sendable, Equatable {
    case notConnected
    case sendFailed(String)
}

public extension PeerTransport {
    var requiresAppLevelPairing: Bool { true }
}

/// Everything the app needs from a peer-to-peer link. `MultipeerTransport` is the real one;
/// `FakeTransport` stands in for tests and previews. Nothing above this layer imports MultipeerConnectivity.
public protocol PeerTransport: AnyObject, Sendable {
    var localPeer: Peer { get }
    /// Whether the app must run its own code-pairing handshake over this transport. Multipeer has no
    /// system pairing, so it does (true, the default). Wi-Fi Aware pairs devices at the OS level, so
    /// the app-level challenge/pair is skipped (false).
    var requiresAppLevelPairing: Bool { get }
    /// Single-consumer stream: exactly one owner iterates it.
    var events: AsyncStream<TransportEvent> { get }
    var connectedPeers: [Peer] { get }

    func startAdvertising(discoveryInfo: [String: String])
    func stopAdvertising()
    func startBrowsing()
    func stopBrowsing()
    func invite(_ peer: Peer, context: Data?, timeout: TimeInterval)
    func send(_ data: Data, to peers: [Peer]) throws
    func sendFile(at url: URL, named name: String, to peer: Peer)
    func disconnect()
}
