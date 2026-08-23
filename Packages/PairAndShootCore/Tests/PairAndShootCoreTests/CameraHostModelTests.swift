import Foundation
import Testing
@testable import PairAndShootCore

@Suite @MainActor struct CameraHostModelTests {
    let transport = FakeTransport(displayName: "iPhone · A7")
    let device = FakeCameraDevice()
    let store = FakeMediaStore()
    let sleeper = FakeSleeper()
    let remote = Peer(id: "remote", displayName: "Remote")

    func makeModel() async -> CameraHostModel {
        let model = CameraHostModel(transport: transport, device: device, mediaStore: store, appVersion: "2.0", sleep: sleeper.sleep)
        await model.start()
        return model
    }

    func validProof(for model: CameraHostModel) -> Data {
        let challenge = Pairing.challenge(from: transport.advertisedInfo)!
        return Pairing.proof(code: model.pairingCode, challenge: challenge, remoteName: "Remote")
    }

    func connectedModel() async -> CameraHostModel {
        let model = await makeModel()
        let answers = Answers()
        transport.emit(.invitation(from: remote, context: validProof(for: model), respond: answers.record))
        _ = await waitUntil { answers.values == [true] }
        transport.simulateConnected(remote)
        _ = await waitUntil { model.link.isConnected }
        return model
    }

    func command(_ command: RemoteCommand) throws {
        transport.emit(.message(try encodedCommand(command), from: remote))
    }

    @Test func startsAdvertisingAChallenge() async throws {
        let model = await makeModel()
        #expect(model.availability == .ready)
        #expect(transport.isAdvertising)
        #expect(Pairing.challenge(from: transport.advertisedInfo) != nil)
        #expect(device.appliedSettings == CameraSettings())
        #expect(model.capabilities.canRecordVideo)
    }

    @Test func unusableCameraIsReportedNotAdvertised() async {
        device.failStart(with: .permissionDenied("camera"))
        let model = await makeModel()
        #expect(model.availability == .unavailable(CameraDeviceError.permissionDenied("camera").errorDescription!))
        #expect(!transport.isAdvertising)
    }

    @Test func wrongCodesAreRefusedAndTheCodeRotatesAfterThree() async {
        let model = await makeModel()
        let firstChallenge = transport.advertisedInfo
        let answers = Answers()
        for _ in 0..<2 {
            transport.emit(.invitation(from: remote, context: Data("junk".utf8), respond: answers.record))
        }
        #expect(await waitUntil { answers.values == [false, false] })
        #expect(transport.advertisedInfo == firstChallenge)
        #expect(model.link == .none)

        transport.emit(.invitation(from: remote, context: Data("junk".utf8), respond: answers.record))
        #expect(await waitUntil { answers.values == [false, false, false] })
        #expect(await waitUntil { transport.advertisedInfo != firstChallenge })
        #expect(model.notice?.contains("new code") == true)
    }

