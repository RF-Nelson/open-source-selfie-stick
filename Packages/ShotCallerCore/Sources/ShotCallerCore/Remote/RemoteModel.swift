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

    public private(set) var connection: Connection = .idle
    /// Compatible cameras in range, most recently seen last.
    public private(set) var cameras: [Peer] = []
    public private(set) var camera: HelloInfo?
    public private(set) var cameraState: CameraState?
    public private(set) var captures: [CaptureResult] = []
    public private(set) var transfer: TransferStatus?
    /// A short, transient message for the person holding the remote.
    public private(set) var notice: String?
    /// The current file-transfer channel while connected: false = Bluetooth only, true = Bluetooth + a
    /// fast Wi-Fi lane. nil when the transport is single-channel (Wi-Fi Aware) or not connected.
    public private(set) var fileChannelFast: Bool?
    /// Captures whose full-resolution file has arrived and been saved here.
    private var downloadedCaptureIDs: Set<UUID> = []
    /// The capture whose file is transferring right now (auto over Wi-Fi, or a Bluetooth download).
    private var downloadingCaptureID: UUID?
    /// Fails a download that makes no progress for a while, so a stalled transfer can't permanently
    /// block the one-at-a-time download slot. Re-armed on every progress update.
    @ObservationIgnored private var downloadWatchdog: Task<Void, Never>?

    public var timerSeconds = 0
    public var sendBackPhotos = true
    public var sendBackVideos = false

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
    @ObservationIgnored private var reconnectAttemptsLeft = 0
    public private(set) var isReconnecting = false

    public init(transport: any PeerTransport, mediaStore: any MediaStore, appVersion: String) {
        self.transport = transport
        self.mediaStore = mediaStore
        self.appVersion = appVersion
    }

    // MARK: Lifecycle

    public func start() {
        guard eventTask == nil else { return }
        connection = .browsing
        transport.startBrowsing()
        eventTask = Task { [weak self, transport] in
            for await event in transport.events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    public func stop() {
        eventTask?.cancel()
        eventTask = nil
        transport.stopBrowsing()
        transport.disconnect()
        pendingCode = nil
        reconnectName = nil
        reconnectAttemptsLeft = 0
        isReconnecting = false
        connection = .idle
        cameras = []
        camera = nil
        cameraState = nil
    }

    // MARK: Connecting

    public func connect(to peer: Peer, code: PairingCode? = nil) {
        // A deliberate connection cancels any in-progress auto-reconnect to a previous camera.
        isReconnecting = false
        reconnectName = nil
        reconnectAttemptsLeft = 0
        invite(peer, code: code)
    }

    private func invite(_ peer: Peer, code: PairingCode?) {
        pendingCode = code
        didReceiveChallenge = false
        connection = .connecting(peer)
        // The code is proved over the data channel once connected; no secret in the invitation, and a
        // longer timeout because peer-to-peer Wi-Fi can be slow to establish.
        transport.invite(peer, context: nil, timeout: 30)
    }

    private func attemptReconnect() {
        guard isReconnecting, let name = reconnectName, case .browsing = connection else { return }
        guard reconnectAttemptsLeft > 0 else {
            isReconnecting = false
            reconnectName = nil
            show("The camera disconnected.")
            return
        }
        guard let peer = cameras.first(where: { $0.displayName == name }) else {
            return   // wait for the camera to be rediscovered (handled in .peerFound)
        }
        reconnectAttemptsLeft -= 1
        invite(peer, code: pendingCode)
    }

    public func disconnect() {
        expectsDisconnect = true
        transport.disconnect()
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
            guard !state.isBusy else { return }
            send(.capturePhoto(sendBack: sendBackPhotos, delay: timerSeconds))
        case .video:
            if state.isRecording {
                send(.stopRecording)
            } else if !state.isBusy {
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

    // MARK: Deferred downloads

    /// True when the camera is holding this capture's full file and it hasn't arrived here yet — i.e.
    /// it was shot over a Bluetooth-only link. The UI offers a download; the camera also sends it
    /// automatically if a Wi-Fi lane appears.
    public func canDownloadFullFile(_ capture: CaptureResult) -> Bool {
        // One download at a time — starting another would clobber the in-flight Bluetooth transfer.
        downloadingCaptureID == nil && capture.fileAvailable && !isDownloaded(capture)
    }

    /// Whether a file is transferring right now (used to keep the UI from starting an overlapping one).
    public var isReceivingFile: Bool { downloadingCaptureID != nil }

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
            if isReconnecting, reconnectName == peer.displayName {
                attemptReconnect()
            }
        case .peerLost(let peer):
            cameras.removeAll { $0.id == peer.id }
        case .invitation(_, _, let respond):
            // A remote never accepts invitations; only cameras do.
            respond(false)
        case .connecting(let peer):
            if case .browsing = connection { connection = .connecting(peer) }
        case .connected(let peer):
            // Stay "connecting" until the camera challenges us and accepts our code.
            connection = .connecting(peer)
        case .disconnected(let peer):
            guard connection.peer?.id == peer.id else { return }
            let wasPaired = connection.isConnected
            let reachedCamera = didReceiveChallenge
            let connectionPeerBeforeDrop = connection.peer
            connection = .browsing
            camera = nil
            cameraState = nil
            didReceiveChallenge = false
            fileChannelFast = nil
            downloadingCaptureID = nil
            endDownloadWatchdog()
            if expectsDisconnect {
                expectsDisconnect = false
                isReconnecting = false
                reconnectName = nil
            } else if wasPaired, let peer = connectionPeerBeforeDrop {
                // A paired session dropped unexpectedly — common on peer-to-peer Wi-Fi. Try to get it
                // back automatically a few times before telling the user.
                reconnectName = peer.displayName
                if !isReconnecting { reconnectAttemptsLeft = 3 }
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
                show("Couldn't connect to the camera. Make sure Bluetooth is on and the devices are close.")
            }
        case .message(let data, let peer):
            guard connection.peer?.id == peer.id else { return }
            handleMessage(data)
        case .fileReceiveStarted(let name, _):
            let id = TransferName.parse(name)?.id
            downloadingCaptureID = id
            transfer = TransferStatus(name: name, fraction: 0, phase: .receiving)
            if let id { armDownloadWatchdog(for: id) }
        case .fileReceiveProgress(let name, let fraction):
            if transfer?.name == name { transfer?.fraction = fraction }
            if let id = TransferName.parse(name)?.id, id == downloadingCaptureID { armDownloadWatchdog(for: id) }
        case .fileReceived(let name, let url, _):
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
            }
        case .state(let state):
            cameraState = state
        case .captureFinished(let result):
            if let index = captures.firstIndex(where: { $0.id == result.id }) {
                captures[index] = result   // an update — e.g. a stranded auto-send is now downloadable
            } else {
                captures.append(result)
                if !result.willSendFile {
                    show(result.kind == .photo ? "Photo saved on the camera." : "Video saved on the camera.")
                }
            }
        case .captureFailed(let reason):
            show(reason)
        case .rejected(let reason):
            // The camera is about to drop us; show its reason instead of the generic disconnect one.
            expectsDisconnect = true
            show(reason)
        case .pong:
            break
        }
    }

    private func save(name: String, from url: URL, captureID: UUID? = nil) async {
        transfer = TransferStatus(name: name, fraction: 1, phase: .saving)
        defer {
            try? FileManager.default.removeItem(at: url)
            if downloadingCaptureID == captureID { downloadingCaptureID = nil }
        }
        do {
            let fileExtension = url.pathExtension.lowercased()
            if ["mov", "mp4", "m4v"].contains(fileExtension) {
                try await mediaStore.saveVideo(fileURL: url)
            } else {
                try await mediaStore.savePhoto(data: Data(contentsOf: url), fileExtension: fileExtension)
            }
            if let captureID { downloadedCaptureIDs.insert(captureID) }
            transfer = TransferStatus(name: name, fraction: 1, phase: .saved)
        } catch {
            transfer = TransferStatus(name: name, fraction: 1, phase: .failed(error.localizedDescription))
            let kind = ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) ? "video" : "photo"
            show("Couldn't save the \(kind) to this device. \(error.localizedDescription)")
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
