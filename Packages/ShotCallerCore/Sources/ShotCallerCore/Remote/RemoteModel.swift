import Foundation
import Observation

/// Everything the remote screen shows and does. Pure logic: it talks to the camera through a
/// `PeerTransport` and saves files through a `MediaStore`, so it runs unchanged in tests.
@MainActor
@Observable
public final class RemoteModel {
    public enum Connection: Hashable, Sendable {
        case idle
        case browsing
        case connecting(Peer)
        case connected(Peer)

        public var peer: Peer? {
            switch self {
            case .connecting(let peer), .connected(let peer): peer
            case .idle, .browsing: nil
            }
        }

        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    /// What the live-view stage should show. `off` is the resting state (not wanted, not connected,
    /// or not supported); `unavailable` carries the words for why a wanted live view isn't running.
    public enum PreviewStatus: Hashable, Sendable {
        case off
        case unavailable(String)
        case starting
        case live
        /// No fresh frame for a while; the last one may still be showing, dimmed.
        case stalled
        /// The camera is skipping frames on purpose (a download, heat); carries the words.
        case paused(String)
    }

    public private(set) var connection: Connection = .idle
    /// Compatible cameras in range, most recently seen last.
    public private(set) var cameras: [Peer] = []
    public private(set) var camera: HelloInfo?
    public private(set) var cameraState: CameraState?
    public private(set) var captures: [CaptureResult] = []
    public private(set) var transfer: TransferStatus?
    /// A short, transient message for the person holding the remote.
    public private(set) var notice: String?
    public var unsavedCaptureCount: Int { unsavedFiles.count }
    private struct UnsavedFile { let name: String; let url: URL; let captureID: UUID? }
    private var unsavedFiles: [URL: UnsavedFile] = [:]
    @ObservationIgnored private var savingFiles: Set<URL> = []
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var connectionTimeoutTask: Task<Void, Never>?
    /// The current file-transfer channel while connected: false = Bluetooth only, true = Bluetooth + a
    /// fast Wi-Fi lane. nil when the transport is single-channel (Wi-Fi Aware) or not connected.
    public private(set) var fileChannelFast: Bool?
    /// Live view. `wantsPreview` is the person's setting; `previewDemand` is whether anyone could be
    /// looking (the scene is active). Frames flow only while both hold and the Wi-Fi lane is up.
    public private(set) var preview: PreviewStatus = .off
    public private(set) var previewFrame: PreviewFrame?
    public private(set) var wantsPreview = true
    @ObservationIgnored private var previewDemand = true
    @ObservationIgnored private var previewSubscription: PreviewSubscription?
    /// The start request awaiting its `previewStarted` / `previewRefused`; answers to any other are ignored.
    @ObservationIgnored private var pendingPreviewRequestID: UUID?
    @ObservationIgnored private var previewSequence: UInt32 = 0
    @ObservationIgnored private var previewRequestSentAt: Date?
    @ObservationIgnored private var previewRequestTask: Task<Void, Never>?
    @ObservationIgnored private var previewWatchdog: Task<Void, Never>?
    /// How old the picture (measured from its request) may be before the stage says it is stalled;
    /// three seconds beyond that it is taken down.
    public var previewTimeout: TimeInterval = 2
    /// Captures whose full-resolution file has arrived and been saved here.
    private var downloadedCaptureIDs: Set<UUID> = []
    /// The capture whose file is transferring right now (auto over Wi-Fi, or a Bluetooth download).
    private var downloadingCaptureID: UUID?
    /// Fails a download that makes no progress for a while, so a stalled transfer can't permanently
    /// block the one-at-a-time download slot. Re-armed on every progress update.
    @ObservationIgnored private var downloadWatchdog: Task<Void, Never>?

