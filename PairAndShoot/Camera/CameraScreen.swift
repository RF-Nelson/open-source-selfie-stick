import AVKit
import PairAndShootCore
import SwiftUI

/// Everything the camera screen needs, created once when the screen appears.
@MainActor
final class CameraStack {
    let model: CameraHostModel
    let preview: PreviewSource?
    let capture: CaptureService?
    let previewController = PreviewController()

    init() {
        let transport = TransportFactory.make(displayName: DeviceIdentity.displayName)
        #if targetEnvironment(simulator)
        let device: any CameraDevice = SimulatedCameraDevice()
        preview = nil
        capture = nil
        #else
        let service = CaptureService()
        let device: any CameraDevice = service
        preview = service.previewSource
        capture = service
        #endif
        model = CameraHostModel(
            transport: transport,
            device: device,
            mediaStore: PhotoKitMediaStore(),
            thumbnails: ImageThumbnailMaker(),
            appVersion: DeviceIdentity.appVersion
        )
    }
}

@MainActor
struct CameraScreen: View {
    let onClose: () -> Void

    @State private var stack: CameraStack?
    @State private var showSettings = false
    @State private var confirmDisconnect = false
    @State private var localTimer = 0
    @State private var zoomBase: CGFloat = 1
    @Environment(PhotoLibraryAccess.self) private var photoAccess

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            if let stack {
                content(stack)
            } else {
                ProgressView().tint(.white)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            UIApplication.shared.isIdleTimerDisabled = true
            let stack = self.stack ?? CameraStack()
            self.stack = stack
            await stack.model.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            if let stack {
                Task { await stack.model.stop() }
            }
        }
    }

    @ViewBuilder
    private func content(_ stack: CameraStack) -> some View {
        let model = stack.model
        let state = model.state
        ZStack {
            if let preview = stack.preview {
                CameraPreviewView(source: preview, position: state.position, controller: stack.previewController)
                    .ignoresSafeArea()
                    .onTapGesture(coordinateSpace: .local) { location in
                        if let devicePoint = stack.previewController.focus(at: location) {
                            Task { await stack.capture?.focus(at: devicePoint) }
                        }
                    }
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                Task { await stack.capture?.setZoom(zoomBase * value.magnification) }
                            }
                            .onEnded { _ in
                                Task { zoomBase = await stack.capture?.zoomFactor ?? 1 }
                            }
                    )
            } else {
                SimulatedPreview()
            }

            if case .unavailable(let reason) = model.availability {
                CameraUnavailableView(reason: reason, onClose: onClose)
            } else {
                VStack(spacing: 0) {
                    topBar(model)
                    if photoAccess.isDenied {
                        PhotoAccessWarning(access: photoAccess)
                            .padding(.top, 12)
                    }
                    Spacer()
                    if !model.link.isConnected, model.availability == .ready {
                        if model.usesCodePairing {
                            PairingCard(model: model)
                                .padding(.bottom, 20)
                        } else if #available(iOS 26.0, *) {
                            CameraPairButton()
                                .padding(.bottom, 20)
                        }
                    }
                    TransferBannerHost(transfer: model.outgoingTransfer)
                        .padding(.bottom, 12)
                    bottomBar(model)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)

                if let seconds = state.countdown {
                    CountdownOverlay(seconds: seconds)
                        .allowsHitTesting(false)
                }
            }

            VStack(spacing: 8) {
                if state.isRecording {
                    RecordingBadge(duration: state.recordingDuration)
                }
                if let notice = model.notice {
                    NoticeToast(text: notice)
                        .onTapGesture { model.dismissNotice() }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 72)
            .animation(.easeOut(duration: 0.2), value: model.notice)
        }
        .onCameraCaptureEvent { event in
            if event.phase == .ended { shutter(model) }
        }
        .sheet(isPresented: $showSettings) {
            CameraSettingsSheet(model: model)
        }
        .confirmationDialog("Disconnect the remote?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { model.disconnectRemote() }
        }
    }

    private func topBar(_ model: CameraHostModel) -> some View {
        let state = model.state
        return HStack(spacing: 10) {
            ControlButton(systemImage: "xmark", label: "Close") { onClose() }
            Spacer(minLength: 4)
            linkPill(model)
            Spacer(minLength: 4)
            ControlButton(
                systemImage: state.flash == .off ? "bolt.slash.fill" : (state.flash == .auto ? "bolt.badge.automatic.fill" : "bolt.fill"),
                label: "Flash \(state.flash.rawValue)",
                isActive: state.flash != .off,
                isEnabled: model.capabilities.hasFlash
            ) { model.perform(.setFlash(state.flash.next)) }
            ControlButton(
                systemImage: "arrow.triangle.2.circlepath.camera",
                label: "Switch camera",
                isEnabled: model.capabilities.hasFrontCamera && !state.isRecording
            ) { model.perform(.setPosition(state.position.toggled)) }
            ControlButton(systemImage: "gearshape.fill", label: "Settings") { showSettings = true }
        }
    }

    @ViewBuilder
    private func linkPill(_ model: CameraHostModel) -> some View {
        switch model.link {
        case .none:
            StatusPill(text: "No remote", systemImage: "dot.radiowaves.left.and.right", tint: Theme.inkMuted)
        case .connecting:
            StatusPill(text: "Connecting…", systemImage: "dot.radiowaves.left.and.right")
        case .connected(let peer, let info):
            Button { confirmDisconnect = true } label: {
                StatusPill(text: info?.displayName ?? peer.displayName, systemImage: "dot.radiowaves.left.and.right", tint: Theme.success)
            }
            .buttonStyle(.plain)
        }
    }

    private func bottomBar(_ model: CameraHostModel) -> some View {
        let state = model.state
        return VStack(spacing: 18) {
            ModeSwitch(mode: state.mode, canRecord: model.capabilities.canRecordVideo, isLocked: state.isRecording) {
                model.perform(.setMode($0))
            }
            HStack {
                ControlButton(
                    systemImage: "timer",
                    label: "Timer",
                    badge: localTimer == 0 ? nil : "\(localTimer)s",
                    isActive: localTimer != 0
                ) { localTimer = localTimer == 0 ? 3 : (localTimer == 3 ? 10 : 0) }
                Spacer()
                ShutterButton(look: .forState(state)) { shutter(model) }
                Spacer()
                CaptureThumbnail(result: model.lastCapture, size: 48)
            }
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }

    private func shutter(_ model: CameraHostModel) {
        let state = model.state
        if state.countdown != nil {
            model.perform(.cancelCountdown)
            return
        }
        switch state.mode {
        case .photo:
            model.perform(.capturePhoto(sendBack: false, delay: localTimer))
        case .video:
            model.perform(state.isRecording ? .stopRecording : .startRecording(sendBack: false, delay: localTimer))
        }
    }
}

