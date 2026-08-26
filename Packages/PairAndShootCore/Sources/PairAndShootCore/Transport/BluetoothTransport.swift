import CoreBluetooth
import Foundation
import os

/// Fixed Core Bluetooth identifiers for Pair & Shoot. The camera side advertises `serviceUUID` and
/// exposes the L2CAP PSM to connect on through `psmCharacteristicUUID` (the PSM is assigned per publish,
/// so it can't live in the advertisement — the central reads it after connecting, then opens L2CAP).
enum BLEIdentifiers {
    // CBUUID is immutable in practice but not marked Sendable, so annotate these shared constants
    // nonisolated(unsafe) rather than recompute them on every access.
    nonisolated(unsafe) static let serviceUUID = CBUUID(string: "8F2A7A01-4B7E-4C3A-9E21-9C7D2F5A6B10")
    nonisolated(unsafe) static let psmCharacteristicUUID = CBUUID(string: "8F2A7A02-4B7E-4C3A-9E21-9C7D2F5A6B10")
}

/// A Bluetooth-only transport: Core Bluetooth for discovery/connection and an L2CAP channel for the
/// message stream. It carries everything the app sends as a message (commands, camera state, the
/// pairing handshake, the small post-shot thumbnail) but declines file transfers — full-resolution
/// photos/videos are too large for BLE, so `supportsFileTransfer` is false and the layered transport
/// routes those over Wi-Fi when it's available.
///
/// The camera is the peripheral (advertises); the remote is the central (scans and connects). The link
/// is unauthenticated at the BLE layer — the app-level 4-digit code (run over this stream after
/// connecting, `requiresAppLevelPairing == true`) is what gates access, matching Multipeer.
public final class BluetoothTransport: NSObject, PeerTransport, @unchecked Sendable {
    public let localPeer: Peer
    public let events: AsyncStream<TransportEvent>
    // BLE can carry files — just slowly, chunked over the L2CAP stream. The layered transport prefers
    // Wi-Fi for these when it's up; on a Bluetooth-only link they still arrive.
    public var supportsFileTransfer: Bool { true }

    /// One incoming file being reassembled from chunks.
    private struct IncomingFile {
        let handle: FileHandle
        let url: URL
        let name: String
        let size: Int
        var received: Int
        let startedAt: Date
    }

    /// First byte of every L2CAP frame's payload: separates control messages from file transfer, which
    /// share the one stream.
    private enum FrameTag: UInt8 { case message = 0, fileBegin = 1, fileChunk = 2, fileEnd = 3, fileCancel = 4 }

    private struct FileHeader: Codable { let name: String; let size: Int }

    private static let fileChunkBytes = 16 * 1024

    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let lock = NSLock()
    private let displayName: String
    private let log = Logger(subsystem: "com.richardnelson.opensourceselfiestick", category: "ble")

    // Peripheral (camera) side.
    private var peripheralManager: CBPeripheralManager?
    private var wantsAdvertising = false
    private var publishedPSM: CBL2CAPPSM?
    private var didAddService = false

    // Central (remote) side.
    private var centralManager: CBCentralManager?
    private var wantsScanning = false
    private var peripheralsByID: [String: CBPeripheral] = [:]
    private var connectingPeripheral: CBPeripheral?

    // Shared open connection.
    private var streamHandler: L2CAPStreamHandler?
    private var connectedPeer: Peer?
    private let inboxDirectory: URL
    private var incomingFile: IncomingFile?

    /// The file being streamed out right now, produced chunk by chunk so only ~one chunk is buffered.
    private struct FileSend { let data: Data; var offset: Int; let name: String; let startedAt: Date }
    private var fileSend: FileSend?

    public init(displayName: String) {
        self.displayName = BluetoothTransport.trimmedName(displayName)
        localPeer = Peer(id: "local", displayName: self.displayName)
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
        inboxDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PairAndShootBLEInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
        super.init()
    }

    deinit {
        streamHandler?.close()
        peripheralManager?.stopAdvertising()
        centralManager?.stopScan()
        continuation.finish()
    }

