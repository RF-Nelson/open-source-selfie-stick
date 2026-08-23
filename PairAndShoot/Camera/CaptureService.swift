import AVFoundation
import Foundation
import PairAndShootCore

/// Keeps block-based notification observers alive and removes them when it goes away.
final class NotificationObserverBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [any NSObjectProtocol] = []

    var isEmpty: Bool { lock.withLock { tokens.isEmpty } }

    func add(_ token: any NSObjectProtocol) {
        lock.withLock { tokens.append(token) }
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

/// Hands the capture session to the preview layer without exposing the actor's internals.
final class PreviewSource: @unchecked Sendable {
    let session: AVCaptureSession

    init(session: AVCaptureSession) {
        self.session = session
    }
}

/// The real camera: one `AVCaptureSession` with a photo output always attached and a movie output
/// attached only in video mode (so photo mode never touches the microphone).
actor CaptureService: CameraDevice {
    nonisolated let previewSource: PreviewSource

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var settings = CameraSettings()
    private var isConfigured = false
    private var activePhotoDelegates: [Int64: PhotoCaptureDelegate] = [:]
    private var movieDelegate: MovieRecordingDelegate?
    private let observers = NotificationObserverBag()
    private var microphoneUnavailable = false

    init() {
        previewSource = PreviewSource(session: session)
    }

    // MARK: CameraDevice

    func start() async throws -> CameraCapabilities {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraDeviceError.permissionDenied("camera") }
        default:
            throw CameraDeviceError.permissionDenied("camera")
        }
        if !isConfigured {
            try configureSession()
        }
        if !session.isRunning {
            session.startRunning()
        }
        installObservers()
        return capabilities
    }

    func stop() {
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        }
        setTorch(false)
        session.stopRunning()
    }

    func apply(_ newSettings: CameraSettings) throws {
        let previous = settings
        settings = newSettings
        guard isConfigured else { return }
        if newSettings.position != previous.position {
            try switchCamera(to: newSettings.position)
        }
        if newSettings.mode != previous.mode {
            try switchMode(to: newSettings.mode)
        }
        if movieOutput.isRecording {
            setTorch(newSettings.mode == .video && newSettings.flash == .on)
        }
    }

    func capturePhoto() async throws -> CapturedPhoto {
        guard isConfigured, session.isRunning else { throw CameraDeviceError.unavailable }
        let useHEVC = photoOutput.availablePhotoCodecTypes.contains(.hevc)
        let photoSettings = useHEVC
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            : AVCapturePhotoSettings()
        photoSettings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        photoSettings.photoQualityPrioritization = photoOutput.maxPhotoQualityPrioritization
        let flash: AVCaptureDevice.FlashMode = switch settings.flash {
        case .off: .off
        case .auto: .auto
        case .on: .on
        }
        if photoOutput.supportedFlashModes.contains(flash) {
            photoSettings.flashMode = flash
        }
        if let connection = photoOutput.connection(with: .video), let rotationCoordinator {
            let angle = rotationCoordinator.videoRotationAngleForHorizonLevelCapture
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
        let delegate = PhotoCaptureDelegate(fileExtension: useHEVC ? "heic" : "jpg")
        activePhotoDelegates[photoSettings.uniqueID] = delegate
        defer { activePhotoDelegates[photoSettings.uniqueID] = nil }
        photoOutput.capturePhoto(with: photoSettings, delegate: delegate)
        return try await delegate.photo()
    }

    func startRecording() async throws {
        guard isConfigured, session.isRunning else { throw CameraDeviceError.unavailable }
        guard settings.mode == .video, session.outputs.contains(movieOutput) else {
            throw CameraDeviceError.failed("Switch to video first.")
        }
        guard !movieOutput.isRecording else { throw CameraDeviceError.busy }
        await addAudioInputIfPermitted()
        if let connection = movieOutput.connection(with: .video), let rotationCoordinator {
            let angle = rotationCoordinator.videoRotationAngleForHorizonLevelCapture
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
        if settings.flash == .on {
            setTorch(true)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        let delegate = MovieRecordingDelegate()
        movieDelegate = delegate
        movieOutput.startRecording(to: url, recordingDelegate: delegate)
        do {
            try await delegate.waitUntilStarted()
        } catch {
            movieDelegate = nil
            setTorch(false)
            throw error
        }
    }

    func stopRecording() async throws -> RecordedMovie {
        guard movieOutput.isRecording, let delegate = movieDelegate else { throw CameraDeviceError.notRecording }
        let duration = movieOutput.recordedDuration.seconds
        movieOutput.stopRecording()
        setTorch(false)
        let url = try await delegate.waitUntilFinished()
        movieDelegate = nil
        return RecordedMovie(url: url, duration: duration.isFinite ? duration : 0)
    }

    func recordingDuration() -> TimeInterval {
        guard movieOutput.isRecording else { return 0 }
        let seconds = movieOutput.recordedDuration.seconds
        return seconds.isFinite ? seconds : 0
    }

    // MARK: Focus and zoom (driven by the preview on this device)

    func focus(at devicePoint: CGPoint) {
        guard let device = videoInput?.device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
        } catch {
            // Focus is best-effort.
        }
    }

    func setZoom(_ factor: CGFloat) {
        guard let device = videoInput?.device else { return }
        let upper = min(device.maxAvailableVideoZoomFactor, 10)
        let clamped = min(max(factor, device.minAvailableVideoZoomFactor), upper)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        } catch {
            // Zoom is best-effort.
        }
    }

    var zoomFactor: CGFloat {
        videoInput?.device.videoZoomFactor ?? 1
    }

    // MARK: Session configuration

    private var capabilities: CameraCapabilities {
        let frontCameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInTrueDepthCamera], mediaType: .video, position: .front
        ).devices
        return CameraCapabilities(
            hasFlash: videoInput?.device.hasFlash ?? false,
            hasFrontCamera: !frontCameras.isEmpty,
            canRecordVideo: true
        )
    }

    private func configureSession() throws {
        let device = try videoDevice(for: settings.position)
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraDeviceError.failed("The camera can't be used right now.")
        }
        session.addInput(input)
        videoInput = input
        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            throw CameraDeviceError.failed("Photo capture isn't available.")
        }
        session.addOutput(photoOutput)
        session.commitConfiguration()
        configurePhotoOutput()
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        isConfigured = true
        if settings.mode == .video {
            try switchMode(to: .video)
        }
    }

    private func videoDevice(for position: CameraPosition) throws -> AVCaptureDevice {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position == .back ? .back : .front)
        guard let device = discovery.devices.first else { throw CameraDeviceError.unavailable }
        return device
    }

    private func switchCamera(to position: CameraPosition) throws {
        let device = try videoDevice(for: position)
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        if let current = videoInput {
            session.removeInput(current)
        }
        guard session.canAddInput(input) else {
            if let current = videoInput {
                session.addInput(current)
            }
            session.commitConfiguration()
            throw CameraDeviceError.failed("That camera can't be used right now.")
        }
        session.addInput(input)
        videoInput = input
        session.commitConfiguration()
        configurePhotoOutput()
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
    }

    private func switchMode(to mode: CaptureMode) throws {
        session.beginConfiguration()
        switch mode {
        case .photo:
            if session.outputs.contains(movieOutput) {
                session.removeOutput(movieOutput)
            }
            if let audioInput {
                session.removeInput(audioInput)
                self.audioInput = nil
            }
            session.sessionPreset = .photo
        case .video:
            session.sessionPreset = .high
            if !session.outputs.contains(movieOutput) {
                guard session.canAddOutput(movieOutput) else {
                    session.sessionPreset = .photo
                    session.commitConfiguration()
                    throw CameraDeviceError.failed("Video recording isn't available on this device.")
                }
                session.addOutput(movieOutput)
            }
            if let connection = movieOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
                if movieOutput.availableVideoCodecTypes.contains(.hevc) {
                    movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
                }
            }
        }
        session.commitConfiguration()
        configurePhotoOutput()
    }

    private func configurePhotoOutput() {
        guard let device = videoInput?.device else { return }
        if let dimensions = device.activeFormat.supportedMaxPhotoDimensions.last {
            photoOutput.maxPhotoDimensions = dimensions
        }
        photoOutput.maxPhotoQualityPrioritization = .quality
    }

    private func addAudioInputIfPermitted() async {
        guard audioInput == nil, !microphoneUnavailable else { return }
        var status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            status = await AVCaptureDevice.requestAccess(for: .audio) ? .authorized : .denied
        }
        guard status == .authorized,
              let microphone = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: microphone)
        else {
            microphoneUnavailable = true
            return
        }
        session.beginConfiguration()
        if session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }
        session.commitConfiguration()
    }

    private func setTorch(_ on: Bool) {
        guard let device = videoInput?.device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        } catch {
            // Torch is best-effort.
        }
    }

    private func resetFocus() {
        guard let device = videoInput?.device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let centre = CGPoint(x: 0.5, y: 0.5)
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusPointOfInterest = centre
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = centre
                device.exposureMode = .continuousAutoExposure
            }
            device.isSubjectAreaChangeMonitoringEnabled = false
        } catch {
            // Best-effort.
        }
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.add(center.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { await self?.resetFocus() }
        })
        observers.add(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
            Task { await self?.recoverIfStopped() }
        })
        observers.add(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            Task { await self?.recoverIfStopped() }
        })
    }

    private func recoverIfStopped() {
        if isConfigured, !session.isRunning {
            session.startRunning()
        }
    }
}
