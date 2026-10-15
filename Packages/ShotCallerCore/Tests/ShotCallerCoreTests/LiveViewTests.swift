import Foundation
import Testing
@testable import ShotCallerCore

@Suite struct PreviewPacketTests {
    let id = UUID()

    @Test func roundTripsEveryKind() throws {
        let packets: [PreviewPacket] = [
            .frameRequest(subscription: id, sequence: 7),
            .frame(subscription: id, sequence: 0xDEADBEEF, width: 480, height: 360, jpeg: Data([0xFF, 0xD8, 0x00, 0xFF, 0xD9])),
            .skipped(subscription: id, sequence: 1, reason: .transferring),
        ]
        for packet in packets {
            #expect(try PreviewPacket.decode(packet.encoded()) == packet)
        }
    }

    @Test func rejectsMalformedPackets() throws {
        let frame = PreviewPacket.frame(subscription: id, sequence: 1, width: 10, height: 10, jpeg: Data(repeating: 1, count: 16)).encoded()
        #expect(throws: PreviewPacket.DecodeError.truncated) { try PreviewPacket.decode(frame.prefix(5)) }
        #expect(throws: PreviewPacket.DecodeError.truncated) { try PreviewPacket.decode(frame.dropLast()) }
        #expect(throws: PreviewPacket.DecodeError.truncated) { try PreviewPacket.decode(frame + Data([0])) }
        var wrongVersion = frame; wrongVersion[0] = 9
        #expect(throws: PreviewPacket.DecodeError.unknownVersion(9)) { try PreviewPacket.decode(wrongVersion) }
        var wrongKind = frame; wrongKind[1] = 77
        #expect(throws: PreviewPacket.DecodeError.unknownKind(77)) { try PreviewPacket.decode(wrongKind) }
        var zeroWidth = frame; zeroWidth[22] = 0; zeroWidth[23] = 0
        #expect(throws: PreviewPacket.DecodeError.badDimensions) { try PreviewPacket.decode(zeroWidth) }
        var huge = frame; huge[26] = 0x7F   // claims ~2 GB of JPEG
        #expect(throws: PreviewPacket.DecodeError.payloadTooLarge(0x7F00_0010)) { try PreviewPacket.decode(huge) }
        var badReason = PreviewPacket.skipped(subscription: id, sequence: 1, reason: .noFrame).encoded(); badReason[22] = 200
        #expect(throws: PreviewPacket.DecodeError.unknownReason(200)) { try PreviewPacket.decode(badReason) }
    }
}

/// The camera's side of the live view, driven over an unlinked fake transport.
@Suite @MainActor struct LiveViewCameraTests {
    final class Thermal: @unchecked Sendable {
        private let lock = NSLock()
        private var _state: ProcessInfo.ThermalState = .nominal
        var state: ProcessInfo.ThermalState {
            get { lock.withLock { _state } }
            set { lock.withLock { _state = newValue } }
        }
    }

    let transport = FakeTransport(displayName: "iPhone · A7")
    let device = FakeCameraDevice(capabilities: CameraCapabilities(hasFlash: true, hasFrontCamera: true, canRecordVideo: true, canStreamPreview: true))
    let store = FakeMediaStore()
    let thermal = Thermal()
    let remote = Peer(id: "remote", displayName: "Remote")

    /// A paired camera with the Wi-Fi fast lane up unless `fastLane` says otherwise.
    func pairedCamera(fastLane: Bool = true, lease: TimeInterval = 10) async -> CameraHostModel {
        let thermal = self.thermal
        let model = CameraHostModel(transport: transport, device: device, mediaStore: store, appVersion: "2.0",
                                    thermalState: { thermal.state }, previewLease: lease)
        await model.start()
        let answers = Answers()
        transport.emit(.invitation(from: remote, context: nil, respond: answers.record))
        _ = await waitUntil { answers.values == [true] }
        transport.simulateConnected(remote)
        let nonce = await waitUntilValue { transport.sentChallengeNonce }!
        let proof = Pairing.proof(code: model.pairingCode, challenge: PairingChallenge(nonce: nonce), remoteName: "Remote")
        transport.emit(.message(try! encodedCommand(.pair(PairingSubmission(proof: proof, displayName: "Remote", appVersion: "2.0"))), from: remote))
        _ = await waitUntil { transport.didSendHello }
        transport.previewChannelAvailable = fastLane
        transport.emit(.fileChannelFast(fastLane))
        _ = await waitUntil { model.fileChannelFast == fastLane }
        return model
    }