    /// The BLE advertisement local name is short; keep it readable and bounded.
    static func trimmedName(_ name: String) -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "Camera" }
        return String(cleaned.prefix(24))
    }

    // MARK: PeerTransport

    public var connectedPeers: [Peer] {
        lock.withLock { connectedPeer.map { [$0] } ?? [] }
    }

    public func startAdvertising(discoveryInfo: [String: String]) {
        lock.withLock { wantsAdvertising = true }
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        } else {
            startAdvertisingIfReady()
        }
        Trace.log("ble: advertising as \(displayName)")
    }

    public func stopAdvertising() {
        // Stop being discoverable, but never tear down a live channel: like the Wi-Fi Aware fix, the
        // camera calls this the moment a remote connects, and killing the connection here would drop it.
        lock.withLock { wantsAdvertising = false }
        peripheralManager?.stopAdvertising()
    }

    public func startBrowsing() {
        lock.withLock { wantsScanning = true }
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        } else {
            startScanningIfReady()
        }
        Trace.log("ble: scanning for cameras")
    }

    public func stopBrowsing() {
        lock.withLock { wantsScanning = false }
        centralManager?.stopScan()
    }

    public func invite(_ peer: Peer, context: Data?, timeout: TimeInterval) {
        guard let peripheral = lock.withLock({ peripheralsByID[peer.id] }), let central = centralManager else {
            continuation.yield(.failure("That camera is no longer in range."))
            return
        }
        lock.withLock { connectingPeripheral = peripheral }
        Trace.log("ble: connecting to \(peer.displayName)")
        continuation.yield(.connecting(peer))
        central.connect(peripheral, options: nil)
    }

    public func send(_ data: Data, to peers: [Peer]) throws {
        let handler = lock.withLock { streamHandler }
        guard let handler else { throw TransportError.notConnected }
        handler.send(tagged(.message, data))
    }

    public func sendFile(at url: URL, named name: String, to peer: Peer) {
        let handler = lock.withLock { streamHandler }
        guard let handler else {
            continuation.yield(.fileSendFinished(name: name, error: "Not connected."))
            return
        }
        guard lock.withLock({ fileSend == nil }) else {
            Trace.log("ble: sendFile ignored — a transfer is already in flight")
            return
        }
        guard let data = try? Data(contentsOf: url),
              let header = try? JSONEncoder().encode(FileHeader(name: name, size: data.count)) else {
            continuation.yield(.fileSendFinished(name: name, error: "Couldn't read the file to send."))
            return
        }
        let startedAt = Date()
        Trace.log("ble: sending file \(name) — \(data.count) bytes")
        lock.withLock { fileSend = FileSend(data: data, offset: 0, name: name, startedAt: startedAt) }
        handler.nextChunk = { [weak self] in self?.produceNextChunk() }
        // Report finished only once our buffer has fully flushed to the Bluetooth stack.
        handler.onDrained = { [weak self] in
            guard let self else { return }
            let seconds = Date().timeIntervalSince(startedAt)
            let kbps = seconds > 0 ? Double(data.count) / 1024.0 / seconds : 0
            Trace.log("ble: file \(name) flushed \(data.count) bytes in \(Int(seconds * 1000)) ms (\(Int(kbps)) KB/s local)")
            self.lock.withLock { self.streamHandler?.nextChunk = nil }
            self.continuation.yield(.fileSendProgress(name: name, fraction: 1))
            self.continuation.yield(.fileSendFinished(name: name, error: nil))
        }
        continuation.yield(.fileSendProgress(name: name, fraction: 0))
        handler.send(tagged(.fileBegin, header))   // kicks the flush loop, which pulls chunks on demand
    }

    /// Produce the next outgoing frame for the streaming file send (a chunk, then one terminator).
    private func produceNextChunk() -> Data? {
        lock.withLock {
            guard var send = fileSend else { return nil }
            if send.offset < send.data.count {
                let end = min(send.offset + Self.fileChunkBytes, send.data.count)
                let chunk = send.data.subdata(in: send.offset..<end)
                send.offset = end
                fileSend = send
                return tagged(.fileChunk, chunk)
            }
            fileSend = nil   // all chunks sent — emit the terminator once, then nil next time
            return tagged(.fileEnd, Data())
        }
    }

    private func tagged(_ tag: FrameTag, _ body: Data) -> Data {
        var payload = Data([tag.rawValue])
        payload.append(body)
        return payload
    }

    public func cancelFileSend() {
        let handler = lock.withLock { () -> L2CAPStreamHandler? in
            fileSend = nil                 // stop producing further chunks
            let handler = streamHandler
            handler?.nextChunk = nil
            handler?.onDrained = nil       // don't report the aborted send as finished
            return handler
        }
        // The partial chunk already buffered completes on a frame boundary; then the receiver gets a
        // clean cancel and discards its partial file. No mid-frame corruption.
        handler?.send(tagged(.fileCancel, Data()))
    }

    public func disconnect() {
        let (peripheral, central, peripheralManager) = lock.withLock {
            (connectingPeripheral ?? peripheralForConnectedPeer(), centralManager, self.peripheralManager)
        }
        tearDownConnection(notify: false)
        if let peripheral, let central { central.cancelPeripheralConnection(peripheral) }
        central?.stopScan()
        peripheralManager?.stopAdvertising()
    }

    // MARK: Connection lifecycle

    private func peripheralForConnectedPeer() -> CBPeripheral? {
        guard let id = connectedPeer?.id else { return nil }
        return peripheralsByID[id]
    }

    /// Wire up an opened L2CAP channel as the active connection and announce it.
    private func adopt(channel: CBL2CAPChannel, peer: Peer) {
        let alreadyConnected = lock.withLock { connectedPeer != nil }
        guard !alreadyConnected else {
            // One remote at a time; drop the newcomer's channel.
            channel.inputStream.close()
            channel.outputStream.close()
            return
        }
        let handler = L2CAPStreamHandler(
            channel: channel,
            onMessage: { [weak self] payload in self?.handleIncoming(payload, from: peer) },
            onClose: { [weak self] error in self?.handleClose(error) }
        )
        lock.withLock {
            streamHandler = handler
            connectedPeer = peer
        }
        Trace.log("ble: L2CAP open — connected to \(peer.displayName)")
        continuation.yield(.connected(peer))
    }

    private func handleClose(_ error: Error?) {
        Trace.log("ble: channel closed\(error.map { " (\($0.localizedDescription))" } ?? "")")
        tearDownConnection(notify: true)
    }

    /// Route one deframed L2CAP payload by its leading tag byte. Runs on the main run loop (where the
    /// streams are scheduled), so `incomingFile` is single-threaded and needs no lock.
    private func handleIncoming(_ payload: Data, from peer: Peer) {
        guard let first = payload.first, let tag = FrameTag(rawValue: first) else { return }
        let body = Data(payload.dropFirst())
        switch tag {
        case .message:
            continuation.yield(.message(body, from: peer))
        case .fileBegin:
            guard let header = try? JSONDecoder().decode(FileHeader.self, from: body) else { return }
            let safeName = header.name.replacingOccurrences(of: "/", with: "_")
            let url = inboxDirectory.appendingPathComponent(UUID().uuidString + "-" + safeName)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: url) else {
                continuation.yield(.fileReceiveFailed(name: header.name, error: "Couldn't open a file to receive."))
                return
            }
            incomingFile = IncomingFile(handle: handle, url: url, name: header.name, size: header.size, received: 0, startedAt: Date())
            Trace.log("ble: receiving file \(header.name) — \(header.size) bytes")
            continuation.yield(.fileReceiveStarted(name: header.name, from: peer))
        case .fileChunk:
            guard var file = incomingFile else { return }
            try? file.handle.write(contentsOf: body)
            file.received += body.count
            incomingFile = file
            let fraction = file.size > 0 ? Double(file.received) / Double(file.size) : 0
            continuation.yield(.fileReceiveProgress(name: file.name, fraction: fraction))
        case .fileEnd:
            guard let file = incomingFile else { return }
            try? file.handle.close()
            incomingFile = nil
            let seconds = Date().timeIntervalSince(file.startedAt)
            let kbps = seconds > 0 ? Double(file.received) / 1024.0 / seconds : 0
            Trace.log("ble: file \(file.name) received \(file.received) bytes in \(Int(seconds * 1000)) ms (\(Int(kbps)) KB/s)")
            continuation.yield(.fileReceived(name: file.name, url: file.url, from: peer))
        case .fileCancel:
            guard let file = incomingFile else { return }
            try? file.handle.close()
            try? FileManager.default.removeItem(at: file.url)
            incomingFile = nil
            Trace.log("ble: file \(file.name) cancelled by sender")
            continuation.yield(.fileReceiveFailed(name: file.name, error: "Cancelled"))
        }
    }

    private func tearDownConnection(notify: Bool) {
        if let file = incomingFile {
            try? file.handle.close()
            incomingFile = nil
        }
        let peer = lock.withLock { () -> Peer? in
            streamHandler?.close()
            streamHandler = nil
            fileSend = nil
            let peer = connectedPeer
            connectedPeer = nil
            connectingPeripheral = nil
            return peer
        }
        if notify, let peer { continuation.yield(.disconnected(peer)) }
    }

    // MARK: Peripheral (camera) helpers

    private func startAdvertisingIfReady() {
        guard let manager = peripheralManager, manager.state == .poweredOn else { return }
        let advertise = lock.withLock { wantsAdvertising }
        guard advertise else { return }
        if lock.withLock({ publishedPSM == nil }) {
            manager.publishL2CAPChannel(withEncryption: false)
            return
        }
        guard didAddService else { return }
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BLEIdentifiers.serviceUUID],
            CBAdvertisementDataLocalNameKey: displayName
        ])
    }

    // MARK: Central (remote) helpers

    private func startScanningIfReady() {
        guard let manager = centralManager, manager.state == .poweredOn else { return }
        let scan = lock.withLock { wantsScanning }
        guard scan else { return }
        manager.scanForPeripherals(withServices: [BLEIdentifiers.serviceUUID], options: nil)
    }
}

