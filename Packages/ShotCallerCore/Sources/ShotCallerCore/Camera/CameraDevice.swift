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
        case .permissionDenied(let what):
            switch what {
            case "photo library": "Allow Photos access in Settings to save captures on this device."
            case "microphone": "Allow microphone access in Settings to record video with sound."
            default: "Allow camera access in Settings to use this device as a camera."
            }
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
    /// An interruption or system limit stopped recording, and its completed file can be collected.
    func recordingHasFinished() async -> Bool
    /// The recording in progress has no audio track because the microphone isn't allowed.
    func isRecordingWithoutSound() async -> Bool
    /// Live view: whether this device can produce small frames of the current scene.
    var supportsPreviewFrames: Bool { get }
    /// Attach (or detach) the frame tap. Enabled only while a remote holds a live-view subscription,
    /// so an idle camera never pays for it. Idempotent.
    func setPreviewFramesEnabled(_ enabled: Bool) async throws
    /// The next frame of the scene as an upright JPEG no longer than `maxEdge` on its long side and no
    /// larger than `maxBytes`; nil when none arrives in time or none fits. Called once per request.
    func previewFrame(maxEdge: Int, maxBytes: Int) async -> PreviewFrame?
}

public extension CameraDevice {
    func recordingHasFinished() async -> Bool { false }
    func isRecordingWithoutSound() async -> Bool { false }
    var supportsPreviewFrames: Bool { false }
    func setPreviewFramesEnabled(_ enabled: Bool) async throws {}
    func previewFrame(maxEdge: Int, maxBytes: Int) async -> PreviewFrame? { nil }
}

/// Produces the small JPEG previews that travel inside `CaptureResult`, and re-encodes photos smaller
/// for a fast Bluetooth transfer.
public protocol ThumbnailMaker: Sendable {
    func thumbnail(forPhoto data: Data) async -> Data?
    func thumbnail(forVideoAt url: URL) async -> Data?
    /// Re-encode a photo smaller for a quicker transfer. `quality == .full` (or an unsupported case)
    /// returns nil, meaning "send the original".
    func compressedPhoto(data: Data, quality: TransferQuality) async -> Data?
}

public extension ThumbnailMaker {
    func compressedPhoto(data: Data, quality: TransferQuality) async -> Data? { nil }
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
    private var _microphoneDenied = false
    private var _previewFramesEnabled = false
    private var _previewFramesServed = 0
    private var _previewFrameBytes = 1024
    private var _previewEnableError: CameraDeviceError?
    private var _previewEnableDelay: Duration = .zero

    public init(capabilities: CameraCapabilities = CameraCapabilities(hasFlash: true, hasFrontCamera: true, canRecordVideo: true)) {
        _capabilities = capabilities
    }

    public var appliedSettings: CameraSettings { lock.withLock { _settings } }
    public var photoCount: Int { lock.withLock { _photoCount } }
    public var isRecording: Bool { lock.withLock { _isRecording } }

    public func failStart(with error: CameraDeviceError?) { lock.withLock { _startError = error } }
    public func failCapture(with error: CameraDeviceError?) { lock.withLock { _captureError = error } }
    public func denyMicrophone(_ denied: Bool = true) { lock.withLock { _microphoneDenied = denied } }

    // Live view: the fake supports frames when its capabilities say so, and reports what was asked.
    public var supportsPreviewFrames: Bool { lock.withLock { _capabilities.canStreamPreview } }
    public var previewFramesEnabled: Bool { lock.withLock { _previewFramesEnabled } }
    public var previewFramesServed: Int { lock.withLock { _previewFramesServed } }
    /// Size of the fake JPEG the next frames carry; larger than `maxBytes` makes the frame "not fit".
    public func setPreviewFrameBytes(_ count: Int) { lock.withLock { _previewFrameBytes = count } }
    public func failPreviewEnable(with error: CameraDeviceError?) { lock.withLock { _previewEnableError = error } }
    /// Makes enabling/disabling the tap take a while, as a session reconfiguration does.
    public func setPreviewEnableDelay(_ delay: Duration) { lock.withLock { _previewEnableDelay = delay } }

    public func setPreviewFramesEnabled(_ enabled: Bool) async throws {
        if enabled, let error = lock.withLock({ _previewEnableError }) { throw error }
        let delay = lock.withLock { _previewEnableDelay }
        if delay > .zero { try? await Task.sleep(for: delay) }
        lock.withLock { _previewFramesEnabled = enabled }
    }

    public func previewFrame(maxEdge: Int, maxBytes: Int) async -> PreviewFrame? {
        let (enabled, bytes) = lock.withLock { () -> (Bool, Int) in
            guard _previewFramesEnabled else { return (false, 0) }
            _previewFramesServed += 1
            return (true, _previewFrameBytes)
        }
        guard enabled, bytes <= maxBytes else { return nil }
        // Shaped like a JPEG (SOI … EOI) so a remote's validation accepts it.
        let body = Data(repeating: 0xAB, count: max(0, bytes - 4))
        return PreviewFrame(jpeg: Data([0xFF, 0xD8]) + body + Data([0xFF, 0xD9]), width: maxEdge, height: maxEdge * 3 / 4)
    }

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

    public func isRecordingWithoutSound() async -> Bool {
        lock.withLock { _isRecording && _microphoneDenied }
    }
}