    @Test func rightCodeIsAcceptedThenHelloAndStateAreSent() async throws {
        let model = await connectedModel()
        #expect(!transport.isAdvertising)
        guard case .hello(let hello)? = transport.sentEvents.first else {
            Issue.record("expected hello first, got \(transport.sentEvents)")
            return
        }
        #expect(hello.capabilities == model.capabilities)
        #expect(transport.sentStates.last == model.state)

        try command(.hello(HelloInfo(appVersion: "2.0", displayName: "Remote")))
        #expect(await waitUntil {
            if case .connected(_, let info) = model.link { return info?.displayName == "Remote" }
            return false
        })
    }

    @Test func secondRemoteIsRefusedWhileOneIsConnected() async {
        let model = await connectedModel()
        let answers = Answers()
        let intruder = Peer(id: "intruder", displayName: "Someone")
        transport.emit(.invitation(from: intruder, context: validProof(for: model), respond: answers.record))
        #expect(await waitUntil { answers.values == [false] })
        #expect(model.link.peer?.id == "remote")
    }

    @Test func remotePhotoCommandCapturesSavesAndSendsTheFile() async throws {
        let model = await connectedModel()
        try command(.capturePhoto(sendBack: true, delay: 0))
        #expect(await waitUntil { model.captures.count == 1 })
        #expect(device.photoCount == 1)
        #expect(store.photos == [Data("fake-photo-1".utf8)])
        let sent = try #require(transport.sentFiles.first)
        #expect(sent.name.hasPrefix("IMG_") && sent.name.hasSuffix(".jpg"))
        #expect(sent.peer.id == "remote")
        let result = try #require(transport.lastCaptureResult)
        #expect(result.willSendFile)
        #expect(result.fileName == sent.name)
        #expect(await waitUntil { model.outgoingTransfer?.phase == .sent })
        #expect(!FileManager.default.fileExists(atPath: sent.url.path))
        #expect(transport.sentStates.contains { $0.isBusy })
        #expect(model.state.isBusy == false)
    }

    @Test func keepsCopiesOffSkipsTheLocalSave() async throws {
        let model = await connectedModel()
        model.keepsCopies = false
        #expect(transport.sentStates.last?.keepsCopies == false)
        try command(.capturePhoto(sendBack: false, delay: 0))
        #expect(await waitUntil { model.captures.count == 1 })
        #expect(store.photos.isEmpty)
        #expect(transport.sentFiles.isEmpty)
    }

    @Test func countdownIsBroadcastAndCanBeCancelled() async throws {
        let model = await connectedModel()
        sleeper.passthrough = false
        try command(.capturePhoto(sendBack: false, delay: 2))
        #expect(await waitUntil { model.state.countdown == 2 && sleeper.pendingCount == 1 })
        #expect(transport.sentStates.last?.countdown == 2)
        sleeper.releaseAll()
        #expect(await waitUntil { model.state.countdown == 1 && sleeper.pendingCount == 1 })

        try command(.cancelCountdown)
        #expect(await waitUntil { model.state.countdown == nil })
        #expect(device.photoCount == 0)
        #expect(transport.sentStates.last?.countdown == nil)

        try command(.capturePhoto(sendBack: false, delay: 1))
        #expect(await waitUntil { sleeper.pendingCount == 1 })
        sleeper.releaseAll()
        #expect(await waitUntil { device.photoCount == 1 })
    }

    @Test func recordingFlowSavesAMovie() async throws {
        let model = await connectedModel()
        try command(.setMode(.video))
        #expect(await waitUntil { model.state.mode == .video })
        #expect(device.appliedSettings.mode == .video)

        try command(.startRecording(sendBack: false, delay: 0))
        #expect(await waitUntil { model.state.isRecording })
        #expect(device.isRecording)
        try command(.setMode(.photo))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(model.state.mode == .video)

        try command(.stopRecording)
        #expect(await waitUntil { model.captures.count == 1 && !model.state.isRecording })
        #expect(store.videos.count == 1)
        #expect(store.videoExistedWhenSaved == [true])
        #expect(!FileManager.default.fileExists(atPath: store.videos[0].path))
        let result = try #require(transport.lastCaptureResult)
        #expect(result.kind == .video)
        #expect(transport.sentStates.last?.isBusy == false)
        #expect(!result.willSendFile)
    }

    @Test func settingsCommandsReachTheDevice() async throws {
        let model = await connectedModel()
        try command(.setFlash(.on))
        try command(.setPosition(.front))
        #expect(await waitUntil { model.state.flash == .on && model.state.position == .front })
        #expect(device.appliedSettings == CameraSettings(mode: .photo, position: .front, flash: .on))
        try command(.ping)
        #expect(await waitUntil { transport.sentEvents.last == .pong })
    }

    @Test func disconnectResumesAdvertisingWithANewChallenge() async {
        let model = await connectedModel()
        let connectedInfo = transport.advertisedInfo
        transport.simulateDisconnected(remote)
        #expect(await waitUntil { model.link == .none && transport.isAdvertising })
        #expect(transport.advertisedInfo != connectedInfo)
    }
}
