import Foundation

public struct CameraSettings: Hashable, Sendable {
    public var mode: CaptureMode
    public var position: CameraPosition
    public var flash: FlashMode

    public init(mode: CaptureMode = .photo, position: CameraPosition = .back, flash: FlashMode = .off) {
        self.mode = mode
        self.position = position
        self.flash = flash
    }
}

public struct CapturedPhoto: Sendable {
    public let data: Data
    /// "heic" or "jpg".
    public let fileExtension: String

    public init(data: Data, fileExtension: String) {
        self.data = data
        self.fileExtension = fileExtension
    }
}

public struct RecordedMovie: Sendable {
    public let url: URL
    public let duration: TimeInterval

    public init(url: URL, duration: TimeInterval) {
        self.url = url
        self.duration = duration
    }
}

public enum CameraDeviceError: Error, Sendable, Equatable, LocalizedError {
    case unavailable
    case permissionDenied(String)
    case busy
    case notRecording
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "No camera is available on this device."
        case .permissionDenied(let what): "Allow access to the \(what) in Settings to use this device as a camera."
        case .busy: "The camera is busy."
        case .notRecording: "Nothing is being recorded."
        case .failed(let reason): reason
        }
    }
}

/// The camera hardware, as the app needs it. `CaptureService` (AVFoundation) is the real one;
/// `FakeCameraDevice` and the simulator's `SimulatedCameraDevice` stand in when there is no camera.
public protocol CameraDevice: AnyObject, Sendable {
    /// Requests permission and starts the preview. Throws when there is no usable camera.
    func start() async throws -> CameraCapabilities
    func stop() async
    func apply(_ settings: CameraSettings) async throws
    func capturePhoto() async throws -> CapturedPhoto
    func startRecording() async throws
    /// Returns a movie file the caller owns.
    func stopRecording() async throws -> RecordedMovie
    func recordingDuration() async -> TimeInterval
}

/// Produces the small JPEG previews that travel inside `CaptureResult`.
public protocol ThumbnailMaker: Sendable {
    func thumbnail(forPhoto data: Data) async -> Data?
    func thumbnail(forVideoAt url: URL) async -> Data?
}

public struct NoThumbnails: ThumbnailMaker {
    public init() {}
    public func thumbnail(forPhoto data: Data) async -> Data? { nil }
    public func thumbnail(forVideoAt url: URL) async -> Data? { nil }
}

/// Where captures end up on a device: the Photos library in the app, a recorder in tests.
/// Implementations copy; the caller stays responsible for deleting the source file.
public protocol MediaStore: Sendable {
    func savePhoto(data: Data, fileExtension: String) async throws
    func saveVideo(fileURL: URL) async throws
}

/// A camera that produces tiny placeholder files instantly. Used by tests and previews.
public final class FakeCameraDevice: CameraDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var _capabilities: CameraCapabilities
    private var _settings = CameraSettings()
    private var _photoCount = 0
    private var _isRecording = false
    private var _recordingStart: Date?
    private var _startError: CameraDeviceError?
    private var _captureError: CameraDeviceError?

    public init(capabilities: CameraCapabilities = CameraCapabilities(hasFlash: true, hasFrontCamera: true, canRecordVideo: true)) {
        _capabilities = capabilities
    }

    public var appliedSettings: CameraSettings { lock.withLock { _settings } }
    public var photoCount: Int { lock.withLock { _photoCount } }
    public var isRecording: Bool { lock.withLock { _isRecording } }

    public func failStart(with error: CameraDeviceError) { lock.withLock { _startError = error } }
    public func failCapture(with error: CameraDeviceError?) { lock.withLock { _captureError = error } }

    public func start() async throws -> CameraCapabilities {
        if let error = lock.withLock({ _startError }) { throw error }
        return lock.withLock { _capabilities }
    }

    public func stop() async {}

    public func apply(_ settings: CameraSettings) async throws {
        lock.withLock { _settings = settings }
    }

    public func capturePhoto() async throws -> CapturedPhoto {
        if let error = lock.withLock({ _captureError }) { throw error }
        let count = lock.withLock { () -> Int in
            _photoCount += 1
            return _photoCount
        }
        return CapturedPhoto(data: Data("fake-photo-\(count)".utf8), fileExtension: "jpg")
    }

    public func startRecording() async throws {
        try lock.withLock {
            guard !_isRecording else { throw CameraDeviceError.busy }
            _isRecording = true
            _recordingStart = Date()
        }
    }

    public func stopRecording() async throws -> RecordedMovie {
        let start = try lock.withLock { () -> Date in
            guard _isRecording, let start = _recordingStart else { throw CameraDeviceError.notRecording }
            _isRecording = false
            _recordingStart = nil
            return start
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).mov")
        try Data("fake-movie".utf8).write(to: url)
        return RecordedMovie(url: url, duration: Date().timeIntervalSince(start))
    }

    public func recordingDuration() async -> TimeInterval {
        lock.withLock { _recordingStart.map { Date().timeIntervalSince($0) } ?? 0 }
    }
}
