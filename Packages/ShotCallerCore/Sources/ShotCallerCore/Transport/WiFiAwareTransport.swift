#if os(iOS)
import Foundation
import Network
import WiFiAware
import os

enum WAFrame: Codable, Sendable {
    case message(Data)
    case fileBegin(id: String, name: String, size: Int)
    case fileChunk(id: String, data: Data)
    case fileEnd(id: String)
}

/// A system-paired Wi-Fi Aware link. Every connection is owned by a cancellable task. In particular,
/// an accepted connection must remain inside the listener's run handler for its entire lifetime.
@available(iOS 26.0, *)
public final class WiFiAwareTransport: PeerTransport, @unchecked Sendable {
    typealias AppProtocol = Coder<WAFrame, WAFrame, NetworkJSONCoder>
    typealias Connection = NetworkConnection<AppProtocol>

    public let localPeer: Peer
    public let events: AsyncStream<TransportEvent>
    public var requiresAppLevelPairing: Bool { false }

    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let serviceName: String
    private let lock = NSLock()
    private let log = Logger(subsystem: "com.richardnelson.opensourceselfiestick", category: "wifiaware")
    private var listenerTask: Task<Void, Never>?
    private var browserTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var listenerID: UUID?
    private var browserID: UUID?
    private var advertisingRequested = false
    private var browsingRequested = false
    private var pairingSuspended = false
    private var session = SinglePeerSession()
    private var connection: Connection?
    private var endpointsByPeerID: [String: WAEndpoint] = [:]
    private var selectedEndpointsByPeerID: [String: WAEndpoint] = [:]
    private var fileSend: (id: UUID, name: String, cancelled: Bool)?
    private struct IncomingFile {
        let handle: FileHandle
        let url: URL
        let name: String
        let size: Int
        var received = 0
    }
    private var incomingFiles: [String: IncomingFile] = [:]
    private let inboxDirectory: URL

    public static var isSupported: Bool {
        WACapabilities.supportedFeatures.contains(.wifiAware)
    }

    public init(displayName: String, serviceName: String = "_\(WireProtocol.serviceType)._udp") {
        self.serviceName = serviceName
        localPeer = Peer(id: "local", displayName: displayName)
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
        inboxDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ShotCallerWAInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
    }

    deinit {
        listenerTask?.cancel()
        browserTask?.cancel()
        connectionTask?.cancel()
        timeoutTask?.cancel()
        messageTask?.cancel()
        for file in incomingFiles.values {
            try? file.handle.close()
            try? FileManager.default.removeItem(at: file.url)
        }
        continuation.finish()
    }

    public var connectedPeers: [Peer] {
        lock.withLock { session.current.map { $0.isReady ? [$0.peer] : [] } ?? [] }
    }

    // MARK: Pairing handoff

    /// DeviceDiscoveryUI claims the same publish/subscribe service. Wait for our network tasks to
    /// finish before mounting its controls, including when a person adds a second paired device.
    public func suspendForPairing() async {
        let tasks = lock.withLock { () -> [Task<Void, Never>] in
            pairingSuspended = true
            let tasks = [listenerTask, browserTask].compactMap { $0 }
            listenerID = nil
            browserID = nil
            listenerTask = nil
            browserTask = nil
            tasks.forEach { $0.cancel() }
            return tasks
        }
        clearDiscovered()
        for task in tasks { await task.value }
    }

    /// Call only after the pairing controls disappear, so there is a single owner of the service.
    public func resumeAfterPairing() {
        let requested = lock.withLock { () -> (Bool, Bool) in
            pairingSuspended = false
            return (advertisingRequested, browsingRequested)
        }
        if requested.0 { startAdvertising(discoveryInfo: [:]) }
        if requested.1 { startBrowserIfRequested() }
    }

