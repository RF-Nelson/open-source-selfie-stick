import Foundation

/// Limits both roles agree on for the live view. The remote asks within them, the camera clamps to
/// them, and the wire format refuses anything larger.
public enum PreviewLimits {
    /// Longest edge of a preview frame, in pixels.
    public static let maxEdge = 480
    public static let minEdge = 160
    /// Frames per second the remote may request; it never has more than one request in flight.
    public static let maxFPS = 5
    /// Largest JPEG the camera may send for one frame (the negotiated cap; see `PreviewPacket.maxPayload`).
    public static let maxBytes = 32 * 1024
    public static let minBytes = 8 * 1024
    /// Under moderate thermal pressure the camera shrinks frames to this edge.
    public static let degradedEdge = 320
    /// Shown by both roles when only Bluetooth is up: the preview never rides the Bluetooth lane.
    public static let needsWiFiMessage = "Live view and automatic photo delivery need a shared Wi-Fi network. Over Bluetooth you can still take photos and videos, and download each one when you want it."
}

/// What the remote asks for when it wants a live view. The camera clamps to `PreviewLimits`.
public struct PreviewRequest: Codable, Sendable, Hashable {
    /// Lets the remote match `previewStarted` / `previewRefused` to the request it is waiting for and
    /// discard answers to one it gave up on.
    public var requestID: UUID
    public var maxEdge: Int
    public var maxFPS: Int
    public var maxBytes: Int

    public init(requestID: UUID = UUID(), maxEdge: Int = PreviewLimits.maxEdge, maxFPS: Int = PreviewLimits.maxFPS, maxBytes: Int = PreviewLimits.maxBytes) {
        self.requestID = requestID
        self.maxEdge = maxEdge
        self.maxFPS = maxFPS
        self.maxBytes = maxBytes
    }
}

/// An accepted live-view subscription: the camera's clamped terms plus an id that every frame request
/// and frame carries, so frames from a previous session or connection can never be shown.
public struct PreviewSubscription: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// The `PreviewRequest.requestID` this subscription answers.
    public var requestID: UUID
    public var maxEdge: Int
    public var fps: Int
    public var maxBytes: Int

    public init(id: UUID = UUID(), requestID: UUID = UUID(), maxEdge: Int, fps: Int, maxBytes: Int) {
        self.id = id
        self.requestID = requestID
        self.maxEdge = maxEdge
        self.fps = fps
        self.maxBytes = maxBytes
    }
}

/// One live-view frame: an upright JPEG (rotation already applied by the camera) and its pixel size.
public struct PreviewFrame: Sendable, Hashable {
    public let jpeg: Data
    public let width: Int
    public let height: Int
    public let timestamp: Date

    public init(jpeg: Data, width: Int, height: Int, timestamp: Date = Date()) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.timestamp = timestamp
    }
}

/// The binary packets of the live view. They travel on the transport's preview channel (the Wi-Fi
/// fast lane only), never inside the JSON protocol: a 30 KB JPEG has no business in base64.
///
/// Layout (big-endian): `version u8 · kind u8 · subscription uuid[16] · sequence u32`, then per kind:
/// frame `width u16 · height u16 · length u32 · jpeg[length]`; skipped `reason u8`; request nothing.
/// The remote sends one `frameRequest` at a time and waits for its `frame` or `skipped` before the
/// next, so nothing ever queues behind a slow receiver.
public enum PreviewPacket: Hashable, Sendable {
    case frameRequest(subscription: UUID, sequence: UInt32)
    case frame(subscription: UUID, sequence: UInt32, width: UInt16, height: UInt16, jpeg: Data)
    case skipped(subscription: UUID, sequence: UInt32, reason: SkipReason)

    public enum SkipReason: UInt8, Sendable, Hashable {
        /// The camera had no frame within its deadline (it may be mid-capture or interrupted).
        case noFrame = 1
        /// A full-resolution file is transferring; the preview yields to it.
        case transferring = 2
        /// The device is hot; the preview pauses to protect capture.
        case thermal = 3
    }