    func command(_ command: RemoteCommand) {
        transport.emit(.message(try! encodedCommand(command), from: remote))
    }

    var startedSubscription: PreviewSubscription? {
        transport.sentEvents.compactMap { if case .previewStarted(let s) = $0 { return s } else { return nil } }.last
    }

    var refusals: [String] {
        transport.sentEvents.compactMap { if case .previewRefused(_, let reason) = $0 { return reason } else { return nil } }
    }

    var startedSubscriptions: [PreviewSubscription] {
        transport.sentEvents.compactMap { if case .previewStarted(let s) = $0 { return s } else { return nil } }
    }

    var endings: [(id: UUID, reason: String?)] {
        transport.sentEvents.compactMap { if case .previewEnded(let id, let reason) = $0 { return (id, reason) } else { return nil } }
    }

    var sentPackets: [PreviewPacket] {
        transport.sentPreviews.compactMap { try? PreviewPacket.decode($0.data) }
    }

    @Test func bluetoothOnlyIsRefusedAndTheTapStaysOff() async {
        let model = await pairedCamera(fastLane: false)
        command(.startPreview(PreviewRequest()))
        #expect(await waitUntil { !refusals.isEmpty })
        #expect(refusals.last == PreviewLimits.needsWiFiMessage)
        #expect(model.previewSubscription == nil)
        #expect(!device.previewFramesEnabled)
    }

    @Test func wiFiRequestIsClampedStartedAndServedOneFrameAtATime() async throws {
        let model = await pairedCamera()
        command(.startPreview(PreviewRequest(maxEdge: 4000, maxFPS: 60, maxBytes: 1)))
        let subscription = await waitUntilValue { startedSubscription }!
        #expect(subscription.maxEdge == PreviewLimits.maxEdge)
        #expect(subscription.fps == PreviewLimits.maxFPS)
        #expect(subscription.maxBytes == PreviewLimits.minBytes)
        #expect(model.previewSubscription == subscription)
        #expect(model.previewViewerName == "Remote")
        #expect(device.previewFramesEnabled)

        transport.emit(.preview(PreviewPacket.frameRequest(subscription: subscription.id, sequence: 1).encoded(), from: remote))
        #expect(await waitUntil { sentPackets.count == 1 })
        guard case .frame(let id, let sequence, let width, _, let jpeg) = sentPackets[0] else { Issue.record("expected a frame"); return }
        #expect(id == subscription.id && sequence == 1 && width == 480 && jpeg.count == 1024)
        #expect(model.previewFramesSent == 1)

        // A request from another subscription (a stale remote) is ignored; nothing is encoded for it.
        transport.emit(.preview(PreviewPacket.frameRequest(subscription: UUID(), sequence: 2).encoded(), from: remote))
        try await Task.sleep(for: .milliseconds(50))
        #expect(sentPackets.count == 1)
        #expect(device.previewFramesServed == 1)
    }

    @Test func aFrameThatDoesNotFitIsSkippedNotSent() async {
        let model = await pairedCamera()
        device.setPreviewFrameBytes(PreviewLimits.maxBytes + 1)
        command(.startPreview(PreviewRequest()))
        let subscription = await waitUntilValue { startedSubscription }!
        transport.emit(.preview(PreviewPacket.frameRequest(subscription: subscription.id, sequence: 3).encoded(), from: remote))
        #expect(await waitUntil { sentPackets.count == 1 })
        #expect(sentPackets[0] == .skipped(subscription: subscription.id, sequence: 3, reason: .noFrame))
        #expect(model.previewFramesSent == 0)
    }

