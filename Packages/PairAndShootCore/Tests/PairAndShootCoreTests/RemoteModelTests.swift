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
        // Camera challenges; remote answers with a pair command; camera accepts by sending hello.
        transport.emit(.message(try! encodedEvent(.challenge("0123456789abcdef")), from: camera))
        _ = await waitUntil { transport.sentPairSubmission != nil }
        transport.emit(.message(try! encodedEvent(.hello(HelloInfo(appVersion: "2.0", displayName: "Cam", capabilities: CameraCapabilities(canRecordVideo: true)))), from: camera))
        _ = await waitUntil { model.connection == .connected(camera) }
        return model
    }

    @Test func browsingListsOnlyCompatibleCameras() async {
        let model = makeModel()
        #expect(transport.isBrowsing)
        #expect(model.connection == .browsing)
        transport.emit(.peerFound(camera))
        transport.emit(.peerFound(Peer(id: "printer", displayName: "Printer", discoveryInfo: ["app": "other"])))
        transport.emit(.peerFound(Peer(id: "nodisc", displayName: "No info", discoveryInfo: nil)))
        // "printer" advertises a different app and is filtered; a peer with no discovery info is a
        // candidate (Bluetooth often omits it).
        #expect(await waitUntil { model.cameras.map(\.id).sorted() == ["cam", "nodisc"] })
        transport.emit(.peerLost(camera))
        #expect(await waitUntil { model.cameras.map(\.id) == ["nodisc"] })
    }

    @Test func connectInvitesThenProvesOverTheChannel() async throws {
        let model = makeModel()
        model.connect(to: camera, code: PairingCode("4821")!)
        #expect(model.connection == .connecting(camera))
        let invitation = try #require(transport.invitations.first)
        #expect(invitation.peer.id == "cam")
        #expect(invitation.context == nil)   // no secret in the invitation any more

        transport.simulateConnected(camera)
        transport.emit(.message(try encodedEvent(.challenge("0123456789abcdef")), from: camera))
        let submission = try #require(await waitUntilValue { transport.sentPairSubmission })
        let verdict = Pairing.verify(context: submission.proof, code: PairingCode("4821")!, challenge: PairingChallenge(nonce: "0123456789abcdef"))
        #expect(verdict == .accepted(remoteName: "Remote"))
        #expect(model.connection == .connecting(camera))   // not connected until the camera says hello
    }

    @Test func pairingProvesTheCodeAndMirrorsState() async throws {
        let model = await connectedModel()
        let submission = try #require(transport.sentPairSubmission)
        #expect(submission.displayName == "Remote")
        #expect(submission.protocolVersion == WireProtocol.version)
        #expect(model.camera?.capabilities?.canRecordVideo == true)

        let state = CameraState(mode: .video, flash: .on, keepsCopies: false)
        transport.emit(.message(try encodedEvent(.state(state)), from: camera))
        #expect(await waitUntil { model.cameraState == state })
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

    @Test func rejectedCodeShowsTheCameraReason() async {
        let model = makeModel()
        transport.emit(.peerFound(camera))
        _ = await waitUntil { model.cameras.count == 1 }
        model.connect(to: camera, code: PairingCode("0000")!)
        transport.simulateConnected(camera)
        transport.emit(.message(try! encodedEvent(.rejected(reason: "The code didn't match. Check the code on the camera and try again.")), from: camera))
        transport.emit(.disconnected(camera))
        #expect(await waitUntil { model.connection == .browsing })
        #expect(model.notice?.contains("didn't match") == true)
    }

    @Test func challengedThenDroppedBlamesTheCode() async {
        let model = makeModel()
        transport.emit(.peerFound(camera))
        _ = await waitUntil { model.cameras.count == 1 }
        model.connect(to: camera, code: PairingCode("0000")!)
        transport.simulateConnected(camera)
        transport.emit(.message(try! encodedEvent(.challenge("0123456789abcdef")), from: camera))
        _ = await waitUntil { transport.sentPairSubmission != nil }
        transport.emit(.disconnected(camera))   // rejected event lost; we were challenged, so blame the code
        #expect(await waitUntil { model.connection == .browsing })
        #expect(model.notice?.contains("didn't accept the code") == true)
    }

    @Test func connectionThatNeverEstablishesSuggestsBluetooth() async {
        let model = makeModel()
        transport.emit(.peerFound(camera))
        _ = await waitUntil { model.cameras.count == 1 }
        model.connect(to: camera, code: PairingCode("0000")!)
        // The session never connects and no challenge ever arrives — the Bluetooth link couldn't form.
        transport.emit(.disconnected(camera))
        #expect(await waitUntil { model.connection == .browsing })
        #expect(model.notice?.lowercased().contains("bluetooth") == true)
    }

    @Test func pairedDropAutoReconnects() async {
        let model = await connectedModel()
        #expect(transport.invitations.count == 1)
        // An unexpected drop of a paired session (typical of peer-to-peer Wi-Fi).
        transport.emit(.disconnected(camera))
        #expect(await waitUntil { model.isReconnecting })
        #expect(await waitUntil { transport.invitations.count == 2 })   // re-invited automatically
        #expect(model.notice != "The camera disconnected.")             // not surfaced yet
        // Complete the handshake again.
        transport.simulateConnected(camera)
        transport.emit(.message(try! encodedEvent(.challenge("0123456789abcdef")), from: camera))
        _ = await waitUntil { transport.sentPairSubmission != nil }
        transport.emit(.message(try! encodedEvent(.hello(HelloInfo(appVersion: "2.0", displayName: "Cam"))), from: camera))
        #expect(await waitUntil { model.connection == .connected(camera) && !model.isReconnecting })
    }

    @Test func autoReconnectGivesUpAfterItsBudget() async {
        let model = await connectedModel()
        transport.emit(.disconnected(camera))   // drop 1 -> reconnect attempt 1
        #expect(await waitUntil { model.isReconnecting && transport.invitations.count == 2 })
        transport.emit(.disconnected(camera))   // attempt 1 fails -> attempt 2
        #expect(await waitUntil { transport.invitations.count == 3 })
        transport.emit(.disconnected(camera))   // attempt 2 fails -> attempt 3
        #expect(await waitUntil { transport.invitations.count == 4 })
        transport.emit(.disconnected(camera))   // attempt 3 fails -> budget exhausted
        #expect(await waitUntil { !model.isReconnecting && model.notice == "The camera disconnected." })
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