// MARK: - Peripheral (camera) side

extension BluetoothTransport: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            startAdvertisingIfReady()
        } else {
            Trace.log("ble: peripheral state \(peripheral.state.rawValue)")
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        if let error {
            Trace.log("ble: didPublishL2CAPChannel error: \(error.localizedDescription)")
            continuation.yield(.failure("Bluetooth couldn't start: \(error.localizedDescription)"))
            return
        }
        lock.withLock { publishedPSM = PSM }
        var value = PSM.bigEndian
        let psmData = Data(bytes: &value, count: MemoryLayout<CBL2CAPPSM>.size)
        let characteristic = CBMutableCharacteristic(type: BLEIdentifiers.psmCharacteristicUUID,
                                                     properties: [.read], value: psmData, permissions: [.readable])
        let service = CBMutableService(type: BLEIdentifiers.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        peripheral.add(service)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            Trace.log("ble: didAdd service error: \(error.localizedDescription)")
            return
        }
        lock.withLock { didAddService = true }
        startAdvertisingIfReady()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == BLEIdentifiers.psmCharacteristicUUID,
              let psm = lock.withLock({ publishedPSM }) else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        var value = psm.bigEndian
        request.value = Data(bytes: &value, count: MemoryLayout<CBL2CAPPSM>.size)
        peripheral.respond(to: request, withResult: .success)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel, error == nil else {
            Trace.log("ble: peripheral didOpen error: \(error?.localizedDescription ?? "no channel")")
            return
        }
        let peer = Peer(id: channel.peer.identifier.uuidString, displayName: "Remote")
        adopt(channel: channel, peer: peer)
    }
}

