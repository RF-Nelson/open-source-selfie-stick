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

    @Test func previewPacketsRideTheWiFiLegOnlyUnderThePrimaryIdentity() async throws {
        let primary = FakeTransport(displayName: "Remote")
        let wifi = FakeTransport(displayName: "Remote Wi-Fi")
        let transport = LayeredTransport(primary: primary, fastLane: wifi)
        let primaryPeer = Peer(id: "bluetooth-camera", displayName: "Camera")
        let wifiPeer = Peer(id: "wifi-camera", displayName: "Camera")
        var previews: [(Data, Peer)] = []
        var messages: [Data] = []
        var fast = false
        let events = Task {
            for await event in transport.events {
                switch event {
                case .fileChannelFast(let value): fast = value
                case .preview(let data, let peer): previews.append((data, peer))
                case .message(let data, _): messages.append(data)
                default: break
                }
            }
        }
        defer { events.cancel() }
        #expect(transport.supportsPreviewChannel)
        primary.simulateConnected(primaryPeer)
        #expect(await waitUntil { transport.connectedPeers == [primaryPeer] })
        // Bluetooth only: the preview channel is down and nothing is attempted on Bluetooth.
        #expect(throws: TransportError.notConnected) { try transport.sendPreview(Data([9]), to: primaryPeer) }
        #expect(primary.sentMessages.isEmpty)
        wifi.previewChannelAvailable = true
        wifi.simulateConnected(wifiPeer)
        #expect(await waitUntil { fast })
        try transport.sendPreview(Data([9, 8]), to: primaryPeer)
        #expect(wifi.sentMessages.last?.data == Data([2, 9, 8]))
        #expect(wifi.sentMessages.last?.peers.map(\.id) == [wifiPeer.id])
        #expect(primary.sentMessages.isEmpty)
        #expect(throws: TransportError.notConnected) { try transport.sendPreview(Data([9]), to: Peer(id: "someone-else", displayName: "X")) }
        // Incoming: lane 2 on the Wi-Fi leg surfaces as a preview from the primary peer; anything else is dropped.
        wifi.emit(.message(Data([2, 7]), from: wifiPeer))
        #expect(await waitUntil { previews.count == 1 })
        #expect(previews[0].0 == Data([7]) && previews[0].1 == primaryPeer)
        wifi.emit(.message(Data([0, 7]), from: wifiPeer))                                         // app lane over Wi-Fi
        wifi.emit(.message(Data([2, 7]), from: Peer(id: "old-wifi-peer", displayName: "Old")))     // foreign Wi-Fi peer
        primary.emit(.message(Data([2, 7]), from: primaryPeer))                                   // preview lane over Bluetooth
        primary.emit(.message(Data([0, 5]), from: primaryPeer))                                   // a real app message
        #expect(await waitUntil { messages == [Data([5])] })
        #expect(previews.count == 1)
        transport.disconnect()
    }
}
