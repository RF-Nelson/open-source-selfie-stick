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

    public var timerSeconds = 0
    public var sendBackPhotos = true
    public var sendBackVideos = false

    public var lastCapture: CaptureResult? { captures.last }
    public var localName: String { transport.localPeer.displayName }

    @ObservationIgnored private let transport: any PeerTransport
    @ObservationIgnored private let mediaStore: any MediaStore
    @ObservationIgnored private let codec = MessageCodec()
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var expectsDisconnect = false

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
        connection = .idle
        cameras = []
        camera = nil
        cameraState = nil
    }

    // MARK: Connecting

    public func connect(to peer: Peer, code: PairingCode) {
        guard let challenge = Pairing.challenge(from: peer.discoveryInfo) else {
            show("That camera is running a different version of the app.")
            return
        }
        let proof = Pairing.proof(code: code, challenge: challenge, remoteName: transport.localPeer.displayName)
        connection = .connecting(peer)
        transport.invite(peer, context: proof, timeout: 15)
    }

    public func disconnect() {
        expectsDisconnect = true
        transport.disconnect()
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
            if Pairing.challenge(from: peer.discoveryInfo) != nil {
                cameras.append(peer)
            }
        case .peerLost(let peer):
            cameras.removeAll { $0.id == peer.id }
        case .invitation(_, _, let respond):
            // A remote never accepts invitations; only cameras do.
            respond(false)
        case .connecting(let peer):
            if case .browsing = connection { connection = .connecting(peer) }
        case .connected(let peer):
            connection = .connected(peer)
            send(.hello(HelloInfo(appVersion: appVersion, displayName: transport.localPeer.displayName)))
        case .disconnected(let peer):
            guard connection.peer?.id == peer.id else { return }
            let wasConnected = connection.isConnected
            connection = .browsing
            camera = nil
            cameraState = nil
            if expectsDisconnect {
                expectsDisconnect = false
            } else {
                show(wasConnected ? "The camera disconnected." : "The camera didn't accept the code. Check it and try again.")
            }
        case .message(let data, let peer):
            guard connection.peer?.id == peer.id else { return }
            handleMessage(data)
        case .fileReceiveStarted(let name, _):
            transfer = TransferStatus(name: name, fraction: 0, phase: .receiving)
        case .fileReceiveProgress(let name, let fraction):
            if transfer?.name == name { transfer?.fraction = fraction }
        case .fileReceived(let name, let url, _):
            Task { await save(name: name, from: url) }
        case .fileReceiveFailed(let name, let error):
            transfer = TransferStatus(name: name, fraction: 0, phase: .failed(error))
        case .fileSendProgress, .fileSendFinished:
            break
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
        case .hello(let info):
            camera = info
            if info.protocolVersion != WireProtocol.version {
                show("The camera is running a different version of the app. Update both devices.")
                expectsDisconnect = true
                transport.disconnect()
            }
        case .state(let state):
            cameraState = state
        case .captureFinished(let result):
            captures.append(result)
            if !result.willSendFile {
                show(result.kind == .photo ? "Photo saved on the camera." : "Video saved on the camera.")
            }
        case .captureFailed(let reason), .rejected(let reason):
            show(reason)
        case .pong:
            break
        }
    }

    private func save(name: String, from url: URL) async {
        transfer = TransferStatus(name: name, fraction: 1, phase: .saving)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let fileExtension = url.pathExtension.lowercased()
            if ["mov", "mp4", "m4v"].contains(fileExtension) {
                try await mediaStore.saveVideo(fileURL: url)
            } else {
                try await mediaStore.savePhoto(data: Data(contentsOf: url), fileExtension: fileExtension)
            }
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
