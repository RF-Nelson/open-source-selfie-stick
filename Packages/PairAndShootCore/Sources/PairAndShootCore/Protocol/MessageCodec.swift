import Foundation

public enum MessageCodecError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case malformed
}

/// JSON on the wire. Multipeer delivers whole messages, so no framing is needed.
public struct MessageCodec: Sendable {
    public init() {}

    public func encode(_ message: Message) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(Envelope(message: message))
    }

    public func decode(_ data: Data) throws -> Message {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        // Read the version first so a peer running a different app version gets a clear answer
        // instead of a decoding failure on a case it has never heard of.
        struct VersionOnly: Decodable { let version: Int }
        guard let header = try? decoder.decode(VersionOnly.self, from: data) else {
            throw MessageCodecError.malformed
        }
        guard header.version == WireProtocol.version else {
            throw MessageCodecError.unsupportedVersion(header.version)
        }
        do {
            return try decoder.decode(Envelope.self, from: data).message
        } catch {
            throw MessageCodecError.malformed
        }
    }
}
