import Foundation
import Observation

/// Everything the camera screen shows and does, and everything a paired remote may ask of it.
/// Local buttons and remote commands go through the same `perform(_:)`, so both behave identically.
@MainActor
@Observable
public final class CameraHostModel {
    public enum Availability: Hashable, Sendable {
        case starting
        case ready
        case unavailable(String)
    }

    public enum Link: Hashable, Sendable {
        case none
        case connecting(Peer)
        case connected(Peer, HelloInfo?)

        public var peer: Peer? {
            switch self {
            case .connecting(let peer), .connected(let peer, _): peer
            case .none: nil
            }
        }

        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    public static let maxFailedAttempts = 3

    public private(set) var availability: Availability = .starting
    public private(set) var capabilities = CameraCapabilities()
    public private(set) var link: Link = .none
    public private(set) var pairingCode = PairingCode.random()
    public private(set) var state = CameraState()
    public private(set) var captures: [CaptureResult] = []
    public private(set) var outgoingTransfer: TransferStatus?
    public private(set) var notice: String?
    public private(set) var unsavedCaptureCount = 0
    /// The current file-transfer channel while connected: false = Bluetooth only, true = Bluetooth + a
    /// fast Wi-Fi lane. nil when the transport is single-channel (Wi-Fi Aware) or not connected.
    public private(set) var fileChannelFast: Bool?
    /// The live view a paired remote is receiving, if any. Frames are produced only on request (one
    /// at a time), only over the Wi-Fi fast lane, and only after the code was proved.
    public private(set) var previewSubscription: PreviewSubscription?
    /// What the paired remote wants copies of (it tells us after pairing and on every change). The
    /// camera's own shutter uses this, so a shot taken at the camera reaches the remote the same way.
    public private(set) var remoteSendBack = SendBackPreferences()
    /// Who is receiving the live view: the paired remote's name, for the "Sharing live view" indicator.
    public var previewViewerName: String? {
        guard previewSubscription != nil, case .connected(let peer, let info) = link else { return nil }
        return info?.displayName ?? peer.displayName
    }

    public var lastCapture: CaptureResult? { captures.last }
    /// Original files still waiting for delivery, including queued and active transfers.
    public var pendingTransferCount: Int { pendingTransferIDs.count }
    /// Transfers whose originals are not safely saved in this camera's Photos library.
    public var unsavedTransferCount: Int {
        captures.filter { pendingTransferIDs.contains($0.id) && $0.savedOnCamera != true }.count
    }
    private var pendingTransferIDs: Set<UUID> {
        var ids = pendingCaptureIDs.union(sendQueue.map(\.id))
        if let activeSendID { ids.insert(activeSendID) }
        return ids
    }
    public var localName: String { transport.localPeer.displayName }
    /// Whether this camera authenticates with a 4-digit code (Multipeer). Wi-Fi Aware pairs at the
    /// system level, so the code UI is replaced by the system pairing flow.
    public var usesCodePairing: Bool { transport.requiresAppLevelPairing }

    /// Whether this device keeps its own copy of every capture in its Photos library.
    public var keepsCopies: Bool {
        get { state.keepsCopies }
        set {
            state.keepsCopies = newValue
            broadcastState()
        }
    }

    @ObservationIgnored private let transport: any PeerTransport
    @ObservationIgnored private let device: any CameraDevice
    @ObservationIgnored private let mediaStore: any MediaStore
    @ObservationIgnored private let thumbnails: any ThumbnailMaker
    @ObservationIgnored private let codec = MessageCodec()
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private let sleep: (@Sendable (Duration) async throws -> Void)?
    @ObservationIgnored private let thermalState: @Sendable () -> ProcessInfo.ThermalState
    /// Seconds without a frame request before a live view is dropped as abandoned (a remote that
    /// locked, crashed or lost the lane without saying stop). Tests shorten it.
    @ObservationIgnored private let previewLease: TimeInterval
    @ObservationIgnored private var previewLeaseTask: Task<Void, Never>?
    @ObservationIgnored private var previewRequestInFlight = false
    /// The newest frame request not yet served; a request arriving mid-encode replaces it, so the
    /// remote's latest demand wins and nothing accumulates.
    @ObservationIgnored private var pendingPreviewSequence: UInt32?
    @ObservationIgnored private var previewTransition: Task<Void, Never>?
    @ObservationIgnored private var previewMisses = 0
    @ObservationIgnored private(set) var previewFramesSent = 0
    @ObservationIgnored private var currentChallenge = PairingChallenge.random()
    @ObservationIgnored private var failedAttempts = 0
    /// True once the connected remote has proved the code (or, on Wi-Fi Aware, as soon as it connects).
    /// `link.isConnected` alone is not authentication: a remote is connected while it is still proving.
    public private(set) var isPaired = false
    @ObservationIgnored private var pairingTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var recordingTicker: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingVideoSendBack = false
    /// Files the camera is holding for a capture, keyed by capture id — either about to be sent, or
    /// deferred (only Bluetooth was up) until the remote asks or a Wi-Fi lane appears.
    private struct HeldFile { let url: URL; let kind: CaptureKind; let photoData: Data? }
    @ObservationIgnored private var heldFiles: [UUID: HeldFile] = [:]
    @ObservationIgnored private var unsavedFiles: [UUID: HeldFile] = [:]
    @ObservationIgnored private var isRetryingSaves = false
    /// Captures whose full file is deferred, waiting for a request or a fast link.
    private var pendingCaptureIDs: Set<UUID> = []
    @ObservationIgnored private var expectsDisconnect = false
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var isStartingCamera = false
    @ObservationIgnored private var restartCameraAfterStart = false
    @ObservationIgnored private var isUpdatingSettings = false
    @ObservationIgnored private var settingsUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    private var activeSendID: UUID?
    @ObservationIgnored private var activeSendToken: UUID?
    @ObservationIgnored private var activeSendHasStarted = false
    @ObservationIgnored private var cancelingSendID: UUID?
    private var sendQueue: [(id: UUID, quality: TransferQuality, allowSlow: Bool)] = []
    @ObservationIgnored private var compressedFiles: [URL] = []
    @ObservationIgnored private let outboxDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShotCallerOutbox-\(UUID().uuidString)", isDirectory: true)

