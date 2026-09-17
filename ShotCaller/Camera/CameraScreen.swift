import AVKit
import ShotCallerCore
import SwiftUI

/// Everything the camera screen needs, created once when the screen appears.
@MainActor
final class CameraStack {
    let model: CameraHostModel
    let transport: any PeerTransport
    let preview: PreviewSource?
    let capture: CaptureService?
    let previewController = PreviewController()

    init() {
        transport = TransportFactory.make(displayName: DeviceIdentity.displayName)
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
    @State private var confirmClose = false
    @State private var isClosing = false
    @State private var previewCapture: CaptureResult?
    @State private var lifecycleTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    @State private var localTimer = 0
    @State private var zoomBase: CGFloat = 1
    @State private var pairingState = WiFiAwarePairingState()
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
            stack.model.keepsCopies = UserDefaults.standard.object(forKey: SessionPreferences.keepsCopies) as? Bool ?? true
            await stack.model.start()
            if !stack.model.usesCodePairing {
                pairingState.start(transport: stack.transport, automaticallyFinishPairing: true)
            }
            TransportFactory.markStarted()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            pairingState.stop()
            let pending = lifecycleTask
            if let stack { Task { await pending?.value; await stack.model.stop() } }
        }
        .onChange(of: scenePhase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = phase == .active
            guard let stack, !isClosing else { return }
            let pending = lifecycleTask
            lifecycleTask = Task {
                await pending?.value
                if phase == .background {
                    pairingState.stop()
                    await stack.model.suspend()
                } else if phase == .active {
                    photoAccess.refresh()
                    await stack.model.resume()
                    if photoAccess.isGranted && stack.model.keepsCopies {
                        await stack.model.retrySavingCaptures()
                    }
                    if !stack.model.usesCodePairing {
                        pairingState.start(transport: stack.transport, automaticallyFinishPairing: true)
                    }
                }
            }
        }
        .confirmationDialog("Leave the camera?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button(hasUnsavedOriginals ? "Discard unsaved shots and leave" : "Finish and leave", role: .destructive) {
                finishAndClose(discardUnsaved: hasUnsavedOriginals)
            }
            Button("Keep camera open", role: .cancel) { }
        } message: {
            Text(stack?.model.unsavedCaptureCount ?? 0 > 0
                 ? "Shots waiting to save will be discarded. Retry saving before leaving to keep their originals."
                 : (stack?.model.unsavedTransferCount ?? 0) > 0
                 ? "Some originals are waiting to transfer and have no copy in this device’s Photos. Download them on the remote before leaving, or they will be discarded."
                 : stack?.model.keepsCopies == false
                 ? "Saving on this device is off. Stop recording and finish the remote’s download before leaving to keep the original. Leaving now can discard it."
                 : "Recording will finish before the camera closes. The remote will disconnect.")
        }
        .overlay {
            if isClosing {
                ZStack {
                    Color.black.opacity(0.8).ignoresSafeArea()
                    ProgressView("Finishing your shot…").tint(.white).foregroundStyle(.white)
                }
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
                CameraUnavailableView(reason: reason, onRetry: { Task { await model.retryCamera() } }, onClose: close)
            } else {
                GeometryReader { geometry in
                    let wide = geometry.size.width > geometry.size.height
                    VStack(spacing: 8) {
                        topBar(model)
                        if photoAccess.isDenied && model.keepsCopies {
                            PhotoAccessWarning(access: photoAccess)
                        }
                        PendingSavesBanner(count: model.unsavedCaptureCount) {
                            Task { await model.retrySavingCaptures() }
                        }
                        if wide {
                            HStack(alignment: .bottom, spacing: 24) {
                                ScrollView { pairingPanel(model) }.frame(maxWidth: 360)
                                Spacer(minLength: 0)
                                ScrollView {
                                    VStack(spacing: 12) {
                                        TransferBannerHost(transfer: model.outgoingTransfer)
                                        bottomBar(model)
                                    }
                                }.frame(maxWidth: 300)
                            }
                        } else {
                            ScrollView {
                                VStack(spacing: 16) {
                                    pairingPanel(model)
                                    TransferBannerHost(transfer: model.outgoingTransfer)
                                    bottomBar(model)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: max(0, geometry.size.height - 96), alignment: .bottom)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }

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
        .sheet(item: $previewCapture) { capture in
            CapturePreviewSheet(capture: capture, savedHere: capture.savedOnCamera == true)
        }
        .confirmationDialog("Disconnect the remote?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { model.disconnectRemote() }
        } message: {
            Text(model.unsavedTransferCount > 0
                 ? "Some originals have not been saved to Photos and are still waiting to transfer. Disconnecting will discard them. Finish downloading on the remote first to keep them."
                 : "You can pair a remote again from the camera screen.")
        }
    }

    @ViewBuilder
    private func pairingPanel(_ model: CameraHostModel) -> some View {
        if !model.link.isConnected, model.availability == .ready {
            if model.usesCodePairing {
                PairingCard(model: model)
            } else if #available(iOS 26.0, *) {
                VStack(spacing: 12) {
                    if pairingState.isLoading {
                        ProgressView("Checking paired devices…").tint(.white)
                    } else if pairingState.isPairing {
                        CameraPairButton()
                            .onDisappear { pairingState.pairingControlDidDisappear() }
                        Button("Done pairing") { pairingState.endPairing() }
                            .buttonStyle(.bordered).tint(.white)
                    } else {
                        Label(pairingState.hasPaired ? "Ready for your remote" : "Pair a remote to connect", systemImage: "wifi")
                            .font(.headline).foregroundStyle(.white)
                        Text("Choose this camera on the paired remote, or pair another device.")
                            .font(.footnote).foregroundStyle(Theme.inkMuted).multilineTextAlignment(.center)
                        Button(pairingState.hasPaired ? "Pair another remote" : "Pair a remote") { pairingState.beginPairing() }
                            .buttonStyle(.borderedProminent)
                    }
                    if let error = pairingState.error {
                        Text(error).font(.footnote).foregroundStyle(.yellow)
                    }
                }
                .padding(12)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    private func topBar(_ model: CameraHostModel) -> some View {
        HStack(spacing: 8) {
            ControlButton(systemImage: "xmark", label: "Close camera") {
                if model.state.isRecording || model.state.isBusy || model.unsavedCaptureCount > 0 || model.unsavedTransferCount > 0 {
                    confirmClose = true
                } else { close() }
            }
            Spacer(minLength: 0)
            linkPill(model)
            Spacer(minLength: 0)
            ControlButton(systemImage: "gearshape.fill", label: "Settings") { showSettings = true }
        }
    }

    private func close() {
        finishAndClose(discardUnsaved: false)
    }

    private var hasUnsavedOriginals: Bool {
        (stack?.model.unsavedCaptureCount ?? 0) > 0 || (stack?.model.unsavedTransferCount ?? 0) > 0
    }

    private func finishAndClose(discardUnsaved: Bool) {
        guard !isClosing else { return }
        isClosing = true
        pairingState.stop()
        let pending = lifecycleTask
        Task {
            await pending?.value
            await stack?.model.suspend()
            if let stack, stack.model.unsavedCaptureCount > 0, !discardUnsaved {
                let model = stack.model
                // Finishing a recording can discover a new save failure after Close was tapped.
                // Keep its original until the person retries or explicitly chooses to discard it.
                await model.resume()
                if !model.usesCodePairing {
                    pairingState.start(transport: stack.transport, automaticallyFinishPairing: true)
                }
                isClosing = false
                confirmClose = true
                return
            }
            await stack?.model.stop()
            onClose()
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
            HStack(spacing: 8) {
                Button { confirmDisconnect = true } label: {
                    StatusPill(text: info?.displayName ?? peer.displayName, systemImage: "dot.radiowaves.left.and.right", tint: Theme.success)
                }
                .buttonStyle(.plain)
                ChannelPill(fast: model.fileChannelFast)
            }
        }
    }

    private func bottomBar(_ model: CameraHostModel) -> some View {
        let state = model.state
        return VStack(spacing: 18) {
            ModeSwitch(mode: state.mode, canRecord: model.capabilities.canRecordVideo, isLocked: state.isRecording || state.isBusy || state.countdown != nil) {
                model.perform(.setMode($0))
            }
            HStack(spacing: 18) {
                ControlButton(systemImage: state.flash == .off ? "bolt.slash.fill" : (state.flash == .auto ? "bolt.badge.automatic.fill" : "bolt.fill"),
                              label: "Flash \(state.flash.rawValue)", isActive: state.flash != .off,
                              isEnabled: model.capabilities.hasFlash && !state.isBusy) {
                    model.perform(.setFlash(state.flash.next))
                }
                ControlButton(systemImage: "timer", label: "Timer",
                              badge: localTimer == 0 ? "Off" : "\(localTimer)s", isActive: localTimer != 0,
                              isEnabled: !state.isRecording && !state.isBusy) {
                    localTimer = localTimer == 0 ? 3 : (localTimer == 3 ? 10 : 0)
                }
                ControlButton(systemImage: "arrow.triangle.2.circlepath.camera", label: "Switch camera",
                              isEnabled: model.capabilities.hasFrontCamera && !state.isRecording && !state.isBusy) {
                    model.perform(.setPosition(state.position.toggled))
                    zoomBase = 1
                }
            }
            ShutterButton(look: .forState(state)) { shutter(model) }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    Button { previewCapture = model.lastCapture } label: {
                        CaptureThumbnail(result: model.lastCapture, size: 48)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.lastCapture == nil)
                    .accessibilityLabel("Preview last shot")
                }
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
    let onRetry: () -> Void
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
            Button("Try again", action: onRetry)
                .buttonStyle(.bordered).tint(.white)
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
    @Environment(\.dismiss) private var dismiss
    @Environment(PhotoLibraryAccess.self) private var photoAccess

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Keep copies in Photos", isOn: $model.keepsCopies)
                } header: {
                    Text("This device")
                } footer: {
                    if photoAccess.isDenied {
                        Text("Photos access is off, so nothing will be saved here until you allow it in Settings.")
                    } else {
                        Text("When off, originals are kept only if the remote requests and saves them. Leave this on to keep your own copy. Saved originals are available in the Photos app.")
                    }
                }
                if model.usesCodePairing {
                    Section {
                        LabeledContent("Code", value: model.pairingCode.digits)
                        Button("Issue a new code") { model.regenerateCode() }
                            .disabled(model.link.isConnected)
                    } header: { Text("Pairing") } footer: {
                        Text("A new code is issued automatically after three wrong guesses.")
                    }
                }
                Section("Connection") {
                    Text(model.usesCodePairing ? "Automatic · Bluetooth and Wi-Fi" : "Wi-Fi Aware")
                    Text("To change the connection, close this session and choose the same option on both home screens.")
                        .font(.footnote).foregroundStyle(.secondary)
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
        .onChange(of: model.keepsCopies) { _, value in
            UserDefaults.standard.set(value, forKey: SessionPreferences.keepsCopies)
            if value { Task { await photoAccess.requestIfNeeded() } }
        }
        .presentationDetents([.medium, .large])
    }
}
