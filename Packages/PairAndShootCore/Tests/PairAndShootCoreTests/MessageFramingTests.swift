import Foundation
import Testing
@testable import PairAndShootCore

@Suite struct MessageFramingTests {
    @Test func framesRoundTripWhenDeliveredWhole() throws {
        var deframer = MessageDeframer()
        let payload = Data("hello world".utf8)
        let out = try deframer.append(MessageFraming.frame(payload))
        #expect(out == [payload])
        #expect(deframer.pendingByteCount == 0)
    }

    @Test func reassemblesAcrossArbitraryChunkBoundaries() throws {
        let payloads = [Data("one".utf8), Data("a slightly longer message".utf8), Data([0x00, 0xFF, 0x10])]
        var stream = Data()
        for p in payloads { stream.append(MessageFraming.frame(p)) }

        var deframer = MessageDeframer()
        var got: [Data] = []
        // Feed one byte at a time — the worst case for a stream defragmenter.
        for byte in stream {
            got += try deframer.append(Data([byte]))
        }
        #expect(got == payloads)
    }

    @Test func deliversMultipleFramesArrivingTogether() throws {
        var deframer = MessageDeframer()
        let a = Data("first".utf8), b = Data("second".utf8)
        let combined = MessageFraming.frame(a) + MessageFraming.frame(b)
        #expect(try deframer.append(combined) == [a, b])
    }

    @Test func handlesEmptyPayload() throws {
        var deframer = MessageDeframer()
        #expect(try deframer.append(MessageFraming.frame(Data())) == [Data()])
    }

    @Test func rejectsAnOversizedFrame() {
        var deframer = MessageDeframer()
        var huge = UInt32(MessageFraming.maxFrameBytes + 1).bigEndian
        var frame = Data()
        withUnsafeBytes(of: &huge) { frame.append(contentsOf: $0) }
        #expect(throws: MessageDeframerError.frameTooLarge(MessageFraming.maxFrameBytes + 1)) {
            _ = try deframer.append(frame)
        }
    }

    @Test func encodesLengthBigEndian() {
        let framed = MessageFraming.frame(Data([0xAB, 0xCD]))
        #expect(Array(framed.prefix(4)) == [0x00, 0x00, 0x00, 0x02])
    }
}
