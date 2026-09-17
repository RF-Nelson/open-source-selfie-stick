import Foundation
import Testing
@testable import ShotCallerCore

struct SinglePeerSessionTests {
    let peer = Peer(id: "camera", displayName: "Camera")

    @Test func onlyOneRemoteCanOwnTheCamera() {
        var state = SinglePeerSession()
        let first = UUID()
        #expect(state.begin(id: first, peer: peer) == true)
        #expect(state.begin(id: UUID(), peer: Peer(id: "other", displayName: "Other")) == false)
        #expect(state.current?.id == first)
        #expect(state.current?.isReady == false)
    }

    @Test func connectedIsEmittedOnlyOnceAndOnlyForCurrentAttempt() {
        var state = SinglePeerSession()
        let id = UUID()
        #expect(state.begin(id: id, peer: peer) == true)
        #expect(state.ready(id: UUID()) == nil)
        #expect(state.ready(id: id) == peer)
        #expect(state.ready(id: id) == nil)
    }

    @Test func lateDisconnectCannotTearDownAReconnectToTheSamePeer() {
        var state = SinglePeerSession()
        let old = UUID(), replacement = UUID()
        #expect(state.begin(id: old, peer: peer) == true)
        #expect(state.finish(id: old) == peer)
        #expect(state.begin(id: replacement, peer: peer) == true)
        #expect(state.finish(id: old) == nil)
        #expect(state.ready(id: old) == nil)
        #expect(state.current?.id == replacement)
        #expect(state.ready(id: replacement) == peer)
    }

    @Test func failedConnectReleasesSlotAndEmitsDisconnectOnlyOnce() {
        var state = SinglePeerSession()
        let id = UUID()
        #expect(state.begin(id: id, peer: peer) == true)
        #expect(state.finish(id: id) == peer)
        #expect(state.finish(id: id) == nil)
        #expect(state.begin(id: UUID(), peer: peer) == true)
    }
}
