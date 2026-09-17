import Foundation

/// A generation, rather than a peer ID, identifies a connection attempt: a reconnect can use the
/// same peer while callbacks from the previous network task are still being delivered.
struct SinglePeerSession: Sendable {
    struct Session: Equatable, Sendable {
        let id: UUID
        let peer: Peer
        var isReady = false
    }

    private(set) var current: Session?

    mutating func begin(id: UUID, peer: Peer) -> Bool {
        guard current == nil else { return false }
        current = Session(id: id, peer: peer)
        return true
    }

    mutating func ready(id: UUID) -> Peer? {
        guard current?.id == id, current?.isReady == false else { return nil }
        current?.isReady = true
        return current?.peer
    }

    mutating func finish(id: UUID) -> Peer? {
        guard current?.id == id else { return nil }
        defer { current = nil }
        return current?.peer
    }
}
