import Foundation
import Testing
@testable import PairAndShootCore

@Suite @MainActor struct RemoteModelTests {
    let transport = FakeTransport(displayName: "Remote")
    let store = FakeMediaStore()
    let camera = aCamera()

    func makeModel() -> RemoteModel {
        let model = RemoteModel(transport: transport, mediaStore: store, appVersion: "2.0")
        model.start()
        return model
    }

    func connectedModel() async -> RemoteModel {
        let model = makeModel()
        transport.emit(.peerFound(camera))
        _ = await waitUntil { model.cameras.count == 1 }
        model.connect(to: camera, code: PairingCode("4821")!)
        transport.simulateConnected(camera)
        _ = await waitUntil { model.connection == .connected(camera) }
        return model
    }

    @Test func browsingListsOnlyCompatibleCameras() async {
        let model = makeModel()
        #expect(transport.isBrowsing)
        #expect(model.connection == .browsing)
        transport.emit(.peerFound(camera))
        transport.emit(.peerFound(Peer(id: "printer", displayName: "Printer", discoveryInfo: ["app": "other"])))
        transport.emit(.peerFound(Peer(id: "old", displayName: "Old app", discoveryInfo: nil)))
        #expect(await waitUntil { model.cameras.map(\.id) == ["cam"] })
        transport.emit(.peerLost(camera))
        #expect(await waitUntil { model.cameras.isEmpty })
    }

    @Test func connectSendsAVerifiableProof() async throws {
        let model = makeModel()
        model.connect(to: camera, code: PairingCode("4821")!)
        #expect(model.connection == .connecting(camera))
        let invitation = try #require(transport.invitations.first)
        #expect(invitation.peer.id == "cam")
        let verdict = Pairing.verify(context: invitation.context, code: PairingCode("4821")!, challenge: PairingChallenge(nonce: "0123456789abcdef"))
        #expect(verdict == .accepted(remoteName: "Remote"))
    }

    @Test func connectingSendsHelloAndMirrorsCameraState() async throws {
        let model = await connectedModel()
        guard case .hello(let hello)? = transport.sentCommands.first else {
            Issue.record("expected a hello, got \(transport.sentCommands)")
            return
        }
        #expect(hello.displayName == "Remote")
        #expect(hello.protocolVersion == WireProtocol.version)

        let state = CameraState(mode: .video, flash: .on, keepsCopies: false)
        transport.emit(.message(try encodedEvent(.state(state)), from: camera))
        transport.emit(.message(try encodedEvent(.hello(HelloInfo(appVersion: "2.0", displayName: "Cam", capabilities: CameraCapabilities(canRecordVideo: true)))), from: camera))
        #expect(await waitUntil { model.cameraState == state && model.camera?.capabilities?.canRecordVideo == true })
    }

    @Test func shutterSendsTheRightCommandForEachState() async throws {
        let model = await connectedModel()
        model.timerSeconds = 3
        model.sendBackPhotos = false

        transport.emit(.message(try encodedEvent(.state(CameraState(mode: .photo))), from: camera))
        #expect(await waitUntil { model.cameraState?.mode == .photo })
        model.shutter()
        #expect(transport.sentCommands.last == .capturePhoto(sendBack: false, delay: 3))

        transport.emit(.message(try encodedEvent(.state(CameraState(mode: .video))), from: camera))
        #expect(await waitUntil { model.cameraState?.mode == .video })
        model.sendBackVideos = true
        model.shutter()
        #expect(transport.sentCommands.last == .startRecording(sendBack: true, delay: 3))

        transport.emit(.message(try encodedEvent(.state(CameraState(mode: .video, isRecording: true))), from: camera))
        #expect(await waitUntil { model.cameraState?.isRecording == true })
        model.shutter()
        #expect(transport.sentCommands.last == .stopRecording)

        transport.emit(.message(try encodedEvent(.state(CameraState(mode: .photo, countdown: 2))), from: camera))
        #expect(await waitUntil { model.cameraState?.countdown == 2 })
        model.shutter()
        #expect(transport.sentCommands.last == .cancelCountdown)

        model.cycleFlash()
        #expect(transport.sentCommands.last == .setFlash(.auto))
        model.flipCamera()
        #expect(transport.sentCommands.last == .setPosition(.front))
        model.setMode(.video)
        #expect(transport.sentCommands.last == .setMode(.video))
    }

    @Test func receivedPhotoIsSavedAndCleanedUp() async throws {
        let model = await connectedModel()
        let bytes = Data("photo bytes".utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).jpg")
        try bytes.write(to: url)
        transport.emit(.fileReceiveStarted(name: "IMG_1.jpg", from: camera))
        transport.emit(.fileReceiveProgress(name: "IMG_1.jpg", fraction: 0.5))
        #expect(await waitUntil { model.transfer?.fraction == 0.5 && model.transfer?.phase == .receiving })
        transport.emit(.fileReceived(name: "IMG_1.jpg", url: url, from: camera))
        #expect(await waitUntil { model.transfer?.phase == .saved })
        #expect(store.photos == [bytes])
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func receivedVideoGoesToTheVideoPath() async throws {
        let model = await connectedModel()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).mov")
        try Data("movie".utf8).write(to: url)
        transport.emit(.fileReceived(name: "VID_1.mov", url: url, from: camera))
        #expect(await waitUntil { model.transfer?.phase == .saved })
        #expect(store.videos.count == 1)
        #expect(store.photos.isEmpty)
    }

    @Test func captureWithoutFileShowsWhereItWent() async throws {
        let model = await connectedModel()
        let result = CaptureResult(kind: .photo, byteCount: 10, willSendFile: false)
        transport.emit(.message(try encodedEvent(.captureFinished(result)), from: camera))
        #expect(await waitUntil { model.captures.count == 1 })
        #expect(model.notice == "Photo saved on the camera.")
    }

    @Test func declinedInvitationExplainsItself() async {
        let model = makeModel()
        model.connect(to: camera, code: PairingCode("0000")!)
        transport.emit(.disconnected(camera))
        #expect(await waitUntil { model.connection == .browsing })
        #expect(model.notice?.contains("didn't accept") == true)
    }

    @Test func versionMismatchDisconnects() async throws {
        let model = await connectedModel()
        var envelope = Envelope(message: .event(.pong))
        envelope.version = 42
        transport.emit(.message(try JSONEncoder().encode(envelope), from: camera))
        #expect(await waitUntil { model.notice?.contains("different version") == true })
        #expect(transport.connectedPeers.isEmpty)
    }
}
