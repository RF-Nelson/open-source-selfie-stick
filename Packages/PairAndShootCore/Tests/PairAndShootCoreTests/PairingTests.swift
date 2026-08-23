import Foundation
import Testing
@testable import PairAndShootCore

@Suite struct PairingTests {
    let challenge = PairingChallenge(nonce: "0123456789abcdef")

    @Test func randomCodesAreFourDigits() {
        for _ in 0..<50 {
            let code = PairingCode.random()
            #expect(code.digits.count == 4)
            #expect(code.digits.allSatisfy { $0.isNumber })
        }
    }

    @Test func parsesTypedCodes() {
        #expect(PairingCode("4821")?.digits == "4821")
        #expect(PairingCode("48 21")?.digits == "4821")
        #expect(PairingCode("0007")?.digits == "0007")
        #expect(PairingCode("482") == nil)
        #expect(PairingCode("48211") == nil)
        #expect(PairingCode("48a1") == nil)
        #expect(PairingCode("") == nil)
    }

    @Test func proofVerifiesWithMatchingCode() {
        let code = PairingCode("4821")!
        let proof = Pairing.proof(code: code, challenge: challenge, remoteName: "Rich's iPhone")
        #expect(Pairing.verify(context: proof, code: code, challenge: challenge) == .accepted(remoteName: "Rich's iPhone"))
    }

    @Test func proofFailsWithWrongCode() {
        let proof = Pairing.proof(code: PairingCode("4821")!, challenge: challenge, remoteName: "Remote")
        #expect(Pairing.verify(context: proof, code: PairingCode("4822")!, challenge: challenge) == .rejected(.wrongCode))
    }

    @Test func proofFailsAgainstAnotherSession() {
        let code = PairingCode("4821")!
        let proof = Pairing.proof(code: code, challenge: challenge, remoteName: "Remote")
        #expect(Pairing.verify(context: proof, code: code, challenge: PairingChallenge(nonce: "fedcba9876543210")) == .rejected(.wrongCode))
    }

    @Test func proofIsBoundToTheRemoteName() throws {
        let code = PairingCode("4821")!
        var proof = try JSONDecoder().decode(Pairing.Proof.self, from: Pairing.proof(code: code, challenge: challenge, remoteName: "Remote"))
        proof.name = "Impostor"
        let tampered = try JSONEncoder().encode(proof)
        #expect(Pairing.verify(context: tampered, code: code, challenge: challenge) == .rejected(.wrongCode))
    }

    @Test func rejectsMissingAndMalformedContext() {
        let code = PairingCode("4821")!
        #expect(Pairing.verify(context: nil, code: code, challenge: challenge) == .rejected(.missingContext))
        #expect(Pairing.verify(context: Data("junk".utf8), code: code, challenge: challenge) == .rejected(.malformedContext))
    }

    @Test func discoveryInfoRoundTrips() {
        let info = Pairing.discoveryInfo(for: challenge)
        #expect(Pairing.challenge(from: info) == challenge)
        #expect(Pairing.challenge(from: nil) == nil)
        #expect(Pairing.challenge(from: ["app": "other", "v": "1", "n": "x"]) == nil)
        #expect(Pairing.challenge(from: ["app": Pairing.appTag, "v": "99", "n": "x"]) == nil)
    }

    @Test func challengesAreUnique() {
        let nonces = Set((0..<20).map { _ in PairingChallenge.random().nonce })
        #expect(nonces.count == 20)
        #expect(nonces.allSatisfy { $0.count == 32 })
    }
}
