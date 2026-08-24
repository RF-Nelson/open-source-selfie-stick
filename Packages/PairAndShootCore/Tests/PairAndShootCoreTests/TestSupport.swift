import Foundation
import Testing
@testable import PairAndShootCore

/// Polls a condition on the main actor until it holds or the timeout passes.
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// Like `waitUntil` but returns the produced value once it is non-nil.
@MainActor
func waitUntilValue<T>(timeout: Duration = .seconds(3), _ produce: @MainActor () -> T?) async -> T? {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if let value = produce() { return value }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return produce()
}

/// Stands in for `Task.sleep`. In passthrough mode every sleep returns almost immediately;
/// in gated mode sleeps suspend until `releaseAll()` and honour task cancellation.
final class FakeSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
    private var _requested: [Duration] = []
    private var _passthrough = true

    var requested: [Duration] { lock.withLock { _requested } }
    var pendingCount: Int { lock.withLock { waiters.count } }
    var passthrough: Bool {
        get { lock.withLock { _passthrough } }
        set { lock.withLock { _passthrough = newValue } }
    }

    func sleep(_ duration: Duration) async throws {
        lock.withLock { _requested.append(duration) }
        if passthrough {
            try await Task.sleep(for: .milliseconds(1))
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                lock.withLock { waiters.append((id, continuation)) }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index).continuation
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    func releaseAll() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            let all = waiters.map(\.continuation)
            waiters = []
            return all
        }
        for continuation in released { continuation.resume() }
    }
}

final class FakeMediaStore: MediaStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _photos: [Data] = []
    private var _videos: [URL] = []
    private var _videoExistedWhenSaved: [Bool] = []
    private var _error: (any Error)?

    var photos: [Data] { lock.withLock { _photos } }
    var videos: [URL] { lock.withLock { _videos } }
    var videoExistedWhenSaved: [Bool] { lock.withLock { _videoExistedWhenSaved } }

    func fail(with error: (any Error)?) { lock.withLock { _error = error } }

    func savePhoto(data: Data, fileExtension: String) async throws {
        if let error = lock.withLock({ _error }) { throw error }
        lock.withLock { _photos.append(data) }
    }

    func saveVideo(fileURL: URL) async throws {
        if let error = lock.withLock({ _error }) { throw error }
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        lock.withLock {
            _videos.append(fileURL)
            _videoExistedWhenSaved.append(exists)
        }
    }
}

/// Collects the answers a model gives to invitations.
final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Bool] = []
    var values: [Bool] { lock.withLock { _values } }
    func record(_ value: Bool) { lock.withLock { _values.append(value) } }
}

extension FakeTransport {
    var decodedMessages: [Message] {
        sentMessages.compactMap { try? MessageCodec().decode($0.data) }
    }

    var sentCommands: [RemoteCommand] {
        decodedMessages.compactMap {
            if case .command(let command) = $0 { return command }
            return nil
        }
    }

    var sentEvents: [CameraEvent] {
        decodedMessages.compactMap {
            if case .event(let event) = $0 { return event }
            return nil
        }
    }

    var lastCaptureResult: CaptureResult? {
        sentEvents.compactMap {
            if case .captureFinished(let result) = $0 { return result }
            return nil
        }.last
    }

    var sentChallengeNonce: String? {
        sentEvents.compactMap {
            if case .challenge(let nonce) = $0 { return nonce }
            return nil
        }.last
    }

    var didSendHello: Bool {
        sentEvents.contains {
            if case .hello = $0 { return true }
            return false
        }
    }

    var sentPairSubmission: PairingSubmission? {
        sentCommands.compactMap {
            if case .pair(let submission) = $0 { return submission }
            return nil
        }.last
    }

    var sentStates: [CameraState] {
        sentEvents.compactMap {
            if case .state(let state) = $0 { return state }
            return nil
        }
    }
}

func encodedCommand(_ command: RemoteCommand) throws -> Data {
    try MessageCodec().encode(.command(command))
}

func encodedEvent(_ event: CameraEvent) throws -> Data {
    try MessageCodec().encode(.event(event))
}

func aCamera(id: String = "cam") -> Peer {
    Peer(id: id, displayName: "iPhone · A7", discoveryInfo: Pairing.advertisingInfo())
}
