#if os(iOS)
import Foundation
import Network
import WiFiAware
import os

/// Transport-level frame carried over the Wi-Fi Aware data channel. App messages are opaque encoded
/// envelopes; files travel as a begin/chunk/end sequence. JSON-coded, so base64 for the byte fields —
/// fine over fast Wi-Fi Aware for a first version; a binary framer can replace it later.
enum WAFrame: Codable, Sendable {
    case message(Data)
    case fileBegin(id: String, name: String, size: Int)
    case fileChunk(id: String, data: Data)
    case fileEnd(id: String)
}

/// Wi-Fi Aware implementation of `PeerTransport` (iOS 26+). Devices are paired at the system level,
/// so there is no app-level code handshake here (`requiresAppLevelPairing == false`); a connection is
/// treated as an established pairing.
///
/// This transport handles one peer at a time, matching the app's model. Peer discovery, connection,
/// framed messaging and chunked file transfer run over the new Swift `Network` API with a
/// `Coder<WAFrame, WAFrame, .json>` protocol on top of TCP.
@available(iOS 26.0, *)
public final class WiFiAwareTransport: PeerTransport, @unchecked Sendable {
    typealias AppProtocol = Coder<WAFrame, WAFrame, NetworkJSONCoder>

    public let localPeer: Peer
    public let events: AsyncStream<TransportEvent>
    public var requiresAppLevelPairing: Bool { false }

    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let serviceName: String
    private let lock = NSLock()
    private let log = Logger(subsystem: "com.richardnelson.opensourceselfiestick", category: "wifiaware")

    private var listenerTask: Task<Void, Never>?
    private var browserTask: Task<Void, Never>?
    private var connection: NetworkConnection<AppProtocol>?
    private var connectedPeer: Peer?
    private var endpointsByPeerID: [String: WAEndpoint] = [:]
    private var incomingFiles: [String: (handle: FileHandle, url: URL, name: String, size: Int, received: Int)] = [:]
    private let inboxDirectory: URL