    public init(transport: any PeerTransport,
                device: any CameraDevice,
                mediaStore: any MediaStore,
                thumbnails: any ThumbnailMaker = NoThumbnails(),
                appVersion: String,
                sleep: (@Sendable (Duration) async throws -> Void)? = nil,
                thermalState: (@Sendable () -> ProcessInfo.ThermalState)? = nil,
                previewLease: TimeInterval = 10) {
        self.transport = transport
        self.device = device
        self.mediaStore = mediaStore
        self.thumbnails = thumbnails
        self.appVersion = appVersion
        self.sleep = sleep
        self.thermalState = thermalState ?? { ProcessInfo.processInfo.thermalState }
        self.previewLease = previewLease
    }

    // MARK: Lifecycle

    public func start() async {
        guard !isStopped else { return }
        if eventTask == nil {
            eventTask = Task { [weak self, transport] in
                for await event in transport.events {
                    guard let self, !Task.isCancelled else { return }
                    self.handle(event)
                }
            }
        }
        await retryCamera()
    }

    public func resume() async { await retryCamera() }

    /// Rechecks camera authorization after a trip to Settings and resumes after backgrounding.
    public func retryCamera() async {
        if let shutdownTask { await shutdownTask.value }
        guard !isStopped, !state.isRecording else { return }
        guard !isStartingCamera else {
            // A start that began before a suspend abandons itself; run again once it has unwound so
            // a quick background/foreground trip can't leave the camera stuck on "starting".
            restartCameraAfterStart = true
            return
        }
        guard !isActive || availability != .ready else { return }
        isActive = true
        isStartingCamera = true
        availability = .starting
        await startDevice()
        isStartingCamera = false
        if restartCameraAfterStart {
            restartCameraAfterStart = false
            await retryCamera()
        }
    }

    private func startDevice() async {
        do {
            var updatedCapabilities = try await device.start()
            guard isActive else { return }
            try await device.apply(settings)
            guard isActive else { return }
            updatedCapabilities.canStreamPreview = updatedCapabilities.canStreamPreview || device.supportsPreviewFrames
            capabilities = updatedCapabilities
            availability = .ready
            if link == .none { advertise() }
        } catch {
            guard isActive else { return }
            availability = .unavailable(Self.describe(error))
        }
    }

    /// Finish a recording before the app leaves the foreground; keep the event stream reusable.
    public func suspend() async {
        guard !isStopped else { return }
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isActive = false
        let task = Task { [self] in
            captureTask?.cancel()
            await captureTask?.value
            await settingsUpdateTask?.value
            if state.isRecording { await stopRecording() }
            recordingTicker?.cancel()
            recordingTicker = nil
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            expectsDisconnect = true
            endPreview(reason: nil, notify: false)
            transport.stopAdvertising()
            transport.disconnect()
            await device.stop()
            isPaired = false
            link = .none
            state.countdown = nil
            state.isBusy = false
            fileChannelFast = nil
            outgoingTransfer = nil
            discardHeldFiles()
            availability = .starting
        }
        shutdownTask = task
        await task.value
        shutdownTask = nil
    }

    public func stop() async {
        guard !isStopped else { return }
        await suspend()
        isStopped = true
        eventTask?.cancel()
        eventTask = nil
        noticeTask?.cancel()
        for file in unsavedFiles.values { try? FileManager.default.removeItem(at: file.url) }
        unsavedFiles.removeAll()
        unsavedCaptureCount = 0
        try? FileManager.default.removeItem(at: outboxDirectory)
    }

