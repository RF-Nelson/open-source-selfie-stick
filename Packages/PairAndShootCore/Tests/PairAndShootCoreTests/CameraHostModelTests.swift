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

    /// Drives the full data-channel handshake with the right code and returns once paired.
    func connectedModel(code: PairingCode? = nil) async -> CameraHostModel {
        let model = await makeModel()
        let answers = Answers()
        transport.emit(.invitation(from: remote, context: nil, respond: answers.record))
        _ = await waitUntil { answers.values == [true] }
        transport.simulateConnected(remote)
        let nonce = await waitUntilValue { transport.sentChallengeNonce }!
        let proof = Pairing.proof(code: code ?? model.pairingCode, challenge: PairingChallenge(nonce: nonce), remoteName: "Remote")
        transport.emit(.message(try! encodedCommand(.pair(PairingSubmission(proof: proof, displayName: "Remote", appVersion: "2.0"))), from: remote))
        _ = await waitUntil { transport.didSendHello }
        return model
    }

    func command(_ command: RemoteCommand) throws {
        transport.emit(.message(try encodedCommand(command), from: remote))
    }

    @Test func startsAdvertising() async throws {
        let model = await makeModel()
        #expect(model.availability == .ready)
        #expect(transport.isAdvertising)
        #expect(Pairing.isCompatibleCamera(transport.advertisedInfo))
        #expect(device.appliedSettings == CameraSettings())
        #expect(model.capabilities.canRecordVideo)
    }

    @Test func unusableCameraIsReportedNotAdvertised() async {
        device.failStart(with: .permissionDenied("camera"))
        let model = await makeModel()
        #expect(model.availability == .unavailable(CameraDeviceError.permissionDenied("camera").errorDescription!))
        #expect(!transport.isAdvertising)
    }

    /// One wrong-code attempt: connect, get challenged, send a bad proof, get rejected + disconnected.
    func attemptWrongCode(_ model: CameraHostModel) async {
        let answers = Answers()
        transport.emit(.invitation(from: remote, context: nil, respond: answers.record))
        _ = await waitUntil { answers.values.count == 1 }
        guard answers.values == [true] else { return }   // refused outright (already linked)
        transport.simulateConnected(remote)
        _ = await waitUntilValue { transport.sentChallengeNonce }
        transport.emit(.message(try! encodedCommand(.pair(PairingSubmission(proof: Data("junk".utf8), displayName: "Remote", appVersion: "2.0"))), from: remote))
        _ = await waitUntil { model.link == .none }        // camera disconnects on a wrong code
        transport.simulateDisconnected(remote)
        _ = await waitUntil { transport.isAdvertising }
    }

    @Test func wrongCodeIsRejectedAndTheCodeRotatesAfterThree() async {
        let model = await makeModel()
        let firstCode = model.pairingCode
        await attemptWrongCode(model)
        await attemptWrongCode(model)
        #expect(model.pairingCode == firstCode)
        await attemptWrongCode(model)
        #expect(await waitUntil { model.pairingCode != firstCode })
        #expect(model.notice?.contains("new code") == true)
    }

    @Test func rightCodeIsAcceptedThenHelloAndStateAreSent() async throws {
        let model = await connectedModel()
        #expect(!transport.isAdvertising)
        // A challenge goes out first, then (after a valid proof) a hello carrying capabilities.
        #expect(transport.sentChallengeNonce != nil)
        let hello = try #require(transport.sentEvents.compactMap { event -> HelloInfo? in
            if case .hello(let info) = event { return info }
            return nil
        }.last)
        #expect(hello.capabilities == model.capabilities)
        #expect(transport.sentStates.last == model.state)
        // The link records the remote's identity from its pairing submission.
        if case .connected(_, let info) = model.link {
            #expect(info?.displayName == "Remote")
        } else {
            Issue.record("expected a connected link, got \(model.link)")
        }
    }

    @Test func systemPairedTransportSkipsTheCodeHandshake() async throws {
        // A transport that pairs at the OS level (Wi-Fi Aware): no challenge, immediate readiness.
        let wa = FakeTransport(displayName: "iPhone A7", appLevelPairing: false)
        let model = CameraHostModel(transport: wa, device: device, mediaStore: store, appVersion: "2.0", sleep: sleeper.sleep)
        await model.start()
        wa.emit(.connected(remote))
        #expect(await waitUntil { wa.didSendHello })
        #expect(wa.sentChallengeNonce == nil)                 // no code handshake
        if case .connected = model.link {} else { Issue.record("expected connected link, got \(model.link)") }
        // Paired immediately: a capture command works with no code exchanged.
        wa.emit(.message(try! encodedCommand(.capturePhoto(sendBack: false, delay: 0)), from: remote))
        #expect(await waitUntil { device.photoCount == 1 })
    }

    @Test func controlCommandsAreIgnoredUntilPaired() async throws {
        let model = await makeModel()
        let answers = Answers()
        transport.emit(.invitation(from: remote, context: nil, respond: answers.record))
        _ = await waitUntil { answers.values == [true] }
        transport.simulateConnected(remote)
        _ = await waitUntilValue { transport.sentChallengeNonce }
        // A capture command before pairing must be ignored.
        try command(.capturePhoto(sendBack: false, delay: 0))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(device.photoCount == 0)
    }

    @Test func secondRemoteIsRefusedWhileOneIsConnected() async {
        let model = await connectedModel()
        let answers = Answers()
        let intruder = Peer(id: "intruder", displayName: "Someone")
        transport.emit(.invitation(from: intruder, context: nil, respond: answers.record))
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
        #expect(sent.name.hasSuffix(".jpg"))
        #expect(sent.peer.id == "remote")
        let result = try #require(transport.lastCaptureResult)
        #expect(result.willSendFile)
        #expect(result.fileName?.hasPrefix("IMG_") == true)
        // The transfer is named by capture id (so the remote can correlate it), not the display name.
        #expect(sent.name == TransferName.make(id: result.id, ext: "jpg"))
        #expect(await waitUntil { model.outgoingTransfer?.phase == .sent })
        #expect(!FileManager.default.fileExists(atPath: sent.url.path))
        #expect(transport.sentStates.contains { $0.isBusy })
        #expect(model.state.isBusy == false)
    }

    @Test func bluetoothOnlyDefersTheFileUntilRequested() async throws {
        let model = await connectedModel()
        transport.emit(.fileChannelFast(false))   // a Bluetooth-only link, no Wi-Fi fast lane
        _ = await waitUntil { model.fileChannelFast == false }
        try command(.capturePhoto(sendBack: true, delay: 0))
        #expect(await waitUntil { model.captures.count == 1 })
        let result = try #require(transport.lastCaptureResult)
        #expect(!result.willSendFile)              // deferred, not slow-pushed over Bluetooth
        #expect(result.fileAvailable)
        #expect(transport.sentFiles.isEmpty)
        // The remote asks for it → the camera sends it.
        try command(.requestFile(id: result.id, quality: .full))
        #expect(await waitUntil { transport.sentFiles.count == 1 })
        #expect(transport.sentFiles.first?.name == TransferName.make(id: result.id, ext: "jpg"))
    }

    @Test func deferredFilesFlushWhenAFastLaneAppears() async throws {
        let model = await connectedModel()
        transport.emit(.fileChannelFast(false))
        _ = await waitUntil { model.fileChannelFast == false }
        try command(.capturePhoto(sendBack: true, delay: 0))
        #expect(await waitUntil { model.captures.count == 1 })
        #expect(transport.sentFiles.isEmpty)
        transport.emit(.fileChannelFast(true))     // Wi-Fi lane comes up → deferred files flush
        #expect(await waitUntil { transport.sentFiles.count == 1 })
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

    @Test func disconnectResumesAdvertising() async {
        let model = await connectedModel()
        transport.simulateDisconnected(remote)
        #expect(await waitUntil { model.link == .none && transport.isAdvertising })
    }
}