    @Test func heatPausesThenStopsTheLiveView() async {
        let model = await pairedCamera()
        command(.startPreview(PreviewRequest()))
        let subscription = await waitUntilValue { startedSubscription }!
        thermal.state = .serious
        transport.emit(.preview(PreviewPacket.frameRequest(subscription: subscription.id, sequence: 1).encoded(), from: remote))
        #expect(await waitUntil { sentPackets.count == 1 })
        #expect(sentPackets[0] == .skipped(subscription: subscription.id, sequence: 1, reason: .thermal))
        thermal.state = .critical
        transport.emit(.preview(PreviewPacket.frameRequest(subscription: subscription.id, sequence: 2).encoded(), from: remote))
        #expect(await waitUntil { !endings.isEmpty })
        #expect(endings[0].id == subscription.id && endings[0].reason?.contains("cool") == true)
        #expect(model.previewSubscription == nil)
        #expect(await waitUntil { !device.previewFramesEnabled })
        // And a fresh request while critical is refused rather than started.
        command(.startPreview(PreviewRequest()))
        #expect(await waitUntil { !refusals.isEmpty })
    }

    @Test func stopFromTheRemoteEndsItAndReleasesTheDevice() async {
        let model = await pairedCamera()
        command(.startPreview(PreviewRequest()))
        let subscription = await waitUntilValue { startedSubscription }!
        command(.stopPreview(id: subscription.id))
        #expect(await waitUntil { model.previewSubscription == nil })
        #expect(await waitUntil { endings.count == 1 && endings[0].id == subscription.id && endings[0].reason == nil })
        #expect(await waitUntil { !device.previewFramesEnabled })
        // A stop for an unknown id changes nothing further.
        command(.stopPreview(id: UUID()))
        #expect(endings.count == 1)
    }

    @Test func losingTheFastLaneEndsTheLiveViewWithTheWiFiReason() async {
        let model = await pairedCamera()
        command(.startPreview(PreviewRequest()))
        _ = await waitUntilValue { startedSubscription }
        transport.previewChannelAvailable = false
        transport.emit(.fileChannelFast(false))
        #expect(await waitUntil { model.previewSubscription == nil })
        #expect(await waitUntil { endings.last?.reason == PreviewLimits.needsWiFiMessage })
        #expect(await waitUntil { !device.previewFramesEnabled })
    }

    @Test func anAbandonedLiveViewExpiresWithoutRequestsAndWithoutWords() async {
        let model = await pairedCamera(lease: 0.2)
        command(.startPreview(PreviewRequest()))
        let subscription = await waitUntilValue { startedSubscription }!
        #expect(await waitUntil { model.previewSubscription == nil })
        #expect(endings.count == 1 && endings[0].id == subscription.id && endings[0].reason == nil)
        #expect(await waitUntil { !device.previewFramesEnabled })
    }

    @Test func overlappingStartsLeaveOneOwnerOfTheTap() async throws {
        let model = await pairedCamera()
        device.setPreviewEnableDelay(.milliseconds(80))
        let first = PreviewRequest()
        let second = PreviewRequest()
        command(.startPreview(first))
        command(.startPreview(second))
        #expect(await waitUntil { startedSubscriptions.count == 2 })
        #expect(startedSubscriptions.map(\.requestID) == [first.requestID, second.requestID])
        #expect(model.previewSubscription?.requestID == second.requestID)
        try await Task.sleep(for: .milliseconds(300))   // no stray release from the replaced first start
        #expect(device.previewFramesEnabled)
        let subscription = model.previewSubscription!
        transport.emit(.preview(PreviewPacket.frameRequest(subscription: subscription.id, sequence: 1).encoded(), from: remote))
        #expect(await waitUntil { sentPackets.count == 1 })
        guard case .frame = sentPackets[0] else { Issue.record("expected a frame from the surviving subscription"); return }
    }

    @Test func aDeviceThatKeepsProducingNothingEndsTheViewWithAReason() async {
        let model = await pairedCamera()
        device.setPreviewFrameBytes(PreviewLimits.maxBytes * 4)   // never fits: every request is a miss
        command(.startPreview(PreviewRequest()))
        let subscription = await waitUntilValue { startedSubscription }!
        for sequence in UInt32(1)...9 {
            transport.emit(.preview(PreviewPacket.frameRequest(subscription: subscription.id, sequence: sequence).encoded(), from: remote))
            #expect(await waitUntil { sentPackets.count == Int(sequence) })
            #expect(sentPackets.last == .skipped(subscription: subscription.id, sequence: sequence, reason: .noFrame))
        }
        transport.emit(.preview(PreviewPacket.frameRequest(subscription: subscription.id, sequence: 10).encoded(), from: remote))
        #expect(await waitUntil { !endings.isEmpty })
        #expect(endings[0].reason?.contains("camera mode") == true)
        #expect(model.previewSubscription == nil)
    }

