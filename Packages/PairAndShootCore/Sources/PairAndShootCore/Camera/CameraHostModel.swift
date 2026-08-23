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

    public var lastCapture: CaptureResult? { captures.last }
    public var localName: String { transport.localPeer.displayName }

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
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var challenge = PairingChallenge.random()
    @ObservationIgnored private var failedAttempts = 0
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var recordingTicker: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingVideoSendBack = false
    @ObservationIgnored private var outgoingFiles: [String: URL] = [:]
    @ObservationIgnored private var expectsDisconnect = false

    public init(transport: any PeerTransport,
                device: any CameraDevice,
                mediaStore: any MediaStore,
                thumbnails: any ThumbnailMaker = NoThumbnails(),
                appVersion: String,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.transport = transport
        self.device = device
        self.mediaStore = mediaStore
        self.thumbnails = thumbnails
        self.appVersion = appVersion
        self.sleep = sleep
    }

    // MARK: Lifecycle

    public func start() async {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self, transport] in
            for await event in transport.events {
                guard let self else { return }
                self.handle(event)
            }
        }
        do {
            capabilities = try await device.start()
            try await device.apply(settings)
            availability = .ready
            advertise()
        } catch {
            availability = .unavailable(Self.describe(error))
        }
    }

    public func stop() async {
        captureTask?.cancel()
        recordingTicker?.cancel()
        eventTask?.cancel()
        eventTask = nil
        transport.stopAdvertising()
        transport.disconnect()
        await device.stop()
        link = .none
    }

    public func disconnectRemote() {
        expectsDisconnect = true
        transport.disconnect()
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

    public func dismissNotice() {
        notice = nil
    }

    private var settings: CameraSettings {
        CameraSettings(mode: state.mode, position: state.position, flash: state.flash)
    }

    private func execute(_ command: RemoteCommand) async {
        switch command {
        case .hello(let info):
            guard case .connected(let peer, _) = link else { return }
            if info.protocolVersion == WireProtocol.version {
                link = .connected(peer, info)
            } else {
                send(.rejected(reason: "The remote is running a different version of the app."))
                show("The remote is running a different version of the app. Update both devices.")
                expectsDisconnect = true
                transport.disconnect()
            }
        case .capturePhoto(let sendBack, let delay):
            startCapture { await self.capturePhoto(sendBack: sendBack, delay: delay) }
        case .startRecording(let sendBack, let delay):
            startCapture { await self.startRecording(sendBack: sendBack, delay: delay) }
        case .stopRecording:
            await stopRecording()
        case .cancelCountdown:
            if state.countdown != nil { captureTask?.cancel() }
        case .setMode(let mode):
            guard !state.isRecording, mode != state.mode else { return }
            guard mode == .photo || capabilities.canRecordVideo else { return }
            await update { $0.mode = mode }
        case .setPosition(let position):
            guard !state.isRecording, position != state.position else { return }
            guard position == .back || capabilities.hasFrontCamera else { return }
            await update { $0.position = position }
        case .setFlash(let flash):
            guard flash != state.flash else { return }
            guard flash == .off || capabilities.hasFlash else { return }
            await update { $0.flash = flash }
        case .ping:
            send(.pong)
        }
    }

    private func startCapture(_ work: @escaping @MainActor () async -> Void) {
        guard captureTask == nil || captureTask?.isCancelled == true else { return }
        captureTask = Task { [weak self] in
            await work()
            self?.captureTask = nil
        }
    }

    private func update(_ change: (inout CameraState) -> Void) async {
        var next = state
        change(&next)
        let settings = CameraSettings(mode: next.mode, position: next.position, flash: next.flash)
        do {
            try await device.apply(settings)
            state = next
            broadcastState()
        } catch {
            show(Self.describe(error))
        }
    }

    // MARK: Capturing

    /// Returns false when the countdown was cancelled.
    private func runCountdown(_ seconds: Int) async -> Bool {
        guard seconds > 0 else { return true }
        for remaining in stride(from: seconds, through: 1, by: -1) {
            state.countdown = remaining
            broadcastState()
            do {
                try await sleep(.seconds(1))
            } catch {
                state.countdown = nil
                broadcastState()
                return false
            }
        }
        state.countdown = nil
        broadcastState()
        return true
    }

    private func capturePhoto(sendBack: Bool, delay: Int) async {
        guard availability == .ready, !state.isBusy, !state.isRecording, state.countdown == nil else { return }
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
            var result = CaptureResult(kind: .photo, byteCount: photo.data.count, willSendFile: false, fileName: name)
            if sendBack, case .connected(let peer, _) = link {
                let url = try writeOutgoing(photo.data, name: name)
                outgoingFiles[name] = url
                outgoingTransfer = TransferStatus(name: name, fraction: 0, phase: .sending)
                transport.sendFile(at: url, named: name, to: peer)
                result.willSendFile = true
            }
            if keepsCopies {
                try await mediaStore.savePhoto(data: photo.data, fileExtension: photo.fileExtension)
            }
            result.thumbnailJPEG = await thumbnails.thumbnail(forPhoto: photo.data)
            captures.append(result)
            send(.captureFinished(result))
        } catch {
            let reason = "Couldn't take the photo. \(Self.describe(error))"
            show(reason)
            send(.captureFailed(reason: reason))
        }
    }

    private func startRecording(sendBack: Bool, delay: Int) async {
        guard availability == .ready, capabilities.canRecordVideo, state.mode == .video,
              !state.isRecording, !state.isBusy, state.countdown == nil else { return }
        guard await runCountdown(delay) else { return }
        do {
            try await device.startRecording()
            pendingVideoSendBack = sendBack
            state.isRecording = true
            state.recordingDuration = 0
            broadcastState()
            startTicker()
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
                try? await self.sleep(.milliseconds(500))
                guard !Task.isCancelled, self.state.isRecording else { return }
                let duration = await self.device.recordingDuration()
                let secondChanged = Int(duration) != Int(self.state.recordingDuration)
                self.state.recordingDuration = duration
                if secondChanged { self.broadcastState() }
            }
        }
    }

    private func stopRecording() async {
        guard state.isRecording else { return }
        recordingTicker?.cancel()
        recordingTicker = nil
        state.isBusy = true
        broadcastState()
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
            var result = CaptureResult(kind: .video, byteCount: size, willSendFile: false, fileName: name, duration: movie.duration)
            if pendingVideoSendBack, case .connected(let peer, _) = link {
                outgoingFiles[name] = movie.url
                outgoingTransfer = TransferStatus(name: name, fraction: 0, phase: .sending)
                transport.sendFile(at: movie.url, named: name, to: peer)
                result.willSendFile = true
            }
            if keepsCopies {
                try await mediaStore.saveVideo(fileURL: movie.url)
            }
            result.thumbnailJPEG = await thumbnails.thumbnail(forVideoAt: movie.url)
            if !result.willSendFile {
                try? FileManager.default.removeItem(at: movie.url)
            }
            captures.append(result)
            send(.captureFinished(result))
        } catch {
            state.isRecording = false
            state.recordingDuration = 0
            let reason = "Couldn't save the video. \(Self.describe(error))"
            show(reason)
            send(.captureFailed(reason: reason))
        }
    }

    // MARK: Transport events

    private func handle(_ event: TransportEvent) {
        switch event {
        case .invitation(let peer, let context, let respond):
            guard case .none = link else {
                respond(false)
                return
            }
            switch Pairing.verify(context: context, code: pairingCode, challenge: challenge) {
            case .accepted:
                link = .connecting(peer)
                respond(true)
            case .rejected:
                respond(false)
                failedAttempts += 1
                if failedAttempts >= Self.maxFailedAttempts {
                    pairingCode = .random()
                    failedAttempts = 0
                    advertise()
                    show("Too many wrong codes. A new code has been issued.")
                }
            }
        case .connecting(let peer):
            if case .none = link { link = .connecting(peer) }
        case .connected(let peer):
            guard link.peer == nil || link.peer?.id == peer.id else { return }
            link = .connected(peer, nil)
            failedAttempts = 0
            transport.stopAdvertising()
            send(.hello(HelloInfo(appVersion: appVersion, displayName: transport.localPeer.displayName, capabilities: capabilities)))
            broadcastState()
        case .disconnected(let peer):
            guard link.peer?.id == peer.id else { return }
            let wasConnected = link.isConnected
            link = .none
            if state.countdown != nil { captureTask?.cancel() }
            if availability == .ready { advertise() }
            if expectsDisconnect {
                expectsDisconnect = false
            } else if wasConnected {
                show("The remote disconnected.")
            }
        case .message(let data, let peer):
            guard link.peer?.id == peer.id else { return }
            handleMessage(data)
        case .fileSendProgress(let name, let fraction):
            outgoingTransfer = TransferStatus(name: name, fraction: fraction, phase: .sending)
        case .fileSendFinished(let name, let error):
            if let url = outgoingFiles.removeValue(forKey: name) {
                try? FileManager.default.removeItem(at: url)
            }
            outgoingTransfer = TransferStatus(name: name, fraction: 1, phase: error.map { .failed($0) } ?? .sent)
        case .failure(let message):
            show(message)
        case .peerFound, .peerLost, .fileReceiveStarted, .fileReceiveProgress, .fileReceived, .fileReceiveFailed:
            break
        }
    }

    private func handleMessage(_ data: Data) {
        do {
            guard case .command(let command) = try codec.decode(data) else { return }
            Task { await execute(command) }
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
        challenge = .random()
        transport.startAdvertising(discoveryInfo: Pairing.discoveryInfo(for: challenge))
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PairAndShootOutbox", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
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