    public enum DecodeError: Error, Equatable, Sendable {
        case truncated
        case unknownVersion(UInt8)
        case unknownKind(UInt8)
        case unknownReason(UInt8)
        case payloadTooLarge(Int)
        case badDimensions
    }

    public static let formatVersion: UInt8 = 1
    /// Hard ceiling on a frame payload, independent of the negotiated `maxBytes`: a peer that sends
    /// more is malformed, and the receiver never allocates for it.
    public static let maxPayload = 256 * 1024
    private static let headerLength = 22

    private enum Kind: UInt8 { case frameRequest = 1, frame = 2, skipped = 3 }

    public var subscription: UUID {
        switch self {
        case .frameRequest(let id, _), .frame(let id, _, _, _, _), .skipped(let id, _, _): id
        }
    }

    public var sequence: UInt32 {
        switch self {
        case .frameRequest(_, let sequence), .frame(_, let sequence, _, _, _), .skipped(_, let sequence, _): sequence
        }
    }

    public func encoded() -> Data {
        var out = Data()
        out.reserveCapacity(Self.headerLength + 8)
        out.append(Self.formatVersion)
        switch self {
        case .frameRequest(let id, let sequence):
            out.append(Kind.frameRequest.rawValue)
            Self.append(id, to: &out)
            Self.append(sequence, to: &out)
        case .frame(let id, let sequence, let width, let height, let jpeg):
            out.append(Kind.frame.rawValue)
            Self.append(id, to: &out)
            Self.append(sequence, to: &out)
            Self.append(width, to: &out)
            Self.append(height, to: &out)
            Self.append(UInt32(jpeg.count), to: &out)
            out.append(jpeg)
        case .skipped(let id, let sequence, let reason):
            out.append(Kind.skipped.rawValue)
            Self.append(id, to: &out)
            Self.append(sequence, to: &out)
            out.append(reason.rawValue)
        }
        return out
    }

    public static func decode(_ data: Data) throws -> PreviewPacket {
        let bytes = [UInt8](data)
        guard bytes.count >= headerLength else { throw DecodeError.truncated }
        guard bytes[0] == formatVersion else { throw DecodeError.unknownVersion(bytes[0]) }
        guard let kind = Kind(rawValue: bytes[1]) else { throw DecodeError.unknownKind(bytes[1]) }
        let id = uuid(bytes[2..<18])
        let sequence = uint32(bytes[18..<22])
        switch kind {
        case .frameRequest:
            return .frameRequest(subscription: id, sequence: sequence)
        case .skipped:
            guard bytes.count >= headerLength + 1 else { throw DecodeError.truncated }
            guard let reason = SkipReason(rawValue: bytes[22]) else { throw DecodeError.unknownReason(bytes[22]) }
            return .skipped(subscription: id, sequence: sequence, reason: reason)
        case .frame:
            guard bytes.count >= headerLength + 8 else { throw DecodeError.truncated }
            let width = uint16(bytes[22..<24])
            let height = uint16(bytes[24..<26])
            guard width > 0, height > 0 else { throw DecodeError.badDimensions }
            let length = Int(uint32(bytes[26..<30]))
            guard length <= maxPayload else { throw DecodeError.payloadTooLarge(length) }
            guard bytes.count == headerLength + 8 + length else { throw DecodeError.truncated }
            let jpeg = data.subdata(in: (headerLength + 8)..<(headerLength + 8 + length))
            return .frame(subscription: id, sequence: sequence, width: width, height: height, jpeg: jpeg)
        }
    }

    private static func append(_ id: UUID, to out: inout Data) {
        let u = id.uuid
        out.append(contentsOf: [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15])
    }

    private static func append(_ value: UInt32, to out: inout Data) {
        out.append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    private static func append(_ value: UInt16, to out: inout Data) {
        out.append(contentsOf: [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    private static func uuid(_ slice: ArraySlice<UInt8>) -> UUID {
        let b = Array(slice)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    private static func uint32(_ slice: ArraySlice<UInt8>) -> UInt32 {
        slice.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func uint16(_ slice: ArraySlice<UInt8>) -> UInt16 {
        slice.reduce(0) { ($0 << 8) | UInt16($1) }
    }
}
