import Foundation
import Testing
@testable import PairAndShootCore

@Suite struct MessageCodecTests {
    let codec = MessageCodec()

    @Test func roundTripsEveryCommand() throws {
        let commands: [RemoteCommand] = [
            .hello(HelloInfo(appVersion: "2.0", displayName: "Remote")),
            .capturePhoto(sendBack: true, delay: 3),
            .startRecording(sendBack: false, delay: 0),
            .stopRecording, .cancelCountdown,
            .setMode(.video), .setPosition(.front), .setFlash(.auto), .ping,
        ]
        for command in commands {
            let decoded = try codec.decode(try codec.encode(.command(command)))
            #expect(decoded == .command(command))
        }
    }

    @Test func roundTripsEveryEvent() throws {
        let result = CaptureResult(kind: .photo, byteCount: 1234, willSendFile: true, fileName: "IMG_1.heic",
                                   thumbnailJPEG: Data([0xFF, 0xD8]), capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let events: [CameraEvent] = [
            .hello(HelloInfo(appVersion: "2.0", displayName: "Camera", capabilities: CameraCapabilities(hasFlash: true, hasFrontCamera: true, canRecordVideo: true))),
            .state(CameraState(mode: .video, position: .front, flash: .on, isRecording: true, recordingDuration: 12.5, countdown: 2, isBusy: true, keepsCopies: false)),
            .captureFinished(result),
            .captureFailed(reason: "nope"), .rejected(reason: "version"), .pong,
        ]
        for event in events {
            let decoded = try codec.decode(try codec.encode(.event(event)))
            #expect(decoded == .event(event))
        }
    }

    @Test func rejectsOtherVersions() throws {
        var envelope = Envelope(message: .command(.ping))
        envelope.version = WireProtocol.version + 1
        let data = try JSONEncoder().encode(envelope)
        #expect(throws: MessageCodecError.unsupportedVersion(WireProtocol.version + 1)) {
            try codec.decode(data)
        }
    }

    @Test func rejectsGarbage() {
        #expect(throws: MessageCodecError.malformed) {
            try codec.decode(Data("not json".utf8))
        }
        #expect(throws: MessageCodecError.malformed) {
            try codec.decode(Data("{\"version\":1,\"message\":{\"command\":{\"teleport\":{}}}}".utf8))
        }
    }

    @Test func bonjourServicesMatchTheServiceType() {
        #expect(WireProtocol.bonjourServices == ["_pairandshoot._tcp", "_pairandshoot._udp"])
        #expect(WireProtocol.serviceType.count <= 15)
    }
}