    @Test func theCameraCanStopSharing() async {
        let model = await pairedCamera()
        command(.startPreview(PreviewRequest()))
        _ = await waitUntilValue { startedSubscription }
        model.stopSharingPreview()
        #expect(model.previewSubscription == nil)
        #expect(model.previewViewerName == nil)
        #expect(endings.last?.reason == "The camera stopped sharing live view.")
    }

    @Test func aDisconnectEndsTheLiveViewSilently() async {
        let model = await pairedCamera()
        command(.startPreview(PreviewRequest()))
        _ = await waitUntilValue { startedSubscription }
        transport.simulateDisconnected(remote)
        #expect(await waitUntil { model.link == .none && model.previewSubscription == nil })
        #expect(endings.isEmpty)
        #expect(await waitUntil { !device.previewFramesEnabled })
    }
}

/// The remote's side, driven over an unlinked fake transport.
@Suite @MainActor struct LiveViewRemoteTests {
    let transport = FakeTransport(displayName: "Rich's iPad")
    let store = FakeMediaStore()
    let camera = aCamera()

    func connectedRemote(canStream: Bool = true, fastLane: Bool? = false) async -> RemoteModel {
        let model = RemoteModel(transport: transport, mediaStore: store, appVersion: "2.0")
        model.start()
        transport.emit(.peerFound(camera))
        _ = await waitUntil { model.cameras.count == 1 }
        model.connect(to: camera, code: PairingCode("1234")!)
        transport.simulateConnected(camera)
        if let fastLane { transport.emit(.fileChannelFast(fastLane)) }
        transport.emit(.message(try! encodedEvent(.challenge("nonce")), from: camera))
        _ = await waitUntil { transport.sentPairSubmission != nil }
        let capabilities = CameraCapabilities(hasFlash: true, hasFrontCamera: true, canRecordVideo: true, canStreamPreview: canStream)
        transport.emit(.message(try! encodedEvent(.hello(HelloInfo(appVersion: "2.0", displayName: "Camera", capabilities: capabilities))), from: camera))
        _ = await waitUntil { model.connection.isConnected }
        return model
    }

    func bringUpFastLane() {
        transport.previewChannelAvailable = true
        transport.emit(.fileChannelFast(true))
    }

    var startRequests: Int {
        transport.sentCommands.filter { if case .startPreview = $0 { return true } else { return false } }.count
    }

    var stopRequests: [UUID] {
        transport.sentCommands.compactMap { if case .stopPreview(let id) = $0 { return id } else { return nil } }
    }

    var frameRequests: [PreviewPacket] {
        transport.sentPreviews.compactMap { try? PreviewPacket.decode($0.data) }
    }

    var lastStartRequest: PreviewRequest? {
        transport.sentCommands.compactMap { if case .startPreview(let r) = $0 { return r } else { return nil } }.last
    }

    /// Answers the remote's latest start request with an accepted subscription.
    func accept(_ model: RemoteModel, expectedStarts: Int = 1) async -> PreviewSubscription {
        #expect(await waitUntil { startRequests == expectedStarts })
        let subscription = PreviewSubscription(requestID: lastStartRequest!.requestID, maxEdge: 480, fps: 5, maxBytes: 32 * 1024)
        transport.emit(.message(try! encodedEvent(.previewStarted(subscription)), from: camera))
        #expect(await waitUntil { frameRequests.count == expectedStarts })
        return subscription
    }

    func start(_ model: RemoteModel) async -> PreviewSubscription {
        bringUpFastLane()
        return await accept(model)
    }

    static func fakeJPEG(count: Int = 300) -> Data {
        Data([0xFF, 0xD8]) + Data(repeating: 1, count: max(0, count - 4)) + Data([0xFF, 0xD9])
    }

