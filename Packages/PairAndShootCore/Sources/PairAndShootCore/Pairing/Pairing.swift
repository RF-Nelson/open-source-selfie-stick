import CryptoKit
import Foundation

/// The short code the camera shows on its screen and the remote's user types in.
///
/// Threat model: the goal is to keep a random nearby person running this app from driving
/// someone else's camera. The proof below binds the code to a per-session challenge and to the
/// remote's name, the camera allows one remote at a time, and it issues a fresh code after
/// `CameraHostModel.maxFailedAttempts` wrong guesses. It is not designed to resist an attacker
/// sniffing the local network with custom Multipeer tooling; the session itself is encrypted.
public struct PairingCode: Hashable, Sendable {
    public static let length = 4
    public let digits: String

    public init?(_ text: String) {
        let digits = text.filter { $0.isASCII && $0.isNumber }
        guard digits.count == Self.length, digits.count == text.filter({ !$0.isWhitespace }).count else { return nil }
        self.digits = digits
    }

    public static func random() -> PairingCode {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    public static func random(using generator: inout some RandomNumberGenerator) -> PairingCode {
        let number = Int.random(in: 0..<10_000, using: &generator)
        return PairingCode(String(format: "%04d", number))!
    }
}

/// A random value the camera advertises for each pairing session. The remote's proof is bound to it,
/// so a proof captured once cannot be replayed against a later session.
public struct PairingChallenge: Hashable, Sendable {
    public let nonce: String

    public init(nonce: String) {
        self.nonce = nonce
    }

    public static func random() -> PairingChallenge {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max)
        }
        return PairingChallenge(nonce: bytes.map { String(format: "%02x", $0) }.joined())
    }
}

public enum PairingRejection: String, Sendable, Hashable {
    case missingContext, malformedContext, unsupportedVersion, wrongCode
}

public enum PairingVerification: Sendable, Hashable {
    case accepted(remoteName: String)
    case rejected(PairingRejection)
}

public enum Pairing {
    public static let appTag = "pairandshoot"

    enum Keys {
        static let app = "app"
        static let version = "v"
        static let nonce = "n"
    }

    /// What the camera advertises. Small and non-secret; the security handshake happens over the
    /// encrypted data channel after connecting, so this may be dropped (e.g. over Bluetooth) without
    /// breaking pairing — it only helps the remote recognise a compatible camera.
    public static func advertisingInfo() -> [String: String] {
        [Keys.app: appTag, Keys.version: String(WireProtocol.version)]
    }

    /// Whether a discovered peer looks like a compatible camera. Tolerant of missing info, because
    /// Bluetooth discovery does not always deliver it and the peer is on our service type regardless.
    public static func isCompatibleCamera(_ discoveryInfo: [String: String]?) -> Bool {
        guard let info = discoveryInfo else { return true }
        if let app = info[Keys.app], app != appTag { return false }
        if let version = info[Keys.version], version != String(WireProtocol.version) { return false }
        return true
    }

    struct Proof: Codable {
        var v: Int
        var name: String
        var mac: Data
    }

    /// The invitation context the remote sends. The camera verifies it before accepting the session.
    public static func proof(code: PairingCode, challenge: PairingChallenge, remoteName: String) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: message(challenge, remoteName), using: key(for: code))
        let proof = Proof(v: WireProtocol.version, name: remoteName, mac: Data(mac))
        return (try? JSONEncoder().encode(proof)) ?? Data()
    }

    public static func verify(context: Data?, code: PairingCode, challenge: PairingChallenge) -> PairingVerification {
        guard let context else { return .rejected(.missingContext) }
        guard let proof = try? JSONDecoder().decode(Proof.self, from: context) else { return .rejected(.malformedContext) }
        guard proof.v == WireProtocol.version else { return .rejected(.unsupportedVersion) }
        let valid = HMAC<SHA256>.isValidAuthenticationCode(proof.mac, authenticating: message(challenge, proof.name), using: key(for: code))
        guard valid else { return .rejected(.wrongCode) }
        return .accepted(remoteName: proof.name)
    }

    private static func key(for code: PairingCode) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data(code.digits.utf8)))
    }

    private static func message(_ challenge: PairingChallenge, _ remoteName: String) -> Data {
        Data("\(appTag)/\(WireProtocol.version)\n\(challenge.nonce)\n\(remoteName)".utf8)
    }
}