    /// Retry files retained after a Photos error, including after authorization changes in Settings.
    public func retrySavingCaptures() async {
        guard !isRetryingSaves else { return }
        isRetryingSaves = true
        defer { isRetryingSaves = false }
        for (id, file) in unsavedFiles {
            do {
                if file.kind == .photo {
                    try await mediaStore.savePhoto(data: file.photoData ?? Data(contentsOf: file.url), fileExtension: file.url.pathExtension)
                } else {
                    try await mediaStore.saveVideo(fileURL: file.url)
                }
                unsavedFiles[id] = nil
                unsavedCaptureCount = unsavedFiles.count
                if heldFiles[id] == nil { try? FileManager.default.removeItem(at: file.url) }
                if let index = captures.firstIndex(where: { $0.id == id }) {
                    captures[index].savedOnCamera = true
                    send(.captureFinished(captures[index]))
                }
            } catch {
                show("Couldn't save to Photos. \(Self.describe(error))")
                return
            }
        }
        if unsavedCaptureCount == 0 { show("Saved to Photos.") }
    }

    public func disconnectRemote() {
        expectsDisconnect = true
        transport.disconnect()
    }

    /// The person at the camera stops the live view; the remote is told why.
    public func stopSharingPreview() {
        endPreview(reason: "The camera stopped sharing live view.", notify: true)
    }

    /// Issues a new code, for example when the person holding the camera thinks someone saw the old one.
    public func regenerateCode() {
        pairingCode = .random()
        failedAttempts = 0
        if !link.isConnected { advertise() }
    }

    // MARK: Actions

    /// Runs a command, whether it came from a button on this screen or from the remote.
    public func perform(_ command: RemoteCommand) {
        Task { await execute(command) }
    }

    /// The camera's own shutter: the same commands a remote would send, with the remote's copy
    /// preferences applied, so the person at the camera never has to know how delivery works.
    public func shutter(delay: Int) {
        if state.countdown != nil {
            perform(.cancelCountdown)
            return
        }
        switch state.mode {
        case .photo:
            perform(.capturePhoto(sendBack: remoteSendBack.photos, delay: delay))
        case .video:
            perform(state.isRecording ? .stopRecording : .startRecording(sendBack: remoteSendBack.videos, delay: delay))
        }
    }

    public func dismissNotice() {
        notice = nil
    }

    private var settings: CameraSettings {
        CameraSettings(mode: state.mode, position: state.position, flash: state.flash)
    }

    private func execute(_ command: RemoteCommand) async {
        if case .pair(let submission) = command {
            await handlePairing(submission)
            return
        }
        // Peer authorization is checked in handleMessage; local controls also work before pairing.
        guard isActive else { return }
        switch command {
        case .pair:
            break
        case .capturePhoto(let sendBack, let delay):
            startCapture { await self.capturePhoto(sendBack: sendBack, delay: delay) }
        case .startRecording(let sendBack, let delay):
            startCapture { await self.startRecording(sendBack: sendBack, delay: delay) }
        case .stopRecording:
            startCapture { await self.stopRecording() }
        case .cancelCountdown:
            if state.countdown != nil { captureTask?.cancel() }
        case .setMode(let mode):
            guard !state.isRecording, !state.isBusy, state.countdown == nil, mode != state.mode else { return }
            guard mode == .photo || capabilities.canRecordVideo else { return }
            await update { $0.mode = mode }
        case .setPosition(let position):
            guard !state.isRecording, !state.isBusy, state.countdown == nil, position != state.position else { return }
            guard position == .back || capabilities.hasFrontCamera else { return }
            await update { $0.position = position }
        case .setFlash(let flash):
            guard flash != state.flash else { return }
            guard flash == .off || capabilities.hasFlash else { return }
            await update { $0.flash = flash }
        case .requestFile(let id, let quality):
            queueHeldFile(id: id, quality: quality, allowSlow: true)
        case .cancelTransfer(let id):
            cancelHeldSend(id: id)
        case .startPreview(let request):
            await enqueuePreviewTransition { [weak self] in await self?.startPreview(request) }.value
        case .stopPreview(let id):
            if previewSubscription?.id == id { endPreview(reason: nil, notify: true) }
        case .setSendBack(let preferences):
            remoteSendBack = preferences
        case .ping:
            send(.pong)
        }
    }

    // MARK: Live view

    /// Every change to the device's frame tap runs through one chain, so a start never races an
    /// earlier release and an obsolete release can never disable the tap a newer subscription owns.
    @discardableResult
    private func enqueuePreviewTransition(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = previewTransition
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        previewTransition = task
        return task
    }