    func deliverFrame(_ subscription: PreviewSubscription, sequence: UInt32? = nil, jpeg: Data = fakeJPEG(), width: UInt16 = 480, height: UInt16 = 360) {
        let sequence = sequence ?? frameRequests.last!.sequence
        transport.emit(.preview(PreviewPacket.frame(subscription: subscription.id, sequence: sequence, width: width, height: height,
                                                    jpeg: jpeg).encoded(), from: camera))
    }

    @Test func asksForALiveViewOnlyOnceTheFastLaneIsUp() async {
        let model = await connectedRemote()
        #expect(model.preview == .unavailable(PreviewLimits.needsWiFiMessage))
        #expect(startRequests == 0)
        bringUpFastLane()
        #expect(await waitUntil { startRequests == 1 })
        #expect(model.preview == .starting)
    }

    @Test func aCameraThatCannotStreamIsExplainedNotAsked() async throws {
        let model = await connectedRemote(canStream: false)
        bringUpFastLane()
        try await Task.sleep(for: .milliseconds(50))
        #expect(startRequests == 0)
        #expect(model.preview == .unavailable("This camera can't share a live view."))
    }

    @Test func oneFrameRequestInFlightAndFramesArePaced() async throws {
        let model = await connectedRemote()
        let subscription = await start(model)
        try await Task.sleep(for: .milliseconds(100))
        #expect(frameRequests.count == 1)   // nothing more until the first one is answered
        deliverFrame(subscription)
        #expect(await waitUntil { model.preview == .live && model.previewFrame != nil })
        #expect(model.previewFrame?.width == 480 && model.previewFrame?.jpeg.count == 300)
        #expect(await waitUntil(timeout: .seconds(1)) { frameRequests.count == 2 })
        #expect(frameRequests[1].sequence == frameRequests[0].sequence + 1)
    }

