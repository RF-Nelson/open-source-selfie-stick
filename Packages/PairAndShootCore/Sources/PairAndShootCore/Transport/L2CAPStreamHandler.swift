import CoreBluetooth
import Foundation

/// Drives one open `CBL2CAPChannel` as a length-prefixed message pipe. The channel gives us a pair of
/// Foundation streams that deliver raw bytes, so we frame outgoing payloads with `MessageFraming` and
/// reassemble incoming ones with `MessageDeframer` — exactly like the Wi-Fi Aware / Network.framework
/// path, which also speaks bytes rather than whole messages.
///
/// Both streams are scheduled on the main run loop; Bluetooth's data rates here (commands, camera
/// state, the odd small thumbnail) are far too low for main-thread I/O to matter, and it keeps the
/// threading model trivial — every callback lands where the transport's Core Bluetooth delegates do.
final class L2CAPStreamHandler: NSObject, StreamDelegate {
    // Retain the channel: it owns the socket file descriptor behind the streams. If it deallocates the
    // fd closes and every stream read/write fails with "Bad file descriptor", so keeping the streams
    // alone is not enough — the whole channel must outlive the connection.
    private let channel: CBL2CAPChannel
    private let input: InputStream
    private let output: OutputStream
    private var deframer = MessageDeframer()
    private var outbox = Data()
    private var closed = false

    private let onMessage: (Data) -> Void
    private let onClose: (Error?) -> Void
    /// One-shot, fired the next time the outgoing buffer fully drains. Used to time a file send and
    /// report it finished only once every byte has left our buffer.
    var onDrained: (() -> Void)?

    init(channel: CBL2CAPChannel, onMessage: @escaping (Data) -> Void, onClose: @escaping (Error?) -> Void) {
        self.channel = channel
        self.input = channel.inputStream
        self.output = channel.outputStream
        self.onMessage = onMessage
        self.onClose = onClose
        super.init()
        input.delegate = self
        output.delegate = self
        input.schedule(in: .main, forMode: .default)
        output.schedule(in: .main, forMode: .default)
        input.open()
        output.open()
    }

    /// Frames `payload` and sends it, buffering whatever the stream can't take right now.
    func send(_ payload: Data) {
        guard !closed else { return }
        outbox.append(MessageFraming.frame(payload))
        flush()
    }

    func close() {
        guard !closed else { return }
        closed = true
        input.close()
        output.close()
        input.remove(from: .main, forMode: .default)
        output.remove(from: .main, forMode: .default)
    }

    // MARK: StreamDelegate

    func stream(_ stream: Stream, handle event: Stream.Event) {
        switch event {
        case .hasBytesAvailable:
            readAvailable()
        case .hasSpaceAvailable:
            flush()
        case .endEncountered:
            fail(nil)
        case .errorOccurred:
            fail(stream.streamError)
        default:
            break
        }
    }

    private func flush() {
        guard !closed else { return }
        let hadData = !outbox.isEmpty
        while !outbox.isEmpty, output.hasSpaceAvailable {
            let written = outbox.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return output.write(base, maxLength: outbox.count)
            }
            if written > 0 {
                outbox.removeSubrange(0..<written)
            } else {
                break
            }
        }
        if hadData, outbox.isEmpty, let drained = onDrained {
            onDrained = nil
            drained()
        }
    }

    private func readAvailable() {
        guard !closed else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        while input.hasBytesAvailable {
            let count = input.read(&chunk, maxLength: chunk.count)
            guard count > 0 else { break }
            do {
                for payload in try deframer.append(Data(chunk[0..<count])) {
                    onMessage(payload)
                }
            } catch {
                fail(error)
                return
            }
        }
    }

    private func fail(_ error: Error?) {
        guard !closed else { return }
        close()
        onClose(error)
    }
}
