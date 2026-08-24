import Foundation
import Testing
@testable import PairAndShootCore

/// A remote model driving a camera model over two linked fake transports: the whole protocol,
/// minus AVFoundation and Multipeer.
@Suite @MainActor struct EndToEndTests {
    @Test func remoteDrivesCameraEndToEnd() async throws {
        let (cameraTransport, remoteTransport) = FakeTransport.linkedPair(cameraName: "iPhone · A7", remoteName: "Rich's iPad")
        let device = FakeCameraDevice()
        let cameraStore = FakeMediaStore()
        let remoteStore = FakeMediaStore()
        let camera = CameraHostModel(transport: cameraTransport, device: device, mediaStore: cameraStore, appVersion: "2.0")
        let remote = RemoteModel(transport: remoteTransport, mediaStore: remoteStore, appVersion: "2.0")

        await camera.start()
        remote.start()
        #expect(await waitUntil { remote.cameras.count == 1 })
        #expect(remote.cameras[0].displayName == "iPhone · A7")

        // Wrong code first: the camera challenges over the channel, rejects the bad proof, and drops us.
        let wrongCode = PairingCode(camera.pairingCode.digits == "0000" ? "0001" : "0000")!
        remote.connect(to: remote.cameras[0], code: wrongCode)
        #expect(await waitUntil { remote.notice?.lowercased().contains("code") == true })
        #expect(await waitUntil { camera.link == .none && !remote.connection.isConnected })

        // The camera goes back on the air; wait to rediscover it, then pair with the right code.
        #expect(await waitUntil { !remote.cameras.isEmpty })
        remote.connect(to: remote.cameras.last!, code: camera.pairingCode)
        #expect(await waitUntil { remote.connection.isConnected && camera.link.isConnected })
        #expect(await waitUntil { remote.camera?.capabilities?.canRecordVideo == true && remote.cameraState != nil })
        #expect(await waitUntil {
            if case .connected(_, let info) = camera.link { return info?.displayName == "Rich's iPad" }
            return false
        })

        // A photo, sent back.
        remote.shutter()
        #expect(await waitUntil { remoteStore.photos.count == 1 && remote.transfer?.phase == .saved })
        #expect(cameraStore.photos.count == 1)
        #expect(remote.captures.count == 1)
        #expect(remote.captures[0].willSendFile)

        // A video, kept on the camera.
        remote.setMode(.video)
        #expect(await waitUntil { remote.cameraState?.mode == .video })
        remote.shutter()
        #expect(await waitUntil { remote.cameraState?.isRecording == true })
        remote.shutter()
        #expect(await waitUntil { remote.captures.count == 2 && remote.cameraState?.isRecording == false })
        #expect(cameraStore.videos.count == 1)
        #expect(remoteStore.videos.isEmpty)
        #expect(remote.notice == "Video saved on the camera.")

        // Hanging up puts the camera back on the air.
        remote.disconnect()
        #expect(await waitUntil { !remote.connection.isConnected && camera.link == .none && cameraTransport.isAdvertising })
        #expect(await waitUntil { remote.cameras.count == 1 })
    }
}

@Suite @MainActor struct VideoSendBackTests {
    @Test func videoSendBackReachesTheRemote() async throws {
        let (cameraTransport, remoteTransport) = FakeTransport.linkedPair(cameraName: "iPhone · A7", remoteName: "iPad")
        let device = FakeCameraDevice()
        let cameraStore = FakeMediaStore()
        let remoteStore = FakeMediaStore()
        let camera = CameraHostModel(transport: cameraTransport, device: device, mediaStore: cameraStore, appVersion: "2.0")
        let remote = RemoteModel(transport: remoteTransport, mediaStore: remoteStore, appVersion: "2.0")

        await camera.start()
        remote.start()
        #expect(await waitUntil { remote.cameras.count == 1 })
        remote.connect(to: remote.cameras.last!, code: camera.pairingCode)
        #expect(await waitUntil { remote.connection.isConnected && camera.link.isConnected && remote.cameraState != nil })

        remote.sendBackVideos = true
        remote.setMode(.video)
        #expect(await waitUntil { remote.cameraState?.mode == .video })
        remote.shutter()
        #expect(await waitUntil { remote.cameraState?.isRecording == true })
        remote.shutter()

        #expect(await waitUntil { remoteStore.videos.count == 1 })
        #expect(cameraStore.videos.count == 1)
        #expect(remote.captures.last?.willSendFile == true)
        #expect(remote.transfer?.phase == .saved)
    }
}

@Suite @MainActor struct SystemPairedEndToEndTests {
    @Test func connectsWithoutACodeAndShoots() async throws {
        // appLevelPairing:false on both — models must skip the 4-digit handshake.
        let (cameraTransport, remoteTransport) = FakeTransport.linkedPair(cameraName: "iPhone A7", remoteName: "iPad", appLevelPairing: false)
        let device = FakeCameraDevice()
        let cameraStore = FakeMediaStore()
        let remoteStore = FakeMediaStore()
        let camera = CameraHostModel(transport: cameraTransport, device: device, mediaStore: cameraStore, appVersion: "2.0")
        let remote = RemoteModel(transport: remoteTransport, mediaStore: remoteStore, appVersion: "2.0")

        await camera.start()
        remote.start()
        #expect(remote.requiresCode == false)
        #expect(await waitUntil { remote.cameras.count == 1 })

        remote.connect(to: remote.cameras.last!)   // no code
        #expect(await waitUntil { remote.connection.isConnected && camera.link.isConnected && remote.cameraState != nil })

        remote.sendBackPhotos = true
        remote.shutter()
        #expect(await waitUntil { remoteStore.photos.count == 1 && camera.captures.count == 1 })
    }
}