private struct PairingCard: View {
    let model: CameraHostModel

    var body: some View {
        VStack(spacing: 10) {
            Text("Pair a remote")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundStyle(Theme.inkMuted)
            Text(model.pairingCode.digits.map(String.init).joined(separator: " "))
                .font(.numerals(48, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .accessibilityLabel("Pairing code \(model.pairingCode.digits.map(String.init).joined(separator: " "))")
            Text("On the other device choose Remote, pick “\(model.localName)”, and enter this code.")
                .font(.footnote)
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
            if case .connecting = model.link {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Connecting…").font(.footnote.weight(.semibold)).foregroundStyle(.white)
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(maxWidth: 360)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}

private struct CameraUnavailableView: View {
    let reason: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.slash")
                .font(.system(size: 44))
                .foregroundStyle(Theme.inkMuted)
            Text(reason)
                .font(.body)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { UIApplication.shared.open(url) }
                    .buttonStyle(.borderedProminent)
            }
            Button("Back") { onClose() }
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .padding(32)
    }
}

private struct SimulatedPreview: View {
    var body: some View {
        LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .overlay {
                Text("Simulator: no live camera.\nPhotos are generated.")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
            }
    }
}

private struct CameraSettingsSheet: View {
    @Bindable var model: CameraHostModel
    @AppStorage(DeviceIdentity.nicknameKey) private var nickname = ""
    @AppStorage(TransportFactory.wifiAwarePreferenceKey) private var useWiFiAware = false
    @Environment(\.dismiss) private var dismiss
    @Environment(PhotoLibraryAccess.self) private var photoAccess

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Keep copies in Photos", isOn: $model.keepsCopies)
                    Button {
                        ExternalApp.openPhotos()
                    } label: {
                        Label("Open Photos", systemImage: "photo.on.rectangle.angled")
                    }
                } header: {
                    Text("This device")
                } footer: {
                    if photoAccess.isDenied {
                        Text("Photos access is off, so nothing will be saved here until you allow it in Settings.")
                    } else {
                        Text("Off means captures only exist on the remote (when it asks for them). Turn it off if this device is borrowed.")
                    }
                }
                Section {
                    LabeledContent("Code", value: model.pairingCode.digits)
                    Button("Issue a new code") { model.regenerateCode() }
                        .disabled(model.link.isConnected)
                } header: {
                    Text("Pairing")
                } footer: {
                    Text("A new code is issued automatically after three wrong guesses.")
                }
                if TransportFactory.wifiAwareSupported {
                    Section {
                        Toggle("Use Wi-Fi Aware", isOn: $useWiFiAware)
                    } header: {
                        Text("Experimental")
                    } footer: {
                        Text("Connect over Wi-Fi Aware instead of Wi-Fi/Bluetooth. Both devices need iOS 26 and must be paired in the system pairing prompt. Applies next time you open the camera.")
                    }
                }
                Section {
                    TextField("Nickname", text: $nickname)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Name")
                } footer: {
                    Text("Remotes currently see this device as “\(model.localName)”. A nickname applies the next time you open the camera.")
                }
            }
            .navigationTitle("Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
