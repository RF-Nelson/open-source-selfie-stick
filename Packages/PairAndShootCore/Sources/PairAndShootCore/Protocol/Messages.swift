import Foundation

/// Facts about the wire protocol that both roles must agree on.
public enum WireProtocol {
    /// Bump when a change breaks older peers. Peers with a different version refuse to talk.
    public static let version = 1
    /// Bonjour service type used for discovery: 1–15 characters, lowercase letters, digits, hyphens.
    public static let serviceType = "pairandshoot"
    /// The entries the app must declare under `NSBonjourServices` in Info.plist.
    public static var bonjourServices: [String] { ["_\(serviceType)._tcp", "_\(serviceType)._udp"] }
}

public enum CaptureMode: String, Codable, Sendable, CaseIterable, Hashable {
    case photo, video
}

public enum CameraPosition: String, Codable, Sendable, CaseIterable, Hashable {
    case back, front
    public var toggled: CameraPosition { self == .back ? .front : .back }
}

public enum FlashMode: String, Codable, Sendable, CaseIterable, Hashable {
    case off, auto, on
    public var next: FlashMode {
        switch self {
        case .off: .auto
        case .auto: .on
        case .on: .off
        }
    }
}

public struct CameraCapabilities: Codable, Sendable, Hashable {
    public var hasFlash: Bool
    public var hasFrontCamera: Bool
    public var canRecordVideo: Bool

    public init(hasFlash: Bool = false, hasFrontCamera: Bool = false, canRecordVideo: Bool = false) {
        self.hasFlash = hasFlash
        self.hasFrontCamera = hasFrontCamera
        self.canRecordVideo = canRecordVideo
    }
}

/// First message each side sends after connecting.
public struct HelloInfo: Codable, Sendable, Hashable {
    public var protocolVersion: Int
    public var appVersion: String
    public var displayName: String
    /// Sent by the camera only.
    public var capabilities: CameraCapabilities?

    public init(protocolVersion: Int = WireProtocol.version, appVersion: String, displayName: String, capabilities: CameraCapabilities? = nil) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.displayName = displayName
        self.capabilities = capabilities
    }
}

/// Full snapshot of what the camera is doing. The camera sends it whenever anything changes;
/// the remote renders from it and never guesses.
public struct CameraState: Codable, Sendable, Hashable {
    public var mode: CaptureMode
    public var position: CameraPosition
    public var flash: FlashMode
    public var isRecording: Bool
    public var recordingDuration: TimeInterval
    /// Seconds left in a delayed capture, or nil when no countdown is running.
    public var countdown: Int?
    /// A capture is in flight (shutter pressed, file not yet written).
    public var isBusy: Bool
    /// The camera keeps its own copy of every capture.
    public var keepsCopies: Bool

    public init(mode: CaptureMode = .photo, position: CameraPosition = .back, flash: FlashMode = .off,
                isRecording: Bool = false, recordingDuration: TimeInterval = 0, countdown: Int? = nil,
                isBusy: Bool = false, keepsCopies: Bool = true) {
        self.mode = mode
        self.position = position
        self.flash = flash
        self.isRecording = isRecording
        self.recordingDuration = recordingDuration
        self.countdown = countdown
        self.isBusy = isBusy
        self.keepsCopies = keepsCopies
    }
}

public enum CaptureKind: String, Codable, Sendable, Hashable {
    case photo, video
}

/// What the camera reports after a capture. Small enough to travel as a message; the file itself
/// (if the remote asked for it) travels separately as a resource transfer with the same `fileName`.
public struct CaptureResult: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: CaptureKind
    public var byteCount: Int
    public var willSendFile: Bool
    public var fileName: String?
    public var duration: TimeInterval?
    /// A small JPEG preview so the remote can show what was just shot even when it declined the file.
    public var thumbnailJPEG: Data?
    public var capturedAt: Date

    public init(id: UUID = UUID(), kind: CaptureKind, byteCount: Int, willSendFile: Bool, fileName: String? = nil,
                duration: TimeInterval? = nil, thumbnailJPEG: Data? = nil, capturedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.byteCount = byteCount
        self.willSendFile = willSendFile
        self.fileName = fileName
        self.duration = duration
        self.thumbnailJPEG = thumbnailJPEG
        self.capturedAt = capturedAt
    }
}

/// Remote → camera.
public enum RemoteCommand: Codable, Sendable, Hashable {
    case hello(HelloInfo)
    case capturePhoto(sendBack: Bool, delay: Int)
    case startRecording(sendBack: Bool, delay: Int)
    case stopRecording
    case cancelCountdown
    case setMode(CaptureMode)
    case setPosition(CameraPosition)
    case setFlash(FlashMode)
    case ping
}

/// Camera → remote.
public enum CameraEvent: Codable, Sendable, Hashable {
    case hello(HelloInfo)
    case state(CameraState)
    case captureFinished(CaptureResult)
    case captureFailed(reason: String)
    case rejected(reason: String)
    case pong
}

public enum Message: Codable, Sendable, Hashable {
    case command(RemoteCommand)
    case event(CameraEvent)
}

public struct Envelope: Codable, Sendable, Hashable {
    public var version: Int
    public var message: Message

    public init(version: Int = WireProtocol.version, message: Message) {
        self.version = version
        self.message = message
    }
}