    /// Preserve the actual selection from DevicePicker instead of hoping a later browse returns it.
    public func registerPairedEndpoint(_ endpoint: WAEndpoint) -> Peer {
        let peer = peer(for: endpoint)
        lock.withLock {
            endpointsByPeerID[peer.id] = endpoint
            selectedEndpointsByPeerID[peer.id] = endpoint
        }
        continuation.yield(.peerFound(peer))
        return peer
    }

    // MARK: Discovery

    public func startAdvertising(discoveryInfo: [String: String]) {
        guard Self.isSupported, let service = WAPublishableService.allServices[serviceName] else {
            continuation.yield(.failure("Wi-Fi Aware isn’t available. Choose Automatic connection on both devices."))
            return
        }
        lock.withLock {
            advertisingRequested = true
            guard !pairingSuspended, listenerTask == nil else { return }
            let id = UUID()
            listenerID = id
            listenerTask = Task { [weak self] in await self?.runListener(service: service, id: id) }
        }
    }

    public func stopAdvertising() {
        lock.withLock {
            advertisingRequested = false
            // The listener owns accepted connections. Stopping discovery after .connected must not
            // cancel the active remote. The session gate rejects all further incoming connections.
            guard session.current == nil else { return }
            listenerID = nil
            listenerTask?.cancel()
            listenerTask = nil
        }
    }