    @Test func staleOrForeignFramesAreIgnored() async throws {
        let model = await connectedRemote()
        let subscription = await start(model)
        deliverFrame(subscription, sequence: frameRequests[0].sequence &+ 5)
        transport.emit(.preview(PreviewPacket.frame(subscription: UUID(), sequence: frameRequests[0].sequence, width: 1, height: 1,
                                                    jpeg: Data([1])).encoded(), from: camera))
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.previewFrame == nil)
        #expect(model.preview == .starting)
    }

    @Test func skipsAreShownAsPaused() async {
        let model = await connectedRemote()
        let subscription = await start(model)
        transport.emit(.preview(PreviewPacket.skipped(subscription: subscription.id, sequence: frameRequests[0].sequence, reason: .transferring).encoded(), from: camera))
        #expect(await waitUntil { model.preview == .paused("Live view paused while downloading.") })
        #expect(await waitUntil(timeout: .seconds(2)) { frameRequests.count == 2 })   // asks again after a pause
    }

    @Test func anUnansweredRequestIsMarkedStalledButNeverReissued() async throws {
        let model = await connectedRemote()
        model.previewTimeout = 0.1
        let subscription = await start(model)
        #expect(await waitUntil { model.preview == .stalled })
        try await Task.sleep(for: .milliseconds(300))
        #expect(frameRequests.count == 1)   // nothing stacks up behind a slow lane
        // The late answer is still the answer: shown, and the loop continues.
        deliverFrame(subscription)
        #expect(await waitUntil { model.preview == .live && model.previewFrame != nil })
        #expect(await waitUntil { frameRequests.count == 2 })
    }

    @Test func anOldPictureIsAgedByTheWatchdogDespiteSkips() async {
        let model = await connectedRemote()
        model.previewTimeout = 0.2
        let subscription = await start(model)
        deliverFrame(subscription)
        #expect(await waitUntil { model.preview == .live })
        // The camera keeps answering "no frame": the picture stays, then is called stalled, then goes.
        let skipper = Task { [transport] in
            while !Task.isCancelled {
                let sequence = await MainActor.run { transport.sentPreviews.compactMap { try? PreviewPacket.decode($0.data) }.last?.sequence } ?? 0
                transport.emit(.preview(PreviewPacket.skipped(subscription: subscription.id, sequence: sequence, reason: .noFrame).encoded(), from: camera))
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { skipper.cancel() }
        #expect(await waitUntil { model.preview == .stalled && model.previewFrame != nil })
        #expect(await waitUntil(timeout: .seconds(5)) { model.previewFrame == nil })
    }

    @Test func aFrameOutsideTheTermsIsNotShown() async throws {
        let model = await connectedRemote()
        let subscription = await start(model)
        deliverFrame(subscription, jpeg: Self.fakeJPEG(count: 32 * 1024 + 1))
        #expect(await waitUntil { frameRequests.count == 2 })   // treated as a skip: asks again
        #expect(model.previewFrame == nil)
        deliverFrame(subscription, jpeg: Data(repeating: 1, count: 300))   // no JPEG markers
        #expect(await waitUntil { frameRequests.count == 3 })
        #expect(model.previewFrame == nil)
        deliverFrame(subscription, width: 900, height: 600)   // bigger than negotiated
        #expect(await waitUntil { frameRequests.count == 4 })
        #expect(model.previewFrame == nil)
        deliverFrame(subscription)
        #expect(await waitUntil { model.preview == .live && model.previewFrame != nil })
    }

    @Test func anAnswerToAnOldStartRequestIsStoppedAndTheRealOneAwaited() async {
        let model = await connectedRemote()
        bringUpFastLane()
        #expect(await waitUntil { startRequests == 1 })
        let stray = PreviewSubscription(requestID: UUID(), maxEdge: 480, fps: 5, maxBytes: 32 * 1024)
        transport.emit(.message(try! encodedEvent(.previewStarted(stray)), from: camera))
        #expect(await waitUntil { stopRequests == [stray.id] })
        #expect(model.preview == .starting)
        _ = await accept(model)
        #expect(await waitUntil { frameRequests.count == 1 })
    }

    @Test func aDelayedEndForARetiredSubscriptionDoesNotCancelANewStart() async {
        let model = await connectedRemote()
        let first = await start(model)
        model.setPreviewDemand(false)
        #expect(stopRequests == [first.id])
        model.setPreviewDemand(true)
        #expect(await waitUntil { startRequests == 2 })
        // The camera's end for the first subscription arrives late, while the second start is pending.
        transport.emit(.message(try! encodedEvent(.previewEnded(id: first.id, reason: nil)), from: camera))
        #expect(model.preview == .starting)
        let second = await accept(model, expectedStarts: 2)
        deliverFrame(second)
        #expect(await waitUntil { model.preview == .live })
    }

    @Test func anEndWithoutWordsRenewsTheView() async {
        let model = await connectedRemote()
        let first = await start(model)
        transport.emit(.message(try! encodedEvent(.previewEnded(id: first.id, reason: nil)), from: camera))
        #expect(await waitUntil { startRequests == 2 })
        #expect(model.preview == .starting && model.previewFrame == nil)
    }

    @Test func losingTheFastLaneClearsTheLiveView() async throws {
        let model = await connectedRemote()
        let subscription = await start(model)
        deliverFrame(subscription)
        #expect(await waitUntil { model.previewFrame != nil })
        transport.previewChannelAvailable = false
        transport.emit(.fileChannelFast(false))
        #expect(await waitUntil { model.preview == .unavailable(PreviewLimits.needsWiFiMessage) })
        #expect(model.previewFrame == nil)
        let requests = frameRequests.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(frameRequests.count == requests)   // no more requests while the lane is down
        bringUpFastLane()
        #expect(await waitUntil { startRequests == 2 })   // asks again when it returns
    }

    @Test func anInactiveSceneStopsAndClearsThenResumes() async {
        let model = await connectedRemote()
        let subscription = await start(model)
        deliverFrame(subscription)
        #expect(await waitUntil { model.previewFrame != nil })
        model.setPreviewDemand(false)
        #expect(model.previewFrame == nil && model.preview == .off)
        #expect(stopRequests == [subscription.id])
        model.setPreviewDemand(true)
        #expect(await waitUntil { startRequests == 2 })
    }

    @Test func turningLiveViewOffStopsItAndTheCamerasEndIsQuiet() async {
        let model = await connectedRemote()
        let subscription = await start(model)
        model.setPreviewEnabled(false)
        #expect(stopRequests == [subscription.id] && model.preview == .off)
        transport.emit(.message(try! encodedEvent(.previewEnded(id: subscription.id, reason: nil)), from: camera))
        #expect(await waitUntil { model.preview == .off })
        #expect(!model.wantsPreview)
        model.setPreviewEnabled(true)
        #expect(await waitUntil { startRequests == 2 })
    }

    @Test func aCameraThatStopsSharingSaysSo() async {
        let model = await connectedRemote()
        let subscription = await start(model)
        transport.emit(.message(try! encodedEvent(.previewEnded(id: subscription.id, reason: "The camera stopped sharing live view.")), from: camera))
        #expect(await waitUntil { model.preview == .unavailable("The camera stopped sharing live view.") })
        #expect(model.previewFrame == nil)
    }

    @Test func aRefusalIsShown() async {
        let model = await connectedRemote()
        bringUpFastLane()
        #expect(await waitUntil { startRequests == 1 })
        transport.emit(.message(try! encodedEvent(.previewRefused(requestID: lastStartRequest!.requestID, reason: "Live view is off while the camera cools down.")), from: camera))
        #expect(await waitUntil { model.preview == .unavailable("Live view is off while the camera cools down.") })
    }

    @Test func disconnectingClearsEverything() async {
        let model = await connectedRemote()
        let subscription = await start(model)
        deliverFrame(subscription)
        #expect(await waitUntil { model.previewFrame != nil })
        model.disconnect()
        #expect(model.preview == .off && model.previewFrame == nil)
    }
}

/// Both models over linked fake transports: the live view from request to frames to stop.
@Suite @MainActor struct LiveViewEndToEndTests {
    @Test func framesFlowOverTheFastLaneAndStopOnCommand() async throws {
        let (cameraTransport, remoteTransport) = FakeTransport.linkedPair(cameraName: "iPhone · A7", remoteName: "Rich's iPad")
        let device = FakeCameraDevice(capabilities: CameraCapabilities(hasFlash: true, hasFrontCamera: true, canRecordVideo: true, canStreamPreview: true))
        let camera = CameraHostModel(transport: cameraTransport, device: device, mediaStore: FakeMediaStore(), appVersion: "2.0")
        let remote = RemoteModel(transport: remoteTransport, mediaStore: FakeMediaStore(), appVersion: "2.0")
        await camera.start()
        remote.start()
        #expect(await waitUntil { remote.cameras.count == 1 })
        remote.connect(to: remote.cameras[0], code: camera.pairingCode)
        #expect(await waitUntil { remote.connection.isConnected && camera.isPaired })
        // The lane speed is unknown on a fake transport, which counts as "no fast lane" until told otherwise.
        #expect(remote.preview == .unavailable(PreviewLimits.needsWiFiMessage))

        // The fast lane comes up on both ends.
        cameraTransport.previewChannelAvailable = true
        remoteTransport.previewChannelAvailable = true
        cameraTransport.emit(.fileChannelFast(true))
        remoteTransport.emit(.fileChannelFast(true))
        #expect(await waitUntil { remote.preview == .live && remote.previewFrame != nil })
        #expect(camera.previewViewerName == "Rich's iPad")
        #expect(await waitUntil { camera.previewFramesSent >= 3 })
        // Frames never touched the message (Bluetooth) channel: every message is JSON.
        #expect(cameraTransport.sentMessages.allSatisfy { $0.data.first == UInt8(ascii: "{") })

        // The camera stops sharing; the remote says why and asks for nothing more.
        camera.stopSharingPreview()
        #expect(await waitUntil { remote.preview == .unavailable("The camera stopped sharing live view.") })
        #expect(await waitUntil { !device.previewFramesEnabled })
        let requests = remoteTransport.sentPreviews.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(remoteTransport.sentPreviews.count == requests)

        // Turning it off and on again from the remote brings it back.
        remote.setPreviewEnabled(false)
        remote.setPreviewEnabled(true)
        #expect(await waitUntil { remote.preview == .live })
        #expect(device.previewFramesEnabled)

        remote.disconnect()
        #expect(await waitUntil { camera.link == .none && camera.previewSubscription == nil })
        #expect(remote.preview == .off && remote.previewFrame == nil)
        #expect(await waitUntil { !device.previewFramesEnabled })
    }
}