    public var timerSeconds = 0
    public var sendBackPhotos = true { didSet { if sendBackPhotos != oldValue { sendPreferences() } } }
    public var sendBackVideos = false { didSet { if sendBackVideos != oldValue { sendPreferences() } } }
    /// How long one connection attempt may take. nil picks the transport's default: 30 s on the
    /// Bluetooth path (verified on hardware), 10 s on Wi-Fi Aware, where a good attempt takes ~3 s and
    /// a stalled one should give way to a fresh browse. Tests shorten it.
    public var connectTimeout: TimeInterval?
    /// A reconnect attempt is shorter: a connect to a camera that is away stays pending and completes
    /// the moment it advertises again, so the timer only has to catch a dead attempt.
    private var effectiveConnectTimeout: TimeInterval {
        connectTimeout ?? (isReconnecting ? 15 : (requiresCode ? 30 : 10))
    }
    /// Automatic reconnect tries before the person is told: with 15 s attempts, eight covers about two
    /// minutes of the camera being away. Tests shorten it.
    public var reconnectAttemptLimit = 8
    private var reconnectBudget: Int { requiresCode ? reconnectAttemptLimit : 5 }

    public var lastCapture: CaptureResult? { captures.last }
    public var localName: String { transport.localPeer.displayName }
    /// Whether the user must enter the camera's 4-digit code (Multipeer). Wi-Fi Aware pairs at the
    /// system level, so no code is needed and the remote connects directly.
    public var requiresCode: Bool { transport.requiresAppLevelPairing }

    @ObservationIgnored private let transport: any PeerTransport
    @ObservationIgnored private let mediaStore: any MediaStore
    @ObservationIgnored private let codec = MessageCodec()
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var expectsDisconnect = false
    @ObservationIgnored private var pendingCode: PairingCode?
    @ObservationIgnored private var didReceiveChallenge = false
    @ObservationIgnored private var reconnectName: String?
    /// The camera's peer id, matched first (names can repeat or change); the name is the fallback for
    /// transports whose ids are not stable across sessions.
    @ObservationIgnored private var reconnectID: String?
    @ObservationIgnored private var reconnectAttemptsLeft = 0
    /// A timed-out attempt's peer: its late `.disconnected` triggers the next try instead of being
    /// mistaken for a fresh failure; a fallback timer covers transports that never send it
    /// (`BluetoothTransport` tears a pending invite down without notifying; `WiFiAwareTransport`
    /// yields the event synchronously). Events carry no attempt identity, so a `.disconnected` that
    /// arrived later than the fallback would count against the replacement attempt; neither shipped
    /// transport does that.
    @ObservationIgnored private var staleAttemptPeerID: String?
    @ObservationIgnored private var retryFallbackTask: Task<Void, Never>?
    public private(set) var isReconnecting = false

    public init(transport: any PeerTransport, mediaStore: any MediaStore, appVersion: String) {
        self.transport = transport
        self.mediaStore = mediaStore
        self.appVersion = appVersion
    }

    // MARK: Lifecycle

    public func start() {
        guard eventTask == nil else { return }
        isStopped = false
        connection = .browsing
        transport.startBrowsing()
        eventTask = Task { [weak self, transport] in
            for await event in transport.events {
                guard let self, !Task.isCancelled else { return }
                self.handle(event)
            }
        }
    }

    /// Leaving the foreground drops the link. Remember a paired camera (and the code it accepted)
    /// so `resume()` reconnects by itself instead of making the person pair again after a glance
    /// at another app.
    public func suspend() {
        let pairedCamera = connection.isConnected ? connection.peer : nil
        let code = pendingCode
        disconnect()
        transport.stopBrowsing()
        connection = .idle
        cameras = []
        if let pairedCamera, !isStopped {
            reconnectName = pairedCamera.displayName
            reconnectID = pairedCamera.id
            pendingCode = code
            reconnectAttemptsLeft = reconnectBudget
            isReconnecting = true
        }
    }

    public func resume() {
        guard connection == .idle else { return }
        if eventTask == nil {
            start()
        } else {
            connection = .browsing
            transport.startBrowsing()
        }
    }

    public func stop() {
        isStopped = true
        suspend()
        eventTask?.cancel()
        eventTask = nil
        noticeTask?.cancel()
        for file in unsavedFiles.values where !savingFiles.contains(file.url) {
            try? FileManager.default.removeItem(at: file.url)
        }
        unsavedFiles.removeAll()
    }

