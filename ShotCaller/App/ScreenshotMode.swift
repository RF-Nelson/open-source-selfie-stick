#if DEBUG
import Foundation
import Observation
import ShotCallerCore
import SwiftUI
import UIKit

/// Debug-only staging for App Store screenshots in the Simulator, which has no Bluetooth and no
/// camera. Both roles run in one process over a linked `FakeTransport` pair: the role on screen is
/// the real screen, its counterpart is a headless model, and a photo from disk is what the camera
/// "sees" (the live view frames, the viewfinder and the captured photo). The connection, pairing
/// code, hello, live-view subscription, countdown and photo delivery all run through the real
/// models, so the screens show what they would show on two devices. Nothing here compiles into
/// Release. `Tools/screenshots.sh` drives it through environment variables:
///
///   SHOTCALLER_SCREENSHOT            remote-live | remote-countdown | remote-saved | remote-settings | camera-live
///   SHOTCALLER_SCREENSHOT_PHOTO      path to the photo (JPEG, HEIC or PNG) the camera sees
///   SHOTCALLER_SCREENSHOT_NAME       this device's name; SHOTCALLER_SCREENSHOT_PEER the other's
///
/// Orientation is the Simulator's: an iPad app that supports multitasking cannot force its own, so
/// the script rotates the device through the Simulator app before the iPad scenes.
@MainActor
@Observable
final class ScreenshotMode {
    enum Scene: String {
        case remoteLive = "remote-live"
        case remoteCountdown = "remote-countdown"
        case remoteSaved = "remote-saved"
        case remoteSettings = "remote-settings"
        case cameraLive = "camera-live"

        var role: Role {
            switch self {
            case .cameraLive: .camera
            case .remoteLive, .remoteCountdown, .remoteSaved, .remoteSettings: .remote
            }
        }
    }

    static let current: ScreenshotMode? = {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment["SHOTCALLER_SCREENSHOT"], let scene = Scene(rawValue: name) else { return nil }
        return ScreenshotMode(scene: scene, environment: environment)
    }()

    let scene: Scene
    /// The camera the on-screen or headless `CameraHostModel` drives.
    let device: StagedCameraDevice
    /// What the on-screen camera's viewfinder shows in place of the capture session.
    let viewfinder: UIImage?
    /// Set once the staged session is live and the scene wants the remote's settings sheet open.
    private(set) var wantsSettingsSheet = false

    private let cameraTransport: FakeTransport
    private let remoteTransport: FakeTransport
    private var headlessCamera: CameraHostModel?
    private var headlessRemote: RemoteModel?
    private var orchestration: Task<Void, Never>?

    private init(scene: Scene, environment: [String: String]) {
        self.scene = scene
        let image = environment["SHOTCALLER_SCREENSHOT_PHOTO"].flatMap { UIImage(contentsOfFile: $0) }
        device = StagedCameraDevice(image: image)
        viewfinder = image
        let me = environment["SHOTCALLER_SCREENSHOT_NAME"] ?? "This device"
        let peer = environment["SHOTCALLER_SCREENSHOT_PEER"] ?? "Other device"
        let pair = FakeTransport.linkedPair(cameraName: scene.role == .camera ? me : peer,
                                            remoteName: scene.role == .remote ? me : peer)
        cameraTransport = pair.camera
        remoteTransport = pair.remote
        // Both ends have the Wi-Fi lane; `.fileChannelFast(true)` is announced once they are paired.
        cameraTransport.previewChannelAvailable = true
        remoteTransport.previewChannelAvailable = true
        // Skip first-use setup and keep copies on both ends, as a set-up pair of devices would.
        let defaults = UserDefaults.standard
        defaults.set(me, forKey: DeviceIdentity.nicknameKey)
        defaults.set(true, forKey: SessionPreferences.cameraSetup)
        defaults.set(true, forKey: SessionPreferences.remoteSetup)
        defaults.set(true, forKey: SessionPreferences.keepsCopies)
        defaults.set(true, forKey: SessionPreferences.sendsPhotos)
        defaults.set(false, forKey: SessionPreferences.sendsVideos)
        defaults.set(true, forKey: SessionPreferences.livePreview)
        defaults.set(false, forKey: TransportFactory.internalWiFiAwareKey)
    }

    /// The transport the on-screen role uses; the headless counterpart gets the other end.
    func transport(for role: Role) -> any PeerTransport {
        role == .camera ? cameraTransport : remoteTransport
    }