// MARK: - Central (remote) side

extension BluetoothTransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startScanningIfReady()
        } else {
            Trace.log("ble: central state \(central.state.rawValue)")
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier.uuidString
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Camera"
        lock.withLock { peripheralsByID[id] = peripheral }
        Trace.log("ble: found camera \(name)")
        continuation.yield(.peerFound(Peer(id: id, displayName: name)))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([BLEIdentifiers.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Trace.log("ble: didFailToConnect: \(error?.localizedDescription ?? "unknown")")
        continuation.yield(.failure("Couldn't connect to that camera."))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Trace.log("ble: peripheral disconnected\(error.map { " (\($0.localizedDescription))" } ?? "")")
        tearDownConnection(notify: true)
    }
}

extension BluetoothTransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == BLEIdentifiers.serviceUUID }) else {
            continuation.yield(.failure("That camera isn't running Pair & Shoot."))
            return
        }
        peripheral.discoverCharacteristics([BLEIdentifiers.psmCharacteristicUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == BLEIdentifiers.psmCharacteristicUUID }) else {
            continuation.yield(.failure("That camera isn't running Pair & Shoot."))
            return
        }
        peripheral.readValue(for: characteristic)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == BLEIdentifiers.psmCharacteristicUUID,
              let data = characteristic.value, data.count == MemoryLayout<CBL2CAPPSM>.size else { return }
        let psm = data.reduce(CBL2CAPPSM(0)) { ($0 << 8) | CBL2CAPPSM($1) }
        peripheral.openL2CAPChannel(psm)
    }

    public func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel, error == nil else {
            Trace.log("ble: central didOpen error: \(error?.localizedDescription ?? "no channel")")
            continuation.yield(.failure("Couldn't open the Bluetooth link."))
            return
        }
        let id = peripheral.identifier.uuidString
        let name = lock.withLock { peripheralsByID[id] }?.name ?? "Camera"
        adopt(channel: channel, peer: Peer(id: id, displayName: name))
    }
}
