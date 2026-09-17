import Foundation
import Testing
@testable import ShotCallerCore

/// A send stays busy until the test emits its completion, including asynchronous cancellation.
private final class DelayedFileTransport: PeerTransport, @unchecked Sendable {
    let base = FakeTransport(displayName: "Camera", appLevelPairing: false)
    var localPeer: Peer { base.localPeer }
    var events: AsyncStream<TransportEvent> { base.events }
    var connectedPeers: [Peer] { base.connectedPeers }
    var requiresAppLevelPairing: Bool { false }
    private let lock = NSLock()
    private var names: [String] = []
    private var cancels = 0
    var sentNames: [String] { lock.withLock { names } }
    var cancelCount: Int { lock.withLock { cancels } }
    func startAdvertising(discoveryInfo: [String: String]) { base.startAdvertising(discoveryInfo: discoveryInfo) }
    func stopAdvertising() { base.stopAdvertising() }
    func startBrowsing() { base.startBrowsing() }
    func stopBrowsing() { base.stopBrowsing() }
    func invite(_ peer: Peer, context: Data?, timeout: TimeInterval) { base.invite(peer, context: context, timeout: timeout) }
    func send(_ data: Data, to peers: [Peer]) throws { try base.send(data, to: peers) }
    func sendFile(at url: URL, named name: String, to peer: Peer) { lock.withLock { names.append(name) } }
    func cancelFileSend() { lock.withLock { cancels += 1 } }
    func disconnect() { base.disconnect() }
}

@Suite @MainActor struct CaptureTransferQueueTests {
    @Test func deferredFilesAreSequentialAndCancellationWaitsForTransportCompletion() async throws {
        let transport = DelayedFileTransport()
        let model = CameraHostModel(transport: transport, device: FakeCameraDevice(), mediaStore: FakeMediaStore(), appVersion: "2.0")
        await model.start()
        let remote = Peer(id: "remote", displayName: "Remote")
        transport.base.simulateConnected(remote)
        transport.base.emit(.fileChannelFast(false))
        #expect(await waitUntil { model.link.isConnected && model.fileChannelFast == false })
        model.perform(.capturePhoto(sendBack: true, delay: 0))
        #expect(await waitUntil { model.captures.count == 1 })
        model.perform(.capturePhoto(sendBack: true, delay: 0))
        #expect(await waitUntil { model.captures.count == 2 })
        transport.base.emit(.fileChannelFast(true))
        #expect(await waitUntil { transport.sentNames.count == 1 })
        let first = model.captures[0]
        let second = model.captures[1]
        model.perform(.cancelTransfer(id: first.id))
        #expect(await waitUntil { transport.cancelCount == 1 })
        model.perform(.requestFile(id: first.id, quality: .full))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(transport.sentNames.count == 1)
        transport.base.emit(.fileSendFinished(name: transport.sentNames[0], error: "Canceled"))
        #expect(await waitUntil { transport.sentNames.count == 2 })
        #expect(TransferName.parse(transport.sentNames[1])?.id == second.id)
        transport.base.emit(.fileSendFinished(name: transport.sentNames[1], error: nil))
        #expect(await waitUntil { transport.sentNames.count == 3 })
        #expect(TransferName.parse(transport.sentNames[2])?.id == first.id)
        await model.stop()
    }

    @Test func aCancelTheRemoteAskedForIsNotShownAsAFailedTransfer() async throws {
        let transport = DelayedFileTransport()
        let model = CameraHostModel(transport: transport, device: FakeCameraDevice(), mediaStore: FakeMediaStore(), appVersion: "2.0")
        await model.start()
        transport.base.simulateConnected(Peer(id: "remote", displayName: "Remote"))
        transport.base.emit(.fileChannelFast(false))
        #expect(await waitUntil { model.link.isConnected && model.fileChannelFast == false })
        model.perform(.capturePhoto(sendBack: true, delay: 0))
        #expect(await waitUntil { model.captures.count == 1 })
        let capture = model.captures[0]
        model.perform(.requestFile(id: capture.id, quality: .full))
        #expect(await waitUntil { transport.sentNames.count == 1 })
        model.perform(.cancelTransfer(id: capture.id))
        #expect(await waitUntil { transport.cancelCount == 1 })
        transport.base.emit(.fileSendFinished(name: transport.sentNames[0], error: "Canceled"))
        #expect(await waitUntil { model.pendingTransferCount == 1 })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(model.outgoingTransfer == nil)
        // The file is still held, so the remote can ask again.
        model.perform(.requestFile(id: capture.id, quality: .full))
        #expect(await waitUntil { transport.sentNames.count == 2 })
        await model.stop()
    }
}