    /// The remote is on screen: run a headless camera, connect to it with its code, open the fast
    /// lane, wait for the live view, then do what the scene asks.
    func run(remote: RemoteModel) {
        guard orchestration == nil else { return }
        orchestration = Task { [self] in
            let camera = CameraHostModel(transport: cameraTransport, device: device, mediaStore: DiscardingMediaStore(),
                                         thumbnails: ImageThumbnailMaker(), appVersion: DeviceIdentity.appVersion)
            camera.keepsCopies = true
            headlessCamera = camera
            await camera.start()
            guard let peer = await wait({ remote.cameras.first }) else { return }
            remote.connect(to: peer, code: camera.pairingCode)
            guard await wait({ remote.connection.isConnected && remote.camera != nil ? true : nil }) != nil else { return }
            await openFastLane()
            guard await wait({ remote.previewFrame }) != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            switch scene {
            case .remoteCountdown:
                remote.timerSeconds = 10
                remote.shutter()
            case .remoteSaved:
                remote.shutter()
            case .remoteSettings:
                wantsSettingsSheet = true
            case .remoteLive, .cameraLive:
                break
            }
        }
    }

    /// The camera is on screen: run a headless remote that connects, opens the fast lane and
    /// subscribes to the live view, so the camera shows its viewfinder and the sharing pill.
    func run(camera: CameraHostModel) {
        guard orchestration == nil else { return }
        orchestration = Task { [self] in
            let remote = RemoteModel(transport: remoteTransport, mediaStore: DiscardingMediaStore(), appVersion: DeviceIdentity.appVersion)
            remote.sendBackPhotos = true
            remote.setPreviewEnabled(true)
            headlessRemote = remote
            remote.start()
            guard let peer = await wait({ remote.cameras.first }) else { return }
            remote.connect(to: peer, code: camera.pairingCode)
            guard await wait({ remote.connection.isConnected && remote.camera != nil ? true : nil }) != nil else { return }
            await openFastLane()
        }
    }

    /// Models the layered transport's Wi-Fi lane coming up: the camera learns first so it accepts the
    /// live-view request the remote sends on hearing the same news.
    private func openFastLane() async {
        cameraTransport.emit(.fileChannelFast(true))
        try? await Task.sleep(for: .milliseconds(200))
        remoteTransport.emit(.fileChannelFast(true))
    }

    private func wait<Value>(timeout: Duration = .seconds(10), _ probe: @MainActor () -> Value?) async -> Value? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let value = probe() { return value }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
}

/// A camera whose scene is one photo from disk: the photo is what it captures, and scaled copies of
/// it are the live-view frames.
final class StagedCameraDevice: CameraDevice, @unchecked Sendable {
    private let upright: UIImage?
    private let photo: Data?

    init(image: UIImage?) {
        upright = image.map { Self.render($0, maxEdge: 2400) }
        photo = upright?.jpegData(compressionQuality: 0.9)
    }

    var supportsPreviewFrames: Bool { true }

    func start() async throws -> CameraCapabilities {
        CameraCapabilities(hasFlash: true, hasFrontCamera: true, canRecordVideo: true, canStreamPreview: true)
    }

    func stop() async {}

    func apply(_ settings: CameraSettings) async throws {}

    func capturePhoto() async throws -> CapturedPhoto {
        guard let photo else { throw CameraDeviceError.failed("No staged photo: set SHOTCALLER_SCREENSHOT_PHOTO.") }
        return CapturedPhoto(data: photo, fileExtension: "jpg")
    }

    func startRecording() async throws {
        throw CameraDeviceError.failed("Recording isn't staged.")
    }

    func stopRecording() async throws -> RecordedMovie {
        throw CameraDeviceError.notRecording
    }

    func recordingDuration() async -> TimeInterval { 0 }

    func setPreviewFramesEnabled(_ enabled: Bool) async throws {}

    func previewFrame(maxEdge: Int, maxBytes: Int) async -> PreviewFrame? {
        guard let upright else { return nil }
        let small = Self.render(upright, maxEdge: CGFloat(maxEdge))
        for quality in [0.6, 0.4, 0.25] as [CGFloat] {
            if let data = small.jpegData(compressionQuality: quality), data.count <= maxBytes {
                return PreviewFrame(jpeg: data, width: Int(small.size.width), height: Int(small.size.height))
            }
        }
        return nil
    }

    /// An upright, 1x copy no longer than `maxEdge` on its long side (EXIF orientation applied).
    private static func render(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let factor = min(1, maxEdge / max(pixels.width, pixels.height))
        let target = CGSize(width: (pixels.width * factor).rounded(.down), height: (pixels.height * factor).rounded(.down))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// The headless side keeps nothing; the on-screen side saves to the Simulator's Photos as usual.
struct DiscardingMediaStore: MediaStore {
    func savePhoto(data: Data, fileExtension: String) async throws {}
    func saveVideo(fileURL: URL) async throws {}
}

/// The staged photo, full bleed, where the capture session's preview layer would be.
struct StagedViewfinder: View {
    let image: UIImage

    var body: some View {
        Color.black
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
            .clipped()
            .ignoresSafeArea()
    }
}
#endif
