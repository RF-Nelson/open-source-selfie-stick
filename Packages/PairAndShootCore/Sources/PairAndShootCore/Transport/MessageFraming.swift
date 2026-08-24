import Foundation

/// Length-prefixed framing for a byte stream (e.g. an `NWConnection`), which — unlike
/// MultipeerConnectivity — delivers bytes, not whole messages. Each frame is a 4-byte big-endian
/// unsigned length followed by that many payload bytes.
///
/// Used by stream-based transports (Wi-Fi Aware / Network.framework). MultipeerTransport does not
/// need it because Multipeer preserves message boundaries.
public enum MessageFraming {
    /// The largest single frame we will send or accept, to bound memory against a bad/hostile peer.
    public static let maxFrameBytes = 64 * 1024 * 1024   // 64 MB

    public static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var out = Data(capacity: payload.count + 4)
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}

public enum MessageDeframerError: Error, Equatable, Sendable {
    case frameTooLarge(Int)
}

/// Accumulates incoming bytes and yields complete payloads as their frames arrive. Not thread-safe;
/// feed it from a single consumer (the transport's receive loop).
public struct MessageDeframer {
    private var buffer = Data()

    public init() {}

    /// Appends received bytes and returns every complete payload now available (possibly none, or
    /// several if multiple frames arrived together). Throws if a frame's declared length exceeds the
    /// limit — the caller should treat that as a protocol violation and drop the connection.
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var messages: [Data] = []
        while true {
            guard buffer.count >= 4 else { break }
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let total = Int(length) + 4
            if Int(length) > MessageFraming.maxFrameBytes {
                throw MessageDeframerError.frameTooLarge(Int(length))
            }
            guard buffer.count >= total else { break }
            messages.append(buffer.subdata(in: 4..<total))
            buffer.removeSubrange(0..<total)
        }
        return messages
    }

    /// Bytes buffered but not yet a complete frame (for diagnostics/tests).
    public var pendingByteCount: Int { buffer.count }
}