    private func runListener(service: WAPublishableService, id: UUID) async {
        while !Task.isCancelled {
            do {
                guard try await hasPairedDevice() else {
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
                let listener = try NetworkListener(
                    for: .wifiAware(.connecting(to: service, from: .allPairedDevices))
                ) { Coder(WAFrame.self, using: .json) { TCP() } }
                Trace.log("Wi-Fi Aware listener starting")
                try await listener.run { [weak self] connection in
                    guard let self, !Task.isCancelled else { return }
                    let peer = Peer(id: connection.id, displayName: "Remote")
                    let sessionID = UUID()
                    let accepted = self.lock.withLock {
                        self.listenerID == id && !self.pairingSuspended &&
                        self.session.begin(id: sessionID, peer: peer)
                    }
                    guard accepted else { return }
                    await self.receive(connection: connection, sessionID: sessionID, timeout: 30)
                }
            } catch {
                guard !Task.isCancelled, lock.withLock({ listenerID == id }) else { return }
                reportDiscoveryError(error)
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    public func startBrowsing() {
        lock.withLock { browsingRequested = true }
        startBrowserIfRequested()
    }

    private func startBrowserIfRequested() {
        guard Self.isSupported, let service = WASubscribableService.allServices[serviceName] else {
            continuation.yield(.failure("Wi-Fi Aware isn’t available. Choose Automatic connection on both devices."))
            return
        }
        lock.withLock {
            guard browsingRequested, !pairingSuspended, browserTask == nil else { return }
            let id = UUID()
            browserID = id
            browserTask = Task { [weak self] in await self?.runBrowser(service: service, id: id) }
        }
    }

    public func stopBrowsing() {
        lock.withLock {
            browsingRequested = false
            browserID = nil
            browserTask?.cancel()
            browserTask = nil
        }
        clearDiscovered()
    }

    private func runBrowser(service: WASubscribableService, id: UUID) async {
        while !Task.isCancelled {
            do {
                guard try await hasPairedDevice() else {
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
                let browser = NetworkBrowser(for: .wifiAware(.connecting(to: .allPairedDevices, from: service)))
                try await browser.run { [weak self] endpoints in
                    self?.updateDiscovered(endpoints, browserID: id)
                }
            } catch {
                guard !Task.isCancelled, lock.withLock({ browserID == id }) else { return }
                clearDiscovered()
                reportDiscoveryError(error)
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private func hasPairedDevice() async throws -> Bool {
        try await WAPairedDevice.allDevices.current()?.isEmpty == false
    }

    private func reportDiscoveryError(_ error: Error) {
        log.error("Wi-Fi Aware discovery: \(error.localizedDescription, privacy: .public)")
        Trace.log("Wi-Fi Aware discovery error: \(error.localizedDescription)")
        continuation.yield(.failure("Wi-Fi Aware couldn’t find the other device. Keep both apps open and Wi-Fi on, or choose Automatic connection."))
    }

    private func updateDiscovered(_ endpoints: [WAEndpoint], browserID id: UUID) {
        lock.withLock {
            guard browserID == id, !pairingSuspended else { return }
            let live = Set(endpoints.map { String($0.device.id) })
            for peerID in Array(endpointsByPeerID.keys) where !live.contains(peerID) {
                if let endpoint = endpointsByPeerID.removeValue(forKey: peerID) {
                    continuation.yield(.peerLost(peer(for: endpoint)))
                }
            }
            for endpoint in endpoints {
                let peer = peer(for: endpoint)
                if endpointsByPeerID[peer.id] == nil { continuation.yield(.peerFound(peer)) }
                endpointsByPeerID[peer.id] = endpoint
            }
        }
    }

    private func clearDiscovered() {
        lock.withLock {
            for endpoint in endpointsByPeerID.values { continuation.yield(.peerLost(peer(for: endpoint))) }
            endpointsByPeerID.removeAll()
            selectedEndpointsByPeerID.removeAll()
        }
    }

    // MARK: Connection ownership

    public func invite(_ peer: Peer, context: Data?, timeout: TimeInterval) {
        lock.withLock {
            guard !pairingSuspended,
                  let endpoint = selectedEndpointsByPeerID.removeValue(forKey: peer.id) ?? endpointsByPeerID[peer.id] else {
                // Models wait for .disconnected to leave their connecting state.
                continuation.yield(.disconnected(peer))
                continuation.yield(.failure("That camera is no longer available. Keep Camera open on it and try again."))
                return
            }
            let id = UUID()
            guard session.begin(id: id, peer: peer) else { return }
            continuation.yield(.connecting(peer))
            let previousBrowser = browserTask
            browserID = nil
            browserTask = nil
            previousBrowser?.cancel()
            for discovered in endpointsByPeerID.values { continuation.yield(.peerLost(self.peer(for: discovered))) }
            endpointsByPeerID.removeAll()
            selectedEndpointsByPeerID.removeAll()
            connectionTask = Task { [weak self] in
                // The browser and the selected connection must not both subscribe to the service.
                await previousBrowser?.value
                guard let self, !Task.isCancelled,
                      self.lock.withLock({ self.session.current?.id == id }) else { return }
                // Construct within the task we own: cancelling this task closes the connection.
                let connection = NetworkConnection(to: endpoint) { Coder(WAFrame.self, using: .json) { TCP() } }
                await self.receive(connection: connection, sessionID: id, timeout: max(1, timeout))
            }
        }
    }

    private func receive(connection: Connection, sessionID id: UUID, timeout: TimeInterval) async {
        let accepted = lock.withLock { () -> Bool in
            guard session.current?.id == id, !Task.isCancelled else { return false }
            self.connection = connection
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                self?.connectionTimedOut(id: id)
            }
            return true
        }
        guard accepted else { return }
        connection.onStateUpdate { [weak self] _, state in
            guard let self else { return }
            Trace.log("Wi-Fi Aware connection \(id): \(String(describing: state))")
            switch state {
            case .ready:
                self.lock.withLock {
                    guard let peer = self.session.ready(id: id) else { return }
                    self.timeoutTask?.cancel()
                    self.timeoutTask = nil
                    self.continuation.yield(.connected(peer))
                    self.continuation.yield(.fileChannelFast(true))
                }
            case .failed(let error):
                self.finishSession(id: id, error: error.localizedDescription)
            case .cancelled:
                self.finishSession(id: id)
            default:
                break
            }
        }
        defer { finishSession(id: id) }
        do {
            for try await message in connection.messages {
                guard !Task.isCancelled else { break }
                lock.withLock {
                    guard session.current?.id == id, let peer = session.current?.peer else { return }
                    handle(frame: message.content, from: peer)
                }
            }
        } catch {
            if !Task.isCancelled { finishSession(id: id, error: error.localizedDescription) }
        }
    }

    private func connectionTimedOut(id: UUID) {
        let waiting = lock.withLock { session.current?.id == id && session.current?.isReady == false }
        guard waiting else { return }
        finishSession(id: id, error: "Connection timed out. Keep both apps open, turn on Wi-Fi, and try again.")
    }

    private func finishSession(id: UUID, error: String? = nil) {
        let shouldResumeBrowsing = lock.withLock { () -> Bool in
            let wasReady = session.current?.isReady == true
            guard let peer = session.finish(id: id) else { return false }
            connection = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            connectionTask?.cancel()
            connectionTask = nil
            // Cancelling the listener also closes its accepted connection, and releases its service
            // before CameraHostModel starts advertising again after the disconnected event.
            listenerID = nil
            listenerTask?.cancel()
            listenerTask = nil
            messageTask?.cancel()
            messageTask = nil
            if let fileSend {
                continuation.yield(.fileSendFinished(name: fileSend.name, error: "The connection ended before the file finished."))
            }
            fileSend = nil
            discardIncomingFiles(error: "The connection ended before the file finished.")
            continuation.yield(.disconnected(peer))
            if let error {
                Trace.log("Wi-Fi Aware session ended: \(error)")
                continuation.yield(.failure(wasReady
                    ? "The Wi-Fi Aware connection was interrupted. Keep both apps open and Wi-Fi on to reconnect."
                    : "Couldn’t connect. On the camera, finish the system prompt and tap Done pairing, then try again with Wi-Fi on."))
            }
            return browsingRequested && !pairingSuspended
        }
        if shouldResumeBrowsing { startBrowserIfRequested() }
    }

    public func disconnect() {
        let id = lock.withLock { session.current?.id }
        if let id { finishSession(id: id) }
    }

    // MARK: Sending

    public func send(_ data: Data, to peers: [Peer]) throws {
        try lock.withLock {
            guard let connection, let current = session.current, current.isReady,
                  peers.contains(where: { $0.id == current.peer.id }) else { throw TransportError.notConnected }
            // Preserve ordering of hello/state and command messages even though PeerTransport.send
            // is synchronous. Each task waits for the previous send before touching the connection.
            let previous = messageTask
            messageTask = Task { [weak self] in
                await previous?.value
                guard !Task.isCancelled else { return }
                do { try await connection.send(.message(data)) }
                catch { self?.finishSession(id: current.id, error: error.localizedDescription) }
            }
        }
    }

    public func sendFile(at url: URL, named name: String, to peer: Peer) {
        lock.withLock {
            guard let connection, let current = session.current, current.isReady, current.peer.id == peer.id else {
                continuation.yield(.fileSendFinished(name: name, error: "Not connected"))
                return
            }
            guard fileSend == nil else {
                continuation.yield(.fileSendFinished(name: name, error: "Another file is still sending."))
                return
            }
            let id = UUID()
            fileSend = (id, name, false)
            let previousMessage = messageTask
            Task { [weak self] in
                // Capture metadata must reach the remote before its file can finish and be saved.
                await previousMessage?.value
                guard let self else { return }
                let active = self.lock.withLock {
                    self.session.current?.id == current.id && self.fileSend?.id == id
                }
                guard active else { return }
                await self.streamFile(at: url, named: name, id: id, sessionID: current.id, over: connection)
            }
        }
    }

    public func cancelFileSend() {
        // Cooperate between chunks; cancelling a Network task could also close the control link.
        lock.withLock { fileSend?.cancelled = true }
    }

    private func streamFile(at url: URL, named name: String, id: UUID, sessionID: UUID, over connection: Connection) async {
        var began = false
        do {
            guard lock.withLock({ fileSend?.id == id && fileSend?.cancelled == false && session.current?.id == sessionID }) else {
                throw CancellationError()
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            try await connection.send(.fileBegin(id: id.uuidString, name: name, size: size))
            began = true
            var sent = 0
            while true {
                let active = lock.withLock { fileSend?.id == id && fileSend?.cancelled == false && session.current?.id == sessionID }
                guard active else { throw CancellationError() }
                guard let chunk = try handle.read(upToCount: 32 * 1024), !chunk.isEmpty else { break }
                try await connection.send(.fileChunk(id: id.uuidString, data: chunk))
                sent += chunk.count
                continuation.yield(.fileSendProgress(name: name, fraction: size > 0 ? min(1, Double(sent) / Double(size)) : 1))
            }
            try await connection.send(.fileEnd(id: id.uuidString))
            completeFileSend(id: id, name: name, error: nil)
        } catch {
            // Closing a partial transfer makes the receiver discard it without adding a new frame
            // case that would break older Wi-Fi Aware builds. Length validation prevents saving it.
            if began, lock.withLock({ session.current?.id == sessionID }) {
                try? await connection.send(.fileEnd(id: id.uuidString))
            }
            completeFileSend(id: id, name: name, error: error is CancellationError ? "Transfer cancelled" : error.localizedDescription)
        }
    }

    private func completeFileSend(id: UUID, name: String, error: String?) {
        lock.withLock {
            guard fileSend?.id == id else { return }
            fileSend = nil
            continuation.yield(.fileSendFinished(name: name, error: error))
        }
    }

    // MARK: Receiving files (called under lock)

    private func handle(frame: WAFrame, from peer: Peer) {
        switch frame {
        case .message(let data):
            continuation.yield(.message(data, from: peer))
        case .fileBegin(let id, let name, let size):
            guard size >= 0, incomingFiles.isEmpty else {
                continuation.yield(.fileReceiveFailed(name: name, error: "Invalid or overlapping file transfer."))
                return
            }
            let safeName = URL(fileURLWithPath: name).lastPathComponent
            let url = inboxDirectory.appendingPathComponent(UUID().uuidString + "-" + safeName)
            guard FileManager.default.createFile(atPath: url.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: url) else {
                try? FileManager.default.removeItem(at: url)
                continuation.yield(.fileReceiveFailed(name: name, error: "Couldn’t create the received file."))
                return
            }
            incomingFiles[id] = IncomingFile(handle: handle, url: url, name: name, size: size)
            continuation.yield(.fileReceiveStarted(name: name, from: peer))
        case .fileChunk(let id, let data):
            guard var file = incomingFiles[id] else { return }
            do {
                guard data.count <= file.size - file.received else { throw TransportError.sendFailed("The file exceeded its expected size.") }
                try file.handle.write(contentsOf: data)
                file.received += data.count
                incomingFiles[id] = file
                continuation.yield(.fileReceiveProgress(name: file.name, fraction: file.size > 0 ? Double(file.received) / Double(file.size) : 1))
            } catch {
                discardIncomingFiles(error: "Couldn’t receive the complete file. Try sending it again.")
            }
        case .fileEnd(let id):
            guard let file = incomingFiles.removeValue(forKey: id) else { return }
            do {
                try file.handle.close()
                guard file.received == file.size else { throw TransportError.sendFailed("Transfer cancelled before the file finished.") }
                continuation.yield(.fileReceived(name: file.name, url: file.url, from: peer))
            } catch {
                try? FileManager.default.removeItem(at: file.url)
                continuation.yield(.fileReceiveFailed(name: file.name, error: "Transfer cancelled before the file finished."))
            }
        }
    }

    private func discardIncomingFiles(error: String) {
        for file in incomingFiles.values {
            try? file.handle.close()
            try? FileManager.default.removeItem(at: file.url)
            continuation.yield(.fileReceiveFailed(name: file.name, error: error))
        }
        incomingFiles.removeAll()
    }

    private func peer(for endpoint: WAEndpoint) -> Peer {
        let device = endpoint.device
        return Peer(id: String(device.id), displayName: device.name ?? device.pairingInfo?.pairingName ?? "Camera")
    }
}
#endif
