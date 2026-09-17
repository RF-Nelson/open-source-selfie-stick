import Foundation
import Testing
@testable import ShotCallerCore

@Suite @MainActor struct LayeredTransportTests {
    @Test func fastLaneFilesUseTheAuthenticatedPrimaryIdentity() async throws {
        let primary = FakeTransport(displayName: "Remote")
        let wifi = FakeTransport(displayName: "Remote Wi-Fi")
        let transport = LayeredTransport(primary: primary, fastLane: wifi)
        let primaryPeer = Peer(id: "bluetooth-camera", displayName: "Camera")
        let wifiPeer = Peer(id: "wifi-camera", displayName: "Camera")
        var filePeers: [Peer] = []
        var fast = false
        let events = Task {
            for await event in transport.events {
                switch event {
                case .fileChannelFast(let value): fast = value
                case .fileReceiveStarted(_, let peer), .fileReceived(_, _, let peer): filePeers.append(peer)
                default: break
                }
            }
        }
        defer { events.cancel() }
        primary.simulateConnected(primaryPeer)
        #expect(await waitUntil { transport.connectedPeers == [primaryPeer] })
        wifi.simulateConnected(wifiPeer)
        #expect(await waitUntil { fast })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data("photo".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        wifi.emit(.fileReceiveStarted(name: "photo.jpg", from: wifiPeer))
        wifi.emit(.fileReceived(name: "photo.jpg", url: url, from: wifiPeer))
        #expect(await waitUntil { filePeers.count == 2 })
        #expect(filePeers == [primaryPeer, primaryPeer])
        transport.disconnect()
    }

    @Test func staleFastLaneFilesAreDiscarded() async throws {
        let primary = FakeTransport(displayName: "Remote")
        let wifi = FakeTransport(displayName: "Remote Wi-Fi")
        let transport = LayeredTransport(primary: primary, fastLane: wifi)
        let primaryPeer = Peer(id: "bluetooth-camera", displayName: "Camera")
        let wifiPeer = Peer(id: "wifi-camera", displayName: "Camera")
        primary.simulateConnected(primaryPeer)
        #expect(await waitUntil { transport.connectedPeers == [primaryPeer] })
        wifi.simulateConnected(wifiPeer)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data("stale photo".utf8).write(to: url)
        wifi.emit(.fileReceived(name: "photo.jpg", url: url, from: Peer(id: "old-wifi-peer", displayName: "Old camera")))
        #expect(await waitUntil { !FileManager.default.fileExists(atPath: url.path) })
        transport.disconnect()
    }
}