    /// Whether Wi-Fi Aware is usable on this device.
    public static var isSupported: Bool {
        if #available(iOS 26.0, *) {
            return WACapabilities.supportedFeatures.contains(.wifiAware)
        }
        return false
    }

    public init(displayName: String, serviceName: String = "_\(WireProtocol.serviceType)._udp") {
        self.serviceName = serviceName
        localPeer = Peer(id: "local", displayName: displayName)
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
        inboxDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PairAndShootWAInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
    }

    deinit {
        listenerTask?.cancel()
        browserTask?.cancel()
        continuation.finish()
    }

    public var connectedPeers: [Peer] {
        lock.withLock { connectedPeer.map { [$0] } ?? [] }
    }

    // MARK: Publisher (camera)

    public func startAdvertising(discoveryInfo: [String: String]) {
        guard let service = WAPublishableService.allServices[serviceName] else {
            continuation.yield(.failure("Wi-Fi Aware service “\(serviceName)” isn’t declared. Check WiFiAwareServices in Info.plist."))
            return
        }
        guard listenerTask == nil else { return }
        listenerTask = Task { [weak self] in
            await self?.runListener(service: service)
        }
    }

    public func stopAdvertising() {
        listenerTask?.cancel()
        listenerTask = nil
    }

    private func runListener(service: WAPublishableService) async {
        do {
            let listener = try NetworkListener(
                for: .wifiAware(.connecting(to: service, from: .allPairedDevices))
            ) {
                Coder(WAFrame.self, using: .json) { TCP() }
            }
            log.notice("wifi-aware listener starting for \(self.serviceName, privacy: .public)")
            try await listener.run { [weak self] connection in
                await self?.adopt(connection: connection, peer: nil)
            }
        } catch {
            guard !Task.isCancelled else { return }
            if Self.isNoPairedDevices(error) {
                log.notice("wifi-aware publisher: no paired devices yet — pair a remote first")
            } else {
                log.error("wifi-aware publisher failed: \(error.localizedDescription, privacy: .public)")
                continuation.yield(.failure("Wi-Fi Aware couldn’t start: \(error.localizedDescription)"))
            }
        }
    }

    /// A "no paired devices" error is expected before the user pairs — not something to alarm them with.
    static func isNoPairedDevices(_ error: any Error) -> Bool {
        let wa = (error as? WAError) ?? (error as? NWError)?.wifiAware
        if let wa, case .noPairedDevices = wa { return true }
        return false
    }

    // MARK: Browser (remote)

    public func startBrowsing() {
        guard let service = WASubscribableService.allServices[serviceName] else {
            continuation.yield(.failure("Wi-Fi Aware service “\(serviceName)” isn’t declared. Check WiFiAwareServices in Info.plist."))
            return
        }
        guard browserTask == nil else { return }
        browserTask = Task { [weak self] in
            await self?.runBrowser(service: service)
        }
    }

    public func stopBrowsing() {
        browserTask?.cancel()
        browserTask = nil
    }

    private func runBrowser(service: WASubscribableService) async {
        do {
            let browser = NetworkBrowser(
                for: .wifiAware(.connecting(to: .allPairedDevices, from: service))
            )
            log.notice("wifi-aware browser starting for \(self.serviceName, privacy: .public)")
            try await browser.run { [weak self] endpoints in
                self?.updateDiscovered(endpoints)
            }
        } catch {
            guard !Task.isCancelled else { return }
            if Self.isNoPairedDevices(error) {
                log.notice("wifi-aware browser: no paired cameras yet — pair a camera first")
            } else {
                log.error("wifi-aware browser failed: \(error.localizedDescription, privacy: .public)")
                continuation.yield(.failure("Can’t search for cameras over Wi-Fi Aware: \(error.localizedDescription)"))
            }
        }
    }

    private func updateDiscovered(_ endpoints: [WAEndpoint]) {
        var found: [Peer] = []
        lock.withLock {
            let live = Set(endpoints.map { String($0.device.id) })
            let gone = endpointsByPeerID.keys.filter { !live.contains($0) }
            for id in gone { endpointsByPeerID[id] = nil }
            for endpoint in endpoints {
                let id = String(endpoint.device.id)
                if endpointsByPeerID[id] == nil { found.append(peer(for: endpoint)) }
                endpointsByPeerID[id] = endpoint
            }
        }
        for peer in found { continuation.yield(.peerFound(peer)) }
    }

    // MARK: Connecting (remote → camera)

    public func invite(_ peer: Peer, context: Data?, timeout: TimeInterval) {
        guard let endpoint = lock.withLock({ endpointsByPeerID[peer.id] }) else {
            continuation.yield(.failure("That camera is no longer in range."))
            return
        }
        continuation.yield(.connecting(peer))
        let connection = NetworkConnection(to: endpoint) {
            Coder(WAFrame.self, using: .json) { TCP() }
        }
        Task { [weak self] in
            await self?.adopt(connection: connection, peer: peer)
        }
    }

    // MARK: Connection lifecycle

    private func adopt(connection: NetworkConnection<AppProtocol>, peer knownPeer: Peer?) async {
        let peer = knownPeer ?? Peer(id: connection.id, displayName: "Camera remote")
        lock.withLock {
            self.connection = connection
            self.connectedPeer = peer
        }
        // The devices are already paired at the system level, so treat an adopted connection as
        // connected and drive the receive loop. (State observation can refine this during testing.)
        continuation.yield(.connected(peer))
        do {
            for try await message in connection.messages {
                handle(frame: message.content, from: peer)
            }
            // Stream ended: peer disconnected.
            markDisconnected(peer)
        } catch {
            markDisconnected(peer)
        }
    }

    private func handle(frame: WAFrame, from peer: Peer) {
        switch frame {
        case .message(let data):
            continuation.yield(.message(data, from: peer))
        case .fileBegin(let id, let name, let size):
            beginReceivingFile(id: id, name: name, size: size, from: peer)
        case .fileChunk(let id, let data):
            appendFileChunk(id: id, data: data)
        case .fileEnd(let id):
            finishReceivingFile(id: id, from: peer)
        }
    }

    // MARK: Sending

    public func send(_ data: Data, to peers: [Peer]) throws {
        guard let connection = lock.withLock({ self.connection }) else { throw TransportError.notConnected }
        Task {
            do { try await connection.send(.message(data)) }
            catch { continuation.yield(.failure("Couldn’t send: \(error.localizedDescription)")) }
        }
    }

    public func sendFile(at url: URL, named name: String, to peer: Peer) {
        guard let connection = lock.withLock({ self.connection }) else {
            continuation.yield(.fileSendFinished(name: name, error: "Not connected"))
            return
        }
        Task { [weak self] in
            await self?.streamFile(at: url, named: name, over: connection)
        }
    }

    private func streamFile(at url: URL, named name: String, over connection: NetworkConnection<AppProtocol>) async {
        let id = UUID().uuidString
        let chunkSize = 32 * 1024
        do {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try await connection.send(.fileBegin(id: id, name: name, size: size))
            var sent = 0
            while true {
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                try await connection.send(.fileChunk(id: id, data: chunk))
                sent += chunk.count
                continuation.yield(.fileSendProgress(name: name, fraction: size > 0 ? Double(sent) / Double(size) : 1))
            }
            try await connection.send(.fileEnd(id: id))
            continuation.yield(.fileSendFinished(name: name, error: nil))
        } catch {
            continuation.yield(.fileSendFinished(name: name, error: error.localizedDescription))
        }
    }

    // MARK: Receiving files

    private func beginReceivingFile(id: String, name: String, size: Int, from peer: Peer) {
        let safeName = name.replacingOccurrences(of: "/", with: "_")
        let url = inboxDirectory.appendingPathComponent(UUID().uuidString + "-" + safeName)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            continuation.yield(.fileReceiveFailed(name: name, error: "Couldn’t open a file to receive into."))
            return
        }
        lock.withLock { incomingFiles[id] = (handle, url, name, size, 0) }
        continuation.yield(.fileReceiveStarted(name: name, from: peer))
    }

    private func appendFileChunk(id: String, data: Data) {
        let update: (name: String, fraction: Double)? = lock.withLock {
            guard var file = incomingFiles[id] else { return nil }
            try? file.handle.write(contentsOf: data)
            file.received += data.count
            incomingFiles[id] = file
            return (file.name, file.size > 0 ? Double(file.received) / Double(file.size) : 0)
        }
        if let update { continuation.yield(.fileReceiveProgress(name: update.name, fraction: update.fraction)) }
    }

    private func finishReceivingFile(id: String, from peer: Peer) {
        let file: (url: URL, name: String)? = lock.withLock {
            guard let file = incomingFiles.removeValue(forKey: id) else { return nil }
            try? file.handle.close()
            return (file.url, file.name)
        }
        if let file { continuation.yield(.fileReceived(name: file.name, url: file.url, from: peer)) }
    }

    // MARK: Teardown

    public func disconnect() {
        let peer = lock.withLock { () -> Peer? in
            self.connection = nil
            let peer = connectedPeer
            connectedPeer = nil
            return peer
        }
        if let peer { continuation.yield(.disconnected(peer)) }
    }

    private func markDisconnected(_ peer: Peer) {
        let shouldEmit = lock.withLock { () -> Bool in
            guard connectedPeer?.id == peer.id else { return false }
            connection = nil
            connectedPeer = nil
            return true
        }
        if shouldEmit { continuation.yield(.disconnected(peer)) }
    }

    private func peer(for endpoint: WAEndpoint) -> Peer {
        let device = endpoint.device
        return Peer(id: String(device.id), displayName: device.name ?? device.pairingInfo?.pairingName ?? "Camera")
    }
}
#endif