    /// Accept a live-view request, on clamped terms, when every precondition holds: a paired remote,
    /// a camera that can produce frames, a transport with a preview channel, and that channel up.
    /// Bluetooth alone is refused outright: frames never ride the control lane.
    private func startPreview(_ request: PreviewRequest) async {
        guard isPaired, case .connected = link else { return }
        guard capabilities.canStreamPreview, transport.supportsPreviewChannel else {
            send(.previewRefused(requestID: request.requestID, reason: "This camera can't share a live view."))
            return
        }
        guard fileChannelFast == true else {
            send(.previewRefused(requestID: request.requestID, reason: PreviewLimits.needsWiFiMessage))
            return
        }
        guard thermalState() != .critical else {
            send(.previewRefused(requestID: request.requestID, reason: "Live view is off while the camera cools down."))
            return
        }
        if previewSubscription != nil { endPreview(reason: nil, notify: false, releaseDevice: false) }
        let subscription = PreviewSubscription(
            requestID: request.requestID,
            maxEdge: min(max(request.maxEdge, PreviewLimits.minEdge), PreviewLimits.maxEdge),
            fps: min(max(request.maxFPS, 1), PreviewLimits.maxFPS),
            maxBytes: min(max(request.maxBytes, PreviewLimits.minBytes), PreviewLimits.maxBytes))
        do {
            try await device.setPreviewFramesEnabled(true)
        } catch {
            send(.previewRefused(requestID: request.requestID, reason: "Live view isn't available right now. \(Self.describe(error))"))
            return
        }
        // The link may have changed while the device reconfigured. Nobody owns the tap, so release it.
        guard isPaired, case .connected = link, fileChannelFast == true, previewSubscription == nil else {
            try? await device.setPreviewFramesEnabled(false)
            return
        }
        previewSubscription = subscription
        previewMisses = 0
        armPreviewLease()
        Trace.log("camera: live view started \(subscription.maxEdge)px/\(subscription.fps)fps/\(subscription.maxBytes)B")
        send(.previewStarted(subscription))
    }

    /// Ends the live view locally and, when `notify`, tells the remote (reason nil = not the camera's
    /// doing: at the remote's request, or an abandoned subscription the remote may simply renew). The
    /// device's frame tap is released through the transition chain, and only if no newer subscription
    /// has taken it; `releaseDevice: false` skips that when a replacement is about to re-enable it.
    private func endPreview(reason: String?, notify: Bool, releaseDevice: Bool = true) {
        guard let subscription = previewSubscription else { return }
        previewSubscription = nil
        previewLeaseTask?.cancel()
        previewLeaseTask = nil
        pendingPreviewSequence = nil
        Trace.log("camera: live view ended\(reason.map { ": " + $0 } ?? "")")
        if notify { send(.previewEnded(id: subscription.id, reason: reason)) }
        if releaseDevice {
            enqueuePreviewTransition { [weak self] in
                guard let self, self.previewSubscription == nil else { return }
                try? await self.device.setPreviewFramesEnabled(false)
            }
        }
    }

