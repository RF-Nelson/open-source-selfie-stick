// Debug-only internal test mode (docs/TRANSPORT.md, 2026-10-10): Release builds compile none of this.
#if os(iOS) && DEBUG
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
    /// Each suspension for pairing gets a token; only its owner may resume discovery.
    private var pairingGeneration = 0
    /// Cancelled discovery tasks that may still be unwinding. A replacement awaits them first, so
    /// two publishers (or subscribers) of the service never overlap.
    private var retiringTasks: [Task<Void, Never>] = []
    /// When a session ended by failure; the next listener waits ~2 s so the radio can settle.
    private var lastFailureAt: Date?
    private var session = SinglePeerSession()
    private var connection: Connection?
    private var endpointsByPeerID: [String: WAEndpoint] = [:]
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
    /// Returns the token that `resumeAfterPairing(token:)` needs. A caller whose task was cancelled
    /// while awaiting must still pass its token back, and a newer suspension makes it a no-op.
    public func suspendForPairing() async -> Int {
        let token = lock.withLock { () -> Int in
            pairingSuspended = true
            pairingGeneration += 1
            let count = [listenerTask, browserTask, connectionTask].compactMap { $0 }.count
            Trace.log("Wi-Fi Aware suspend for pairing #\(pairingGeneration): cancelling \(count) task(s)")
            listenerID = nil
            browserID = nil
            retire(listenerTask)
            retire(browserTask)
            retire(connectionTask)
            listenerTask = nil
            browserTask = nil
            connectionTask = nil
            return pairingGeneration
        }
        clearDiscovered()
        // The barrier is shared: every suspension awaits whatever is still unwinding, however many
        // suspensions were started and stopped in between.
        await awaitRetiringTasks()
        Trace.log("Wi-Fi Aware suspend for pairing #\(token): discovery stopped")
        return token
    }

    /// Call only after the pairing controls disappear, so there is a single owner of the service.
    public func resumeAfterPairing(token: Int) {
        let requested = lock.withLock { () -> (Bool, Bool)? in
            guard token == pairingGeneration, pairingSuspended else { return nil }
            pairingSuspended = false
            return (advertisingRequested, browsingRequested)
        }
        guard let requested else {
            Trace.log("Wi-Fi Aware resume after pairing #\(token): ignored (not the current owner)")
            return
        }
        Trace.log("Wi-Fi Aware resume after pairing #\(token): advertise=\(requested.0) browse=\(requested.1)")
        if requested.0 { startAdvertising(discoveryInfo: [:]) }
        if requested.1 { startBrowserIfRequested() }
    }

    /// Replacement discovery must not start while a cancelled listener/browser/connection is still
    /// unwinding: the service allows one publisher and one subscriber per device. Tasks stay in the
    /// list until awaited, so any number of waiters see the same barrier. A discovery task awaits
    /// only the predecessors captured when it was created (tasks that already existed), so the
    /// dependencies are acyclic: no task ever awaits itself or a task created after it.
    private func awaitRetiringTasks() async {
        let snapshot = lock.withLock { retiringTasks }
        await awaitTasks(snapshot)
    }

    private func awaitTasks(_ tasks: [Task<Void, Never>]) async {
        for task in tasks { await task.value }
        lock.withLock { retiringTasks.removeAll { tasks.contains($0) } }
    }

    /// After a failure, give the radio a moment before publishing again (2 s plus a little jitter).
    private func backOffAfterFailure() async {
        guard let since = lock.withLock({ lastFailureAt }).map({ Date().timeIntervalSince($0) }), since < 2 else { return }
        let wait = (2 - since) + Double.random(in: 0...0.5)
        Trace.log("Wi-Fi Aware listener backing off \(String(format: "%.1f", wait)) s after a failure")
        try? await Task.sleep(for: .seconds(wait))
    }

    private func describe(_ error: Error) -> String {
        if let nw = error as? NWError, let wa = nw.wifiAware { return "\(nw) [\(wa)]" }
        return error.localizedDescription
    }

    /// The peer a DevicePicker selection will show up as once the browser rediscovers it. Picker
    /// endpoints are for pairing; data connections only use endpoints the browser returned.
    public func peer(forSelected endpoint: WAEndpoint) -> Peer {
        let peer = peer(for: endpoint)
        Trace.log("Wi-Fi Aware picker selected \(peer.displayName) (\(peer.id)); waiting for the browser to find it")
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
            let predecessors = retiringTasks
            listenerTask = Task { [weak self] in
                guard let self else { return }
                await self.runListener(service: service, id: id, after: predecessors)
            }
        }
    }

    public func stopAdvertising() {
        lock.withLock {
            advertisingRequested = false
            // The listener owns accepted connections. Stopping discovery after .connected must not
            // cancel the active remote. The session gate rejects all further incoming connections.
            guard session.current == nil else { return }
            if listenerTask != nil { Trace.log("Wi-Fi Aware listener stopping (advertising off)") }
            listenerID = nil
            retire(listenerTask)
            listenerTask = nil
        }
    }

    /// Call under the lock: cancels a discovery task and remembers it until a replacement has awaited it.
    private func retire(_ task: Task<Void, Never>?) {
        guard let task else { return }
        task.cancel()
        retiringTasks.append(task)
    }

    private func runListener(service: WAPublishableService, id: UUID, after predecessors: [Task<Void, Never>]) async {
        await awaitTasks(predecessors)
        await backOffAfterFailure()
        guard !Task.isCancelled, lock.withLock({ listenerID == id }) else {
            Trace.log("Wi-Fi Aware listener superseded before it started")
            return
        }
        var waitedForPairing = false
        while !Task.isCancelled {
            do {
                guard try await hasPairedDevice() else {
                    if !waitedForPairing { Trace.log("Wi-Fi Aware listener waiting: no paired devices yet") }
                    waitedForPairing = true
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
                let listener = try NetworkListener(
                    for: .wifiAware(.connecting(to: service, from: .allPairedDevices))
                ) { Coder(WAFrame.self, using: .json) { TCP() } }
                .onStateUpdate { [weak self] _, state in
                    if case .failed(let error) = state, let self {
                        // Record the failure here: the accepted session may end "cleanly" from the
                        // listener's cancellation, and the next listener must still back off.
                        self.lock.withLock { self.lastFailureAt = Date() }
                        Trace.log("Wi-Fi Aware listener state: failed \(self.describe(error))")
                    } else {
                        Trace.log("Wi-Fi Aware listener state: \(String(describing: state))")
                    }
                }
                let paired = await Self.pairedDeviceSummary()
                Trace.log("Wi-Fi Aware listener starting (paired devices: \(paired))")
                try await listener.run { [weak self] connection in
                    guard let self, !Task.isCancelled else { return }
                    let peer = Peer(id: connection.id, displayName: "Remote")
                    let sessionID = UUID()
                    let accepted = self.lock.withLock {
                        self.listenerID == id && !self.pairingSuspended &&
                        self.session.begin(id: sessionID, peer: peer)
                    }
                    Trace.log("Wi-Fi Aware incoming connection \(sessionID): \(accepted ? "accepted" : "refused (busy or suspended)")")
                    guard accepted else { return }
                    await self.receive(connection: connection, sessionID: sessionID, timeout: 30)
                }
                Trace.log("Wi-Fi Aware listener run ended without error")
            } catch {
                guard !Task.isCancelled, lock.withLock({ listenerID == id }) else {
                    Trace.log("Wi-Fi Aware listener stopped: \(Task.isCancelled ? "cancelled" : "superseded")")
                    return
                }
                reportDiscoveryError(error)
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        Trace.log("Wi-Fi Aware listener stopped: cancelled")
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
            let predecessors = retiringTasks
            browserTask = Task { [weak self] in
                guard let self else { return }
                await self.runBrowser(service: service, id: id, after: predecessors)
            }
        }
    }

    public func stopBrowsing() {
        lock.withLock {
            browsingRequested = false
            if browserTask != nil { Trace.log("Wi-Fi Aware browser stopping") }
            browserID = nil
            retire(browserTask)
            browserTask = nil
        }
        clearDiscovered()
    }

    private func runBrowser(service: WASubscribableService, id: UUID, after predecessors: [Task<Void, Never>]) async {
        await awaitTasks(predecessors)
        guard !Task.isCancelled, lock.withLock({ browserID == id }) else {
            Trace.log("Wi-Fi Aware browser superseded before it started")
            return
        }
        var waitedForPairing = false
        while !Task.isCancelled {
            do {
                guard try await hasPairedDevice() else {
                    if !waitedForPairing { Trace.log("Wi-Fi Aware browser waiting: no paired devices yet") }
                    waitedForPairing = true
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
                let browser = NetworkBrowser(for: .wifiAware(.connecting(to: .allPairedDevices, from: service)))
                    .onStateUpdate { [weak self] _, state in
                        if case .failed(let error) = state, let self {
                            Trace.log("Wi-Fi Aware browser state: failed \(self.describe(error))")
                        } else {
                            Trace.log("Wi-Fi Aware browser state: \(String(describing: state))")
                        }
                    }
                let paired = await Self.pairedDeviceSummary()
                Trace.log("Wi-Fi Aware browser starting (paired devices: \(paired))")
                try await browser.run { [weak self] endpoints in
                    Trace.log("Wi-Fi Aware browser found: \(endpoints.map { "\($0.device.name ?? "?") (\($0.device.id))" }.joined(separator: ", "))")
                    self?.updateDiscovered(endpoints, browserID: id)
                }
                Trace.log("Wi-Fi Aware browser run ended without error")
            } catch {
                guard !Task.isCancelled, lock.withLock({ browserID == id }) else {
                    Trace.log("Wi-Fi Aware browser stopped: \(Task.isCancelled ? "cancelled" : "superseded")")
                    return
                }
                clearDiscovered()
                reportDiscoveryError(error)
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        Trace.log("Wi-Fi Aware browser stopped: cancelled")
    }

    private func hasPairedDevice() async throws -> Bool {
        try await WAPairedDevice.allDevices.current()?.isEmpty == false
    }

    private static func pairedDeviceSummary() async -> String {
        guard let devices = try? await WAPairedDevice.allDevices.current(), !devices.isEmpty else { return "none" }
        return devices.values.map { "\($0.name ?? $0.pairingInfo?.pairingName ?? "?") (\($0.id))" }.joined(separator: ", ")
    }

    private func reportDiscoveryError(_ error: Error) {
        log.error("Wi-Fi Aware discovery: \(error.localizedDescription, privacy: .public)")
        Trace.log("Wi-Fi Aware discovery error: \(describe(error))")
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
        }
    }

    // MARK: Connection ownership

    public func invite(_ peer: Peer, context: Data?, timeout: TimeInterval) {
        lock.withLock {
            guard !pairingSuspended, let endpoint = endpointsByPeerID[peer.id] else {
                Trace.log("Wi-Fi Aware invite refused: \(peer.displayName) is not in the browser's current results")
                // Models wait for .disconnected to leave their connecting state.
                continuation.yield(.disconnected(peer))
                continuation.yield(.failure("That camera is no longer available. Keep Camera open on it and try again."))
                return
            }
            let id = UUID()
            guard session.begin(id: id, peer: peer) else { return }
            Trace.log("Wi-Fi Aware connecting \(id) to \(peer.displayName) via \(endpoint)")
            continuation.yield(.connecting(peer))
            let previousBrowser = browserTask
            browserID = nil
            browserTask = nil
            previousBrowser?.cancel()
            if let previousBrowser { retiringTasks.append(previousBrowser) }
            for discovered in endpointsByPeerID.values { continuation.yield(.peerLost(self.peer(for: discovered))) }
            endpointsByPeerID.removeAll()
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
            if case .failed(let error) = state {
                Trace.log("Wi-Fi Aware connection \(id): failed \(self.describe(error))")
            } else {
                Trace.log("Wi-Fi Aware connection \(id): \(String(describing: state))")
            }
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
                self.finishSession(id: id, error: self.describe(error))
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
        // The readiness check and the teardown happen under one lock acquisition, so a `.ready`
        // that lands in between cannot be torn down by its own timeout.
        finishSession(id: id, onlyIfUnready: true, error: "Connection timed out. Keep both apps open, turn on Wi-Fi, and try again.")
    }

    private func finishSession(id: UUID, onlyIfUnready: Bool = false, error: String? = nil) {
        let shouldResumeBrowsing = lock.withLock { () -> Bool in
            let wasReady = session.current?.isReady == true
            if onlyIfUnready, session.current?.id == id, wasReady { return false }
            guard let peer = session.finish(id: id) else { return false }
            if error != nil { lastFailureAt = Date() }
            connection = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            // Both possible owners of the connection join the barrier: the next browser or listener
            // awaits them, so the service is free before it is used again.
            retire(connectionTask)
            connectionTask = nil
            // Cancelling the listener also closes its accepted connection. The next listener awaits
            // this one (retiringTasks) so the service is free before it publishes again.
            listenerID = nil
            retire(listenerTask)
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