    public func retrySavingCaptures() async {
        for file in unsavedFiles.values {
            await save(name: file.name, from: file.url, captureID: file.captureID)
        }
    }

    // MARK: Connecting

    public func connect(to peer: Peer, code: PairingCode? = nil) {
        // A deliberate connection cancels any in-progress auto-reconnect to a previous camera.
        isReconnecting = false
        reconnectName = nil
        reconnectID = nil
        reconnectAttemptsLeft = 0
        clearStaleAttempt()
        invite(peer, code: code)
    }

    private func invite(_ peer: Peer, code: PairingCode?) {
        pendingCode = code
        didReceiveChallenge = false
        connection = .connecting(peer)
        connectionTimeoutTask?.cancel()
        let timeout = effectiveConnectTimeout
        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled, self.connection == .connecting(peer) else { return }
            self.connectionTimedOut()
        }
        // The code is proved over the data channel once connected; no secret in the invitation, and a
        // longer timeout because peer-to-peer Wi-Fi can be slow to establish.
        transport.invite(peer, context: nil, timeout: timeout)
    }

    /// A timed-out attempt during an automatic reconnect is one failed try, not the end of the
    /// reconnect: the camera often re-advertises a moment after its link dropped. A deliberate
    /// connection that times out is reported.
    private func connectionTimedOut() {
        if isReconnecting, let peer = connection.peer {
            // Reset locally first, then cancel the attempt. The transport's `.disconnected` for it
            // arrives later and starts the next try (see handle(.disconnected)); if the transport
            // never sends one, the fallback timer does.
            connection = .browsing
            camera = nil
            cameraState = nil
            didReceiveChallenge = false
            staleAttemptPeerID = peer.id
            retryFallbackTask?.cancel()
            retryFallbackTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.staleAttemptPeerID == peer.id else { return }
                self.staleAttemptPeerID = nil
                self.attemptReconnect()
            }
            transport.disconnect()
        } else {
            disconnect()
            show(requiresCode
                ? "Couldn't connect. Keep both devices nearby with Bluetooth on, then try again."
                : "Couldn't connect. Keep Wi-Fi on and Shot Caller open on both devices, then try again.")
        }
    }

    private func attemptReconnect() {
        // A timed-out attempt is still being torn down: its `.disconnected` (or the fallback timer)
        // starts the next try, so a rediscovery in between must not open a second attempt.
        guard isReconnecting, staleAttemptPeerID == nil, let name = reconnectName, case .browsing = connection else { return }
        guard reconnectAttemptsLeft > 0 else {
            isReconnecting = false
            reconnectName = nil
            reconnectID = nil
            show("The camera disconnected.")
            return
        }
        guard let peer = rememberedCamera(id: reconnectID, name: name) else {
            // Wait for the camera to be rediscovered (handled in .peerFound). This wait is not
            // bounded: the budget limits invitations, not elapsed time.
            return
        }
        reconnectAttemptsLeft -= 1
        invite(peer, code: pendingCode)
    }

    /// Bluetooth and Wi-Fi Aware peer ids are stable for a device, so a known id is the only match
    /// (two cameras can share a name). The name is used only when no id was recorded.
    private func rememberedCamera(id: String?, name: String) -> Peer? {
        if let id { return cameras.first(where: { $0.id == id }) }
        return cameras.first(where: { $0.displayName == name })
    }

    private func isRememberedCamera(_ peer: Peer) -> Bool {
        if let reconnectID { return peer.id == reconnectID }
        return peer.displayName == reconnectName
    }

    private func clearStaleAttempt() {
        staleAttemptPeerID = nil
        retryFallbackTask?.cancel()
        retryFallbackTask = nil
    }

    public func disconnect() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        endDownloadWatchdog()
        clearPreview(status: .off)
        pendingCode = nil
        reconnectName = nil
        reconnectID = nil
        reconnectAttemptsLeft = 0
        isReconnecting = false
        clearStaleAttempt()
        didReceiveChallenge = false
        camera = nil
        cameraState = nil
        fileChannelFast = nil
        downloadingCaptureID = nil
        transfer = nil
        invalidateAvailableFiles()
        // Some transports emit no disconnected event while an invitation is still pending.
        // Reset locally before canceling, so the old callback cannot restore a stale connection.
        connection = .browsing
        transport.disconnect()
    }

    private func invalidateAvailableFiles() {
        for index in captures.indices {
            captures[index].fileAvailable = false
            captures[index].willSendFile = false
        }
    }

    /// Nudge discovery, e.g. right after a Wi-Fi Aware pairing completes.
    public func restartBrowsing() {
        transport.stopBrowsing()
        transport.startBrowsing()
    }

    // MARK: Controls

    /// The one big button: takes a photo, or starts/stops recording, or cancels a running countdown.
    public func shutter() {
        guard connection.isConnected, let state = cameraState else { return }
        if state.countdown != nil {
            send(.cancelCountdown)
            return
        }
        switch state.mode {
        case .photo:
            guard !state.isBusy, !isReceivingFile else { return }
            send(.capturePhoto(sendBack: sendBackPhotos, delay: timerSeconds))
        case .video:
            if state.isRecording {
                send(.stopRecording)
            } else if !state.isBusy, !isReceivingFile {
                send(.startRecording(sendBack: sendBackVideos, delay: timerSeconds))
            }
        }
    }

    public func setMode(_ mode: CaptureMode) {
        guard cameraState?.mode != mode else { return }
        send(.setMode(mode))
    }

    public func cycleFlash() {
        guard let flash = cameraState?.flash else { return }
        send(.setFlash(flash.next))
    }

    public func flipCamera() {
        guard let position = cameraState?.position else { return }
        send(.setPosition(position.toggled))
    }

    public func cancelCountdown() {
        send(.cancelCountdown)
    }

    public func dismissNotice() {
        notice = nil
    }

    /// The camera applies these to shots taken with its own shutter.
    private func sendPreferences() {
        guard connection.isConnected else { return }
        send(.setSendBack(SendBackPreferences(photos: sendBackPhotos, videos: sendBackVideos)))
    }

    // MARK: Live view

    /// The person's choice (persisted by the app). Turning it off stops the camera's frame tap too.
    public func setPreviewEnabled(_ enabled: Bool) {
        guard wantsPreview != enabled else { return }
        wantsPreview = enabled
        reconcilePreview()
    }

    /// Whether anyone could be looking: false while the scene is inactive (app switcher, a system
    /// sheet) so no frame is fetched or kept on screen; true again when it is active.
    public func setPreviewDemand(_ active: Bool) {
        guard previewDemand != active else { return }
        previewDemand = active
        if !active { previewFrame = nil }
        reconcilePreview()
    }

    /// Starts or stops the live view so that it matches intent, demand and what the link allows.
    private func reconcilePreview() {
        let wanted = wantsPreview && previewDemand
        guard wanted else {
            if let subscription = previewSubscription { send(.stopPreview(id: subscription.id)) }
            clearPreview(status: .off)
            return
        }
        guard previewSubscription == nil, pendingPreviewRequestID == nil else { return }
        guard connection.isConnected, let camera, transport.supportsPreviewChannel else {
            preview = .off
            return
        }
        guard camera.capabilities?.canStreamPreview == true else {
            preview = .unavailable("This camera can't share a live view.")
            return
        }
        guard fileChannelFast == true else {
            preview = .unavailable(PreviewLimits.needsWiFiMessage)
            return
        }
        let request = PreviewRequest()
        pendingPreviewRequestID = request.requestID
        preview = .starting
        send(.startPreview(request))
    }

    private func clearPreview(status: PreviewStatus) {
        previewSubscription = nil
        pendingPreviewRequestID = nil
        previewRequestTask?.cancel()
        previewRequestTask = nil
        previewWatchdog?.cancel()
        previewWatchdog = nil
        previewRequestSentAt = nil
        previewFrame = nil
        preview = status
    }

    private func requestNextFrame(after delay: TimeInterval) {
        previewRequestTask?.cancel()
        previewRequestTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, !Task.isCancelled else { return }
            self.sendFrameRequest()
        }
    }

    /// Exactly one request in flight. It is never reissued on a timeout: the camera answers every
    /// request it accepts (a frame or a skip), reliable delivery does not lose packets, and a lane that
    /// dies reports `.fileChannelFast(false)`. Reissuing would only stack JPEGs behind a stalled lane.
    /// The watchdog marks the picture stalled meanwhile.
    private func sendFrameRequest() {
        guard let subscription = previewSubscription, let peer = connection.peer else { return }
        previewSequence &+= 1
        let sequence = previewSequence
        previewRequestSentAt = Date()
        do {
            try transport.sendPreview(PreviewPacket.frameRequest(subscription: subscription.id, sequence: sequence).encoded(), to: peer)
        } catch {
            // The lane is down; `.fileChannelFast(false)` will follow and explain.
        }
    }

    /// Independent of the request loop: judges the picture by its age (measured from the request that
    /// produced it, not from receipt), so repeated skips cannot keep a stale frame looking live.
    private func startPreviewWatchdog() {
        previewWatchdog?.cancel()
        previewWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled, let subscription = self.previewSubscription else { return }
                let timeout = self.previewTimeout
                let age = Date().timeIntervalSince(self.previewFrame?.timestamp ?? self.previewRequestSentAt ?? Date())
                if age > timeout + 3, self.previewFrame != nil {
                    self.previewFrame = nil   // too old to frame from
                }
                if age > timeout {
                    switch self.preview {
                    case .live, .starting: self.preview = .stalled
                    case .stalled, .paused, .off, .unavailable: break
                    }
                }
                _ = subscription
            }
        }
    }

    private func handlePreviewPacket(_ data: Data) {
        guard let subscription = previewSubscription, let packet = try? PreviewPacket.decode(data),
              packet.subscription == subscription.id, packet.sequence == previewSequence else { return }   // stale or foreign
        switch packet {
        case .frame(_, _, let width, let height, let jpeg):
            let requestedAt = previewRequestSentAt ?? Date()
            guard Self.isAcceptableFrame(jpeg, width: Int(width), height: Int(height), terms: subscription) else {
                requestNextFrame(after: 0.3)   // a frame outside the terms is a skip, not a picture
                return
            }
            previewFrame = PreviewFrame(jpeg: jpeg, width: Int(width), height: Int(height), timestamp: requestedAt)
            preview = .live
            let elapsed = Date().timeIntervalSince(requestedAt)
            requestNextFrame(after: max(0, 1.0 / Double(max(subscription.fps, 1)) - elapsed))
        case .skipped(_, _, let reason):
            switch reason {
            case .transferring:
                preview = .paused("Live view paused while downloading.")
                requestNextFrame(after: 1)
            case .thermal:
                preview = .paused("Live view paused to keep the camera cool.")
                requestNextFrame(after: 1)
            case .noFrame:
                // Mid-capture or a brief interruption: keep what is showing (the watchdog ages it) and
                // ask again soon.
                if previewFrame == nil, preview == .live { preview = .starting }
                requestNextFrame(after: 0.3)
            }
        case .frameRequest:
            break   // only cameras receive these
        }
    }

    /// A frame must honour the negotiated terms and at least look like a JPEG (SOI … EOI) before it is
    /// published; the app decodes it off the main actor.
    static func isAcceptableFrame(_ jpeg: Data, width: Int, height: Int, terms: PreviewSubscription) -> Bool {
        guard jpeg.count <= terms.maxBytes, jpeg.count >= 4, width > 0, height > 0,
              max(width, height) <= terms.maxEdge else { return false }
        return jpeg.prefix(2) == Data([0xFF, 0xD8]) && jpeg.suffix(2) == Data([0xFF, 0xD9])
    }

    // MARK: Deferred downloads

    /// True when the camera is holding this capture's full file and it hasn't arrived here yet — i.e.
    /// it was shot over a Bluetooth-only link. The UI offers a download; the camera also sends it
    /// automatically if a Wi-Fi lane appears.
    public func canDownloadFullFile(_ capture: CaptureResult) -> Bool {
        // One download at a time — starting another would clobber the in-flight Bluetooth transfer.
        connection.isConnected && !isReceivingFile && capture.fileAvailable && !isDownloaded(capture)
    }

    /// Whether a file is transferring right now (used to keep the UI from starting an overlapping one).
    public var isReceivingFile: Bool { downloadingCaptureID != nil || !savingFiles.isEmpty }

    public func isDownloading(_ capture: CaptureResult) -> Bool { downloadingCaptureID == capture.id }
    public func isDownloaded(_ capture: CaptureResult) -> Bool { downloadedCaptureIDs.contains(capture.id) }

    /// Roughly how long this capture would take over Bluetooth (~28 KB/s) at the given quality. The
    /// compressed qualities are estimated from typical re-encode ratios (photos only).
    public func estimatedBluetoothSeconds(for capture: CaptureResult, quality: TransferQuality = .full) -> Int {
        let factor: Double
        switch quality {
        case .full: factor = 1
        case .high: factor = capture.kind == .photo ? 0.4 : 1
        case .medium: factor = capture.kind == .photo ? 0.15 : 1
        }
        return max(1, Int((Double(capture.byteCount) * factor / 1024.0) / 28.0))
    }

    /// Ask the camera to send a deferred capture, at the given quality.
    public func requestFullFile(_ capture: CaptureResult, quality: TransferQuality = .full) {
        guard canDownloadFullFile(capture) else { return }
        downloadingCaptureID = capture.id
        transfer = TransferStatus(name: TransferName.make(id: capture.id, ext: "dat"), fraction: 0, phase: .receiving)
        send(.requestFile(id: capture.id, quality: quality))
        armDownloadWatchdog(for: capture.id)
    }

    /// Stop a download the user started.
    public func cancelDownload(_ capture: CaptureResult) {
        send(.cancelTransfer(id: capture.id))
        if downloadingCaptureID == capture.id { downloadingCaptureID = nil }
        endDownloadWatchdog()
        transfer = nil
    }

    private func armDownloadWatchdog(for id: UUID) {
        downloadWatchdog?.cancel()
        downloadWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.failStalledDownload(id)
        }
    }

    private func endDownloadWatchdog() {
        downloadWatchdog?.cancel()
        downloadWatchdog = nil
    }

    private func failStalledDownload(_ id: UUID) {
        guard downloadingCaptureID == id else { return }
        send(.cancelTransfer(id: id))
        downloadingCaptureID = nil
        transfer = nil
        show("The download stalled — try again.")
    }

    // MARK: Events

    private func send(_ command: RemoteCommand) {
        guard let peer = connection.peer else { return }
        do {
            try transport.send(try codec.encode(.command(command)), to: [peer])
        } catch {
            show("Couldn't reach the camera.")
        }
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .peerFound(let peer):
            cameras.removeAll { $0.id == peer.id }
            if Pairing.isCompatibleCamera(peer.discoveryInfo) {
                cameras.append(peer)
            }
            if isReconnecting, isRememberedCamera(peer) {
                attemptReconnect()
            }
        case .peerLost(let peer):
            cameras.removeAll { $0.id == peer.id }
        case .invitation(_, _, let respond):
            // A remote never accepts invitations; only cameras do.
            respond(false)
        case .connecting:
            // invite already records the expected peer; late callbacks cannot revive a canceled attempt.
            break
        case .connected(let peer):
            // Wait for hello, and ignore late or duplicate callbacks from a canceled invitation.
            guard case .connecting(let expected) = connection, expected.id == peer.id else { return }
            clearStaleAttempt()
        case .disconnected(let peer):
            if isReconnecting, case .browsing = connection, staleAttemptPeerID == peer.id {
                // The attempt that timed out has now been torn down: start the next one.
                clearStaleAttempt()
                attemptReconnect()
                return
            }
            guard connection.peer?.id == peer.id else { return }
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
            let wasPaired = connection.isConnected
            let reachedCamera = didReceiveChallenge
            let connectionPeerBeforeDrop = connection.peer
            connection = .browsing
            camera = nil
            cameraState = nil
            didReceiveChallenge = false
            fileChannelFast = nil
            downloadingCaptureID = nil
            transfer = nil
            invalidateAvailableFiles()
            endDownloadWatchdog()
            clearPreview(status: .off)
            if expectsDisconnect {
                expectsDisconnect = false
                isReconnecting = false
                reconnectName = nil
            } else if wasPaired, let peer = connectionPeerBeforeDrop {
                // A paired session dropped unexpectedly — common on peer-to-peer Wi-Fi. Try to get it
                // back automatically a few times before telling the user.
                reconnectName = peer.displayName
                reconnectID = peer.id
                if !isReconnecting { reconnectAttemptsLeft = reconnectBudget }
                isReconnecting = true
                attemptReconnect()
            } else if isReconnecting {
                // A reconnect attempt failed to connect; try again until the budget runs out.
                attemptReconnect()
            } else if reachedCamera {
                // We connected and were challenged, but pairing didn't complete — most likely the code.
                show("The camera didn't accept the code. Check it and try again.")
            } else {
                // The session never established — the Bluetooth link couldn't form.
                show(requiresCode
                    ? "Couldn't connect to the camera. Make sure Bluetooth is on and the devices are close."
                    : "Couldn't connect to the camera. Keep Wi-Fi on and Shot Caller open on both devices.")
            }
        case .message(let data, let peer):
            guard connection.peer?.id == peer.id else { return }
            handleMessage(data)
        case .fileReceiveStarted(let name, let peer):
            guard connection.isConnected, connection.peer?.id == peer.id else { return }
            let id = TransferName.parse(name)?.id
            downloadingCaptureID = id
            transfer = TransferStatus(name: name, fraction: 0, phase: .receiving)
            if let id { armDownloadWatchdog(for: id) }
        case .fileReceiveProgress(let name, let fraction):
            if transfer?.name == name { transfer?.fraction = fraction }
            if let id = TransferName.parse(name)?.id, id == downloadingCaptureID { armDownloadWatchdog(for: id) }
        case .fileReceived(let name, let url, let peer):
            guard connection.isConnected, connection.peer?.id == peer.id else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            endDownloadWatchdog()
            let id = TransferName.parse(name)?.id
            Task { await save(name: name, from: url, captureID: id) }
        case .fileReceiveFailed(let name, let error):
            if downloadingCaptureID == TransferName.parse(name)?.id { downloadingCaptureID = nil }
            endDownloadWatchdog()
            // A cancel (by either side) isn't a failure worth alarming the user about.
            transfer = error.lowercased().contains("cancel") ? nil : TransferStatus(name: name, fraction: 0, phase: .failed(error))
        case .fileSendProgress, .fileSendFinished:
            break
        case .fileChannelFast(let fast):
            fileChannelFast = fast
            if fast {
                reconcilePreview()
            } else if previewSubscription != nil || pendingPreviewRequestID != nil {
                clearPreview(status: .unavailable(PreviewLimits.needsWiFiMessage))
            } else if wantsPreview, previewDemand, connection.isConnected {
                preview = .unavailable(PreviewLimits.needsWiFiMessage)
            }
        case .preview(let data, let peer):
            guard connection.isConnected, connection.peer?.id == peer.id else { return }
            handlePreviewPacket(data)
        case .failure(let message):
            show(message)
        }
    }

    private func handleMessage(_ data: Data) {
        let message: Message
        do {
            message = try codec.decode(data)
        } catch MessageCodecError.unsupportedVersion {
            show("The camera is running a different version of the app. Update both devices.")
            expectsDisconnect = true
            transport.disconnect()
            return
        } catch {
            return
        }
        guard case .event(let event) = message else { return }
        switch event {
        case .challenge(let nonce):
            didReceiveChallenge = true
            guard let code = pendingCode, let peer = connection.peer else { return }
            let proof = Pairing.proof(code: code, challenge: PairingChallenge(nonce: nonce), remoteName: transport.localPeer.displayName)
            let submission = PairingSubmission(proof: proof, displayName: transport.localPeer.displayName, appVersion: appVersion)
            do {
                try transport.send(try codec.encode(.command(.pair(submission))), to: [peer])
            } catch {
                show("Couldn't reach the camera.")
            }
        case .hello(let info):
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
            // The camera accepted our code.
            camera = info
            isReconnecting = false
            reconnectName = nil
            reconnectAttemptsLeft = 0
            if let peer = connection.peer {
                connection = .connected(peer)
            }
            if info.protocolVersion != WireProtocol.version {
                show("The camera is running a different version of the app. Update both devices.")
                expectsDisconnect = true
                transport.disconnect()
            } else {
                sendPreferences()
                reconcilePreview()
            }
        case .state(let state):
            cameraState = state
        case .captureFinished(let result):
            if let index = captures.firstIndex(where: { $0.id == result.id }) {
                captures[index] = result   // an update — e.g. a stranded auto-send is now downloadable
            } else {
                captures.append(result)
                if !result.willSendFile {
                    let kind = result.kind == .photo ? "Photo" : "Video"
                    if result.savedOnCamera == true || (result.savedOnCamera == nil && cameraState?.keepsCopies != false) {
                        show("\(kind) saved on the camera.")
                    } else if result.fileAvailable {
                        show("\(kind) ready to download. No copy saved in the camera's Photos.")
                    } else {
                        show("\(kind) captured. No copy saved in the camera's Photos.")
                    }
                }
            }
        case .captureFailed(let reason):
            show(reason)
        case .rejected(let reason):
            // The camera is about to drop us; show its reason instead of the generic disconnect one.
            expectsDisconnect = true
            show(reason)
        case .previewStarted(let subscription):
            guard subscription.requestID == pendingPreviewRequestID, previewSubscription == nil, wantsPreview, previewDemand else {
                send(.stopPreview(id: subscription.id))   // an answer to a request we gave up on
                return
            }
            pendingPreviewRequestID = nil
            previewSubscription = subscription
            preview = .starting
            startPreviewWatchdog()
            requestNextFrame(after: 0)
        case .previewRefused(let requestID, let reason):
            guard requestID == pendingPreviewRequestID else { return }
            pendingPreviewRequestID = nil
            if wantsPreview, previewDemand { preview = .unavailable(reason) }
        case .previewEnded(let id, let reason):
            // Ends for a retired subscription (one we already stopped, or one replaced by a newer start)
            // are history. An end without words for the current one means the camera dropped it for no
            // reason of its own (an expired lease): renew it, if still wanted.
            guard previewSubscription?.id == id else { return }
            clearPreview(status: reason.map { .unavailable($0) } ?? .off)
            if reason == nil { reconcilePreview() }
        case .pong:
            break
        }
    }

    private func save(name: String, from url: URL, captureID: UUID? = nil) async {
        guard !savingFiles.contains(url), !isStopped else { return }
        savingFiles.insert(url)
        transfer = TransferStatus(name: name, fraction: 1, phase: .saving)
        defer {
            savingFiles.remove(url)
            if downloadingCaptureID == captureID { downloadingCaptureID = nil }
        }
        do {
            let fileExtension = url.pathExtension.lowercased()
            if ["mov", "mp4", "m4v"].contains(fileExtension) {
                try await mediaStore.saveVideo(fileURL: url)
            } else {
                try await mediaStore.savePhoto(data: Data(contentsOf: url), fileExtension: fileExtension)
            }
            try? FileManager.default.removeItem(at: url)
            unsavedFiles[url] = nil
            if let captureID { downloadedCaptureIDs.insert(captureID) }
            if !isStopped { transfer = TransferStatus(name: name, fraction: 1, phase: .saved) }
        } catch {
            guard !isStopped else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            unsavedFiles[url] = UnsavedFile(name: name, url: url, captureID: captureID)
            let reason = CameraHostModel.describe(error)
            transfer = TransferStatus(name: name, fraction: 1, phase: .failed(reason))
            let kind = ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) ? "video" : "photo"
            show("Couldn't save the \(kind) to Photos. The file is kept here while this screen stays open. \(reason)")
        }
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
}