    private func armPreviewLease() {
        previewLeaseTask?.cancel()
        let lease = previewLease
        previewLeaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(lease))
            guard let self, !Task.isCancelled else { return }
            // No request for a while: the remote locked, lost the lane, or stalled. No words — a remote
            // that still wants the view renews it by itself.
            self.endPreview(reason: nil, notify: true)
        }
    }

    private func handlePreviewPacket(_ data: Data) {
        guard let subscription = previewSubscription,
              let packet = try? PreviewPacket.decode(data),
              case .frameRequest(let id, let sequence) = packet, id == subscription.id else { return }
        armPreviewLease()
        pendingPreviewSequence = sequence
        servePreviewRequest()
    }

    /// Serves the newest outstanding frame request: one encode at a time, yielding to heat and to a
    /// file transfer. Each answer is a frame or an explicit skip, so the remote is never left waiting;
    /// a device that produces nothing for ten requests running ends the view with a reason.
    private func servePreviewRequest() {
        guard !previewRequestInFlight, let sequence = pendingPreviewSequence,
              let subscription = previewSubscription, case .connected(let peer, _) = link else { return }
        pendingPreviewSequence = nil
        let thermal = thermalState()
        if thermal == .critical {
            endPreview(reason: "Live view stopped to keep the camera cool.", notify: true)
            return
        }
        if activeSendID != nil {
            sendPreviewPacket(.skipped(subscription: subscription.id, sequence: sequence, reason: .transferring), to: peer)
            return
        }
        if thermal == .serious {
            sendPreviewPacket(.skipped(subscription: subscription.id, sequence: sequence, reason: .thermal), to: peer)
            return
        }
        let maxEdge = thermal == .fair ? min(subscription.maxEdge, PreviewLimits.degradedEdge) : subscription.maxEdge
        previewRequestInFlight = true
        Task { [weak self, device] in
            // A frame the device never delivers must not wedge the loop: give it a deadline and move on.
            let frame = await FirstResult.of(timeout: .seconds(3)) {
                await device.previewFrame(maxEdge: maxEdge, maxBytes: subscription.maxBytes)
            } ?? nil
            guard let self else { return }
            self.previewRequestInFlight = false
            guard self.previewSubscription?.id == subscription.id, case .connected(let peer, _) = self.link else { return }
            if let frame {
                self.previewMisses = 0
                self.previewFramesSent += 1
                self.sendPreviewPacket(.frame(subscription: subscription.id, sequence: sequence,
                                              width: UInt16(clamping: frame.width), height: UInt16(clamping: frame.height),
                                              jpeg: frame.jpeg), to: peer)
            } else {
                self.previewMisses += 1
                if self.previewMisses >= Self.maxPreviewMisses {
                    self.endPreview(reason: "Live view isn't available in this camera mode.", notify: true)
                    return
                }
                self.sendPreviewPacket(.skipped(subscription: subscription.id, sequence: sequence, reason: .noFrame), to: peer)
            }
            self.servePreviewRequest()   // a newer request may have arrived meanwhile
        }
    }

    private static let maxPreviewMisses = 10

    private func sendPreviewPacket(_ packet: PreviewPacket, to peer: Peer) {
        do {
            try transport.sendPreview(packet.encoded(), to: peer)
        } catch {
            // The fast lane is gone; its `.fileChannelFast(false)` ends the subscription properly.
            Trace.log("camera: live view packet not sent: \(error)")
        }
    }

    private func handlePairing(_ submission: PairingSubmission) async {
        guard case .connected(let peer, _) = link, !isPaired else { return }
        guard submission.protocolVersion == WireProtocol.version else {
            send(.rejected(reason: "The other device is running a different version of the app. Update both."))
            expectsDisconnect = true
            transport.disconnect()
            return
        }
        switch Pairing.verify(context: submission.proof, code: pairingCode, challenge: currentChallenge) {
        case .accepted:
            isPaired = true
            failedAttempts = 0
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            link = .connected(peer, HelloInfo(protocolVersion: submission.protocolVersion,
                                              appVersion: submission.appVersion,
                                              displayName: submission.displayName))
            send(.hello(HelloInfo(appVersion: appVersion, displayName: transport.localPeer.displayName, capabilities: capabilities)))
            broadcastState()
        case .rejected:
            failedAttempts += 1
            let rotate = failedAttempts >= Self.maxFailedAttempts
            send(.rejected(reason: "The code didn't match. Check the code on the camera and try again."))
            if rotate {
                pairingCode = .random()
                failedAttempts = 0
                show("Too many wrong codes. A new code has been issued.")
            }
            expectsDisconnect = true
            transport.disconnect()
        }
    }

    private func startPairingTimeout() {
        // Real time on purpose: a safety net that frees the single connection slot if a peer connects
        // but never completes pairing. It must not use the injectable countdown clock.
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled, !self.isPaired, self.link.isConnected else { return }
            self.expectsDisconnect = true
            self.transport.disconnect()
        }
    }

    private func startCapture(_ work: @escaping @MainActor () async -> Void) {
        guard captureTask == nil else { return }
        captureTask = Task { [weak self] in
            await work()
            self?.captureTask = nil
        }
    }

    private func update(_ change: @escaping @MainActor (inout CameraState) -> Void) async {
        let previous = settingsUpdateTask
        let task = Task { [self] in
            await previous?.value
            guard isActive else { return }
            isUpdatingSettings = true
            defer { isUpdatingSettings = false }
            var next = state
            change(&next)
            let settings = CameraSettings(mode: next.mode, position: next.position, flash: next.flash)
            do {
                try await device.apply(settings)
                state.mode = next.mode
                state.position = next.position
                state.flash = next.flash
                broadcastState()
            } catch {
                show(Self.describe(error))
            }
        }
        settingsUpdateTask = task
        await task.value
    }

    // MARK: Capturing

    /// Returns false when the countdown was cancelled.
    private func runCountdown(_ seconds: Int) async -> Bool {
        guard !Task.isCancelled, isActive else { return false }
        let seconds = min(max(seconds, 0), 10)
        guard seconds > 0 else { return true }
        for remaining in stride(from: seconds, through: 1, by: -1) {
            state.countdown = remaining
            broadcastState()
            do {
                if let sleep {
                    try await sleep(.seconds(1))
                } else {
                    try await Task.sleep(for: .seconds(1))
                }
            } catch {
                state.countdown = nil
                broadcastState()
                return false
            }
        }
        state.countdown = nil
        broadcastState()
        return !Task.isCancelled && isActive
    }

    private func capturePhoto(sendBack: Bool, delay: Int) async {
        guard availability == .ready, !isUpdatingSettings, !state.isBusy, !state.isRecording, state.countdown == nil else { return }
        guard await runCountdown(delay) else { return }
        state.isBusy = true
        broadcastState()
        defer {
            state.isBusy = false
            broadcastState()
        }
        do {
            let photo = try await device.capturePhoto()
            let name = "IMG_\(Self.stamp()).\(photo.fileExtension)"
            var result = CaptureResult(kind: .photo, byteCount: photo.data.count, willSendFile: false,
                                       fileName: name, savedOnCamera: false)
            if keepsCopies {
                do {
                    try await mediaStore.savePhoto(data: photo.data, fileExtension: photo.fileExtension)
                    result.savedOnCamera = true
                } catch {
                    let url = try writeOutgoing(photo.data, name: TransferName.make(id: result.id, ext: photo.fileExtension))
                    unsavedFiles[result.id] = HeldFile(url: url, kind: .photo, photoData: photo.data)
                    unsavedCaptureCount = unsavedFiles.count
                    show("Photo taken, but not saved to Photos. \(Self.describe(error))")
                }
            }
            if sendBack, transport.supportsFileTransfer, isPaired, case .connected = link {
                let url = try writeOutgoing(photo.data, name: TransferName.make(id: result.id, ext: photo.fileExtension))
                heldFiles[result.id] = HeldFile(url: url, kind: .photo, photoData: photo.data)
                result.fileAvailable = fileChannelFast == false
                result.willSendFile = !result.fileAvailable
                if result.fileAvailable { pendingCaptureIDs.insert(result.id) }
            }
            result.thumbnailJPEG = await thumbnails.thumbnail(forPhoto: photo.data)
            Trace.log("camera: photo \(result.id) \(photo.data.count) B — sendBack=\(sendBack) fast=\(String(describing: fileChannelFast)) willSend=\(result.willSendFile) deferred=\(result.fileAvailable)")
            captures.append(result)
            // Publish the result before starting the transfer, whose completion can arrive immediately.
            send(.captureFinished(result))
            if result.willSendFile { queueHeldFile(id: result.id) }
        } catch {
            let reason = "Couldn't take the photo. \(Self.describe(error))"
            show(reason)
            send(.captureFailed(reason: reason))
        }
    }

    private func startRecording(sendBack: Bool, delay: Int) async {
        guard availability == .ready, capabilities.canRecordVideo, state.mode == .video,
              !isUpdatingSettings, !state.isRecording, !state.isBusy, state.countdown == nil else { return }
        guard await runCountdown(delay) else { return }
        state.isBusy = true
        broadcastState()
        defer {
            state.isBusy = false
            broadcastState()
        }
        do {
            try await device.startRecording()
            pendingVideoSendBack = sendBack
            state.isRecording = true
            state.recordingDuration = 0
            broadcastState()
            startTicker()
            if await device.isRecordingWithoutSound() {
                show("Recording without sound. Allow Microphone in Settings to add audio.")
            }
        } catch {
            let reason = "Couldn't start recording. \(Self.describe(error))"
            show(reason)
            send(.captureFailed(reason: reason))
        }
    }

    private func startTicker() {
        recordingTicker?.cancel()
        recordingTicker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Recording progress uses a real clock, independent of the injectable shutter timer.
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                guard !Task.isCancelled, self.state.isRecording else { return }
                if await self.device.recordingHasFinished() {
                    self.startCapture { await self.stopRecording() }
                    return
                }
                let duration = await self.device.recordingDuration()
                let secondChanged = Int(duration) != Int(self.state.recordingDuration)
                self.state.recordingDuration = duration
                if secondChanged { self.broadcastState() }
            }
        }
    }

    private func stopRecording() async {
        guard state.isRecording, !state.isBusy else { return }
        state.isBusy = true
        broadcastState()
        let ticker = recordingTicker
        ticker?.cancel()
        await ticker?.value
        recordingTicker = nil
        defer {
            state.isBusy = false
            broadcastState()
        }
        do {
            let movie = try await device.stopRecording()
            state.isRecording = false
            state.recordingDuration = 0
            broadcastState()
            let name = "VID_\(Self.stamp()).\(movie.url.pathExtension.isEmpty ? "mov" : movie.url.pathExtension)"
            let size = (try? FileManager.default.attributesOfItem(atPath: movie.url.path)[.size] as? Int) ?? 0
            var result = CaptureResult(kind: .video, byteCount: size, willSendFile: false,
                                       fileName: name, duration: movie.duration, savedOnCamera: false)
            let file = HeldFile(url: movie.url, kind: .video, photoData: nil)
            if keepsCopies {
                do {
                    try await mediaStore.saveVideo(fileURL: movie.url)
                    result.savedOnCamera = true
                } catch {
                    unsavedFiles[result.id] = file
                    unsavedCaptureCount = unsavedFiles.count
                    show("Video recorded, but not saved to Photos. \(Self.describe(error))")
                }
            }
            if pendingVideoSendBack, transport.supportsFileTransfer, isPaired, case .connected = link {
                heldFiles[result.id] = file
                result.fileAvailable = fileChannelFast == false
                result.willSendFile = !result.fileAvailable
                if result.fileAvailable { pendingCaptureIDs.insert(result.id) }
            }
            result.thumbnailJPEG = await thumbnails.thumbnail(forVideoAt: movie.url)
            Trace.log("camera: video \(result.id) \(size) B \(Int(movie.duration)) s — sendBack=\(pendingVideoSendBack) fast=\(String(describing: fileChannelFast)) willSend=\(result.willSendFile) deferred=\(result.fileAvailable) savedOnCamera=\(result.savedOnCamera == true)")
            if heldFiles[result.id] == nil, unsavedFiles[result.id] == nil {
                try? FileManager.default.removeItem(at: movie.url)
            }
            captures.append(result)
            send(.captureFinished(result))
            if result.willSendFile { queueHeldFile(id: result.id) }
        } catch {
            Trace.log("camera: video failed — \(Self.describe(error))")
            state.isRecording = false
            state.recordingDuration = 0
            let reason = "Couldn't finish the video. \(Self.describe(error))"
            show(reason)
            send(.captureFailed(reason: reason))
        }
    }

    // MARK: Transport events

    private func handle(_ event: TransportEvent) {
        switch event {
        case .invitation(let peer, _, let respond):
            // Accept one remote at a time; the code is verified over the data channel after
            // connecting (reliable over Bluetooth, unlike discovery info and the invitation context).
            guard isActive, availability == .ready, case .none = link else {
                respond(false)
                return
            }
            link = .connecting(peer)
            respond(true)
        case .connecting(let peer):
            if case .none = link { link = .connecting(peer) }
        case .connected(let peer):
            guard isActive else { return }
            expectsDisconnect = false
            guard link.peer == nil || link.peer?.id == peer.id else { return }
            link = .connected(peer, nil)
            isPaired = false
            transport.stopAdvertising()
            if transport.requiresAppLevelPairing {
                currentChallenge = .random()
                send(.challenge(currentChallenge.nonce))
                startPairingTimeout()
            } else {
                // Wi-Fi Aware: the OS already paired the two devices, so accept immediately.
                isPaired = true
                Trace.log("camera: connected to \(peer.displayName) — sending hello")
                send(.hello(HelloInfo(appVersion: appVersion, displayName: transport.localPeer.displayName, capabilities: capabilities)))
                broadcastState()
                Trace.log("camera: hello + state sent")
            }
        case .disconnected(let peer):
            guard link.peer?.id == peer.id else { return }
            let wasPaired = isPaired
            isPaired = false
            remoteSendBack = SendBackPreferences()
            endPreview(reason: nil, notify: false)
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            link = .none
            fileChannelFast = nil
            discardHeldFiles()
            if state.countdown != nil { captureTask?.cancel() }
            if isActive, availability == .ready { advertise() }
            if expectsDisconnect {
                expectsDisconnect = false
            } else if wasPaired {
                show("The remote disconnected.")
            }
        case .message(let data, let peer):
            guard link.peer?.id == peer.id else { return }
            handleMessage(data)
        case .fileSendProgress(let name, let fraction):
            outgoingTransfer = TransferStatus(name: name, fraction: fraction, phase: .sending)
        case .fileSendFinished(let name, let error):
            let completedID = TransferName.parse(name)?.id
            let wasCanceled = completedID != nil && cancelingSendID == completedID
            if activeSendID == completedID {
                activeSendID = nil
                activeSendToken = nil
                activeSendHasStarted = false
                cancelingSendID = nil
                sendNextHeldFile()
            }
            // Keep the held file (and any transient compressed copy) so a capture can be re-downloaded
            // — e.g. after the remote cancels. Everything is wiped on disconnect.
            // A cancel the remote asked for isn't a failure worth a banner on the camera.
            outgoingTransfer = wasCanceled ? nil
                : TransferStatus(name: name, fraction: 1, phase: error.map { .failed($0) } ?? .sent)
            // If an automatic Wi-Fi send failed (the fast lane dropped mid-transfer), re-offer the
            // capture as a Bluetooth download instead of stranding it: flip it to "available" and tell
            // the remote so a download button appears; it also flushes if a Wi-Fi lane returns.
            if error != nil, let (id, _) = TransferName.parse(name), heldFiles[id] != nil,
               let index = captures.firstIndex(where: { $0.id == id }), captures[index].willSendFile {
                captures[index].willSendFile = false
                captures[index].fileAvailable = true
                pendingCaptureIDs.insert(id)
                send(.captureFinished(captures[index]))
            }
        case .fileChannelFast(let fast):
            fileChannelFast = fast
            if fast {
                flushHeldFiles()
            } else {
                endPreview(reason: PreviewLimits.needsWiFiMessage, notify: true)
            }
        case .preview(let data, let peer):
            guard link.peer?.id == peer.id, isPaired else { return }
            handlePreviewPacket(data)
        case .failure(let message):
            show(message)
        case .peerFound, .peerLost, .fileReceiveStarted, .fileReceiveProgress, .fileReceived, .fileReceiveFailed:
            break
        }
    }

    private func handleMessage(_ data: Data) {
        do {
            guard case .command(let command) = try codec.decode(data) else { return }
            // Local controls work before pairing; commands received from a peer never do.
            let peerID = link.peer?.id
            if case .pair = command {
                Task { await execute(command) }
            } else {
                guard isPaired else { return }
                Task {
                    guard self.isPaired, self.link.peer?.id == peerID else { return }
                    await execute(command)
                }
            }
        } catch MessageCodecError.unsupportedVersion {
            send(.rejected(reason: "The remote is running a different version of the app."))
            show("The remote is running a different version of the app. Update both devices.")
            expectsDisconnect = true
            transport.disconnect()
        } catch {
            // Ignore anything we don't understand.
        }
    }

    // MARK: Helpers

    private func advertise() {
        transport.startAdvertising(discoveryInfo: Pairing.advertisingInfo())
    }

    private func send(_ event: CameraEvent) {
        guard case .connected(let peer, _) = link else { return }
        try? transport.send(try codec.encode(.event(event)), to: [peer])
    }

    private func broadcastState() {
        send(.state(state))
    }

    private func show(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func writeOutgoing(_ data: Data, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: outboxDirectory, withIntermediateDirectories: true)
        let url = outboxDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func queueHeldFile(id: UUID, quality: TransferQuality = .full, allowSlow: Bool = false) {
        guard heldFiles[id] != nil, activeSendID != id || cancelingSendID == id,
              !sendQueue.contains(where: { $0.id == id }) else { return }
        pendingCaptureIDs.remove(id)
        sendQueue.append((id, quality, allowSlow))
        sendNextHeldFile()
    }

    private func sendNextHeldFile() {
        guard activeSendID == nil, !sendQueue.isEmpty, isPaired, case .connected = link else {
            if !sendQueue.isEmpty { Trace.log("camera: \(sendQueue.count) file(s) queued behind active=\(String(describing: activeSendID)) paired=\(isPaired)") }
            return
        }
        let request = sendQueue.removeFirst()
        if !request.allowSlow, fileChannelFast == false {
            pendingCaptureIDs.insert(request.id)
            if let index = captures.firstIndex(where: { $0.id == request.id }) {
                captures[index].willSendFile = false
                captures[index].fileAvailable = true
                send(.captureFinished(captures[index]))
            }
            sendNextHeldFile()
            return
        }
        activeSendID = request.id
        let token = UUID()
        activeSendToken = token
        activeSendHasStarted = false
        Task { await sendHeldFile(id: request.id, quality: request.quality, token: token) }
    }

    /// Compressed copies never replace the held original. Recheck the connection after encoding.
    private func sendHeldFile(id: UUID, quality: TransferQuality, token: UUID) async {
        guard case .connected(let peer, _) = link, let held = heldFiles[id], activeSendToken == token else { return }
        var url = held.url
        if quality != .full, held.kind == .photo, let photoData = held.photoData,
           let compressed = await thumbnails.compressedPhoto(data: photoData, quality: quality) {
            guard link.peer?.id == peer.id, isPaired, heldFiles[id] != nil, activeSendToken == token else { return }
            if let compressedURL = try? writeOutgoing(compressed, name: "\(id.uuidString)-compressed.jpg") {
                url = compressedURL
                compressedFiles.append(compressedURL)
            }
        }
        guard link.peer?.id == peer.id, isPaired, heldFiles[id] != nil, activeSendToken == token else { return }
        let ext = url.pathExtension.isEmpty ? (held.kind == .video ? "mov" : "dat") : url.pathExtension
        let name = TransferName.make(id: id, ext: ext)
        outgoingTransfer = TransferStatus(name: name, fraction: 0, phase: .sending)
        activeSendHasStarted = true
        transport.sendFile(at: url, named: name, to: peer)
    }

    private func flushHeldFiles() {
        // Preserve capture order and feed one file at a time into transports with a single send slot.
        for capture in captures where pendingCaptureIDs.contains(capture.id) {
            queueHeldFile(id: capture.id)
        }
    }

    private func cancelHeldSend(id: UUID) {
        sendQueue.removeAll { $0.id == id }
        if activeSendID == id {
            outgoingTransfer = nil
            if activeSendHasStarted {
                // The transport frees its send slot asynchronously; wait for its finish event.
                cancelingSendID = id
                transport.cancelFileSend()
            } else {
                activeSendID = nil
                activeSendToken = nil
                sendNextHeldFile()
            }
        }
        if heldFiles[id] != nil { pendingCaptureIDs.insert(id) }
    }

    private func discardHeldFiles() {
        // A dropped link or a trip to Settings must not destroy the only copy of an unsent shot.
        // Retain it for an explicit Photos retry while this camera screen stays open.
        for capture in captures where pendingTransferIDs.contains(capture.id) && capture.savedOnCamera != true {
            if let file = heldFiles[capture.id] { unsavedFiles[capture.id] = file }
        }
        unsavedCaptureCount = unsavedFiles.count
        for (id, file) in heldFiles where unsavedFiles[id] == nil {
            try? FileManager.default.removeItem(at: file.url)
        }
        for url in compressedFiles { try? FileManager.default.removeItem(at: url) }
        compressedFiles.removeAll()
        heldFiles.removeAll()
        pendingCaptureIDs.removeAll()
        sendQueue.removeAll()
        activeSendID = nil
        activeSendToken = nil
        activeSendHasStarted = false
        cancelingSendID = nil
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return formatter.string(from: Date())
    }

    static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
