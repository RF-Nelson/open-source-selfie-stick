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
    #if DEBUG
    @State private var pairingState = WiFiAwarePairingState()
    #endif
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
            #if DEBUG
            if !stack.model.usesCodePairing {
                pairingState.start(transport: stack.transport, automaticallyFinishPairing: true)
            }
            #endif
            TransportFactory.markStarted()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            #if DEBUG
            pairingState.stop()
            #endif
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
                    #if DEBUG
                    pairingState.stop()
                    #endif
                    await stack.model.suspend()
                } else if phase == .active {
                    photoAccess.refresh()
                    await stack.model.resume()
                    if photoAccess.isGranted && stack.model.keepsCopies {
                        await stack.model.retrySavingCaptures()
                    }
                    #if DEBUG
                    if !stack.model.usesCodePairing {
                        pairingState.start(transport: stack.transport, automaticallyFinishPairing: true)
                    }
                    #endif
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
        // The viewfinder and its controls appear once a remote is connected. A recording that outlives
        // its remote keeps them, so Stop is always reachable; a capture still starting or finishing
        // (`isBusy`) keeps them too, so a disconnect mid-operation cannot flash the waiting room.
        // `isPaired` rather than `link.isConnected`: a remote that is still proving the code is
        // connected but not yet trusted, and must not reveal the viewfinder.
        let connected = (model.link.isConnected && model.isPaired) || state.isRecording || state.isBusy
        ZStack {
            if !connected {
                // Nothing to shoot with yet: no viewfinder until a remote is connected.
                Theme.canvas.ignoresSafeArea()
            } else if let preview = stack.preview {
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
            } else if !connected {
                waitingRoom(model)
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
                if let viewer = model.previewViewerName {
                    LiveViewSharingPill(viewer: viewer)
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
            // The hardware shutter does nothing while there is no viewfinder.
            if event.phase == .ended, connected { shutter(model) }
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

    /// Everything the camera shows before a remote is connected. The whole screen is about getting
    /// a remote connected: no viewfinder, no capture controls.
    private func waitingRoom(_ model: CameraHostModel) -> some View {
        VStack(spacing: 8) {
            topBar(model)
            if photoAccess.isDenied && model.keepsCopies {
                PhotoAccessWarning(access: photoAccess)
            }
            PendingSavesBanner(count: model.unsavedCaptureCount) {
                Task { await model.retrySavingCaptures() }
            }
            ScrollView {
                VStack(spacing: 20) {
                    if model.availability == .starting {
                        ProgressView("Starting the camera…").tint(.white).foregroundStyle(.white)
                    } else if model.usesCodePairing {
                        codeWaiting(model)
                    } else {
                        #if DEBUG
                        if #available(iOS 26.0, *) { wifiAwareWaiting(model) }
                        #endif
                    }
                }
                .padding(24)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func codeWaiting(_ model: CameraHostModel) -> some View {
        WaitingHeader(title: "Waiting for a remote", systemImage: "dot.radiowaves.left.and.right")
        Text(model.pairingCode.digits.map(String.init).joined(separator: " "))
            .font(.numerals(64, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .accessibilityLabel("Pairing code \(model.pairingCode.digits.map(String.init).joined(separator: " "))")
        Text("On the other device choose Remote, pick “\(model.localName)”, and enter this code.")
            .font(.body)
            .foregroundStyle(Theme.inkMuted)
            .multilineTextAlignment(.center)
        Text("The viewfinder and shutter appear when a remote connects.")
            .font(.footnote)
            .foregroundStyle(Theme.inkMuted)
            .multilineTextAlignment(.center)
        if case .connecting = model.link {
            ConnectingRow()
        }
    }

    #if DEBUG
    @available(iOS 26.0, *)
    @ViewBuilder
    private func wifiAwareWaiting(_ model: CameraHostModel) -> some View {
        if pairingState.isLoading {
            ProgressView("Checking paired devices…").tint(.white).foregroundStyle(.white)
        } else if pairingState.isPairing {
            WaitingHeader(title: "Pair your remote", systemImage: "dot.radiowaves.left.and.right")
            CameraPairButton()
                .onDisappear { pairingState.pairingControlDidDisappear() }
            Text(pairingState.hasPaired
                 ? "Tap Pair remote, then on the remote tap Pair camera and choose this device in Apple’s prompt. After pairing, close Apple’s panel and tap Done pairing if this screen is still showing."
                 : "Tap Pair remote, then on the remote tap Pair camera and choose this device in Apple’s prompt. This screen continues by itself once they are paired.")
                .font(.body)
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
            if pairingState.hasPaired {
                Button("Done pairing") { pairingState.endPairing() }
                    .buttonStyle(.bordered).tint(.white)
            }
        } else if pairingState.hasPaired {
            WaitingHeader(title: "Waiting for your remote", systemImage: "wifi")
            Text("On the remote, choose this device from its camera list. Keep both apps open.")
                .font(.body)
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
            if case .connecting = model.link {
                ConnectingRow()
            }
            Button("Pair a different remote") { pairingState.beginPairing() }
                .buttonStyle(.bordered).tint(.white)
                .padding(.top, 12)
        } else {
            WaitingHeader(title: "Pair your remote", systemImage: "dot.radiowaves.left.and.right")
            Button { pairingState.beginPairing() } label: {
                PairButtonLabel(title: "Pair remote", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.plain)
            Text("A remote connects only after Apple pairs the two devices.")
                .font(.body)
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
        }
        if let error = pairingState.error {
            Text(error).font(.footnote).foregroundStyle(.yellow).multilineTextAlignment(.center)
        }
    }
    #endif

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
        #if DEBUG
        pairingState.stop()
        #endif
        let pending = lifecycleTask
        Task {
            await pending?.value
            await stack?.model.suspend()
            if let stack, stack.model.unsavedCaptureCount > 0, !discardUnsaved {
                let model = stack.model
                // Finishing a recording can discover a new save failure after Close was tapped.
                // Keep its original until the person retries or explicitly chooses to discard it.
                await model.resume()
                #if DEBUG
                if !model.usesCodePairing {
                    pairingState.start(transport: stack.transport, automaticallyFinishPairing: true)
                }
                #endif
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
        model.shutter(delay: localTimer)   // honours the remote's copy preferences
    }
}

private struct WaitingHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(Theme.inkMuted)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
    }
}

private struct ConnectingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().tint(.white)
            Text("Connecting…").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
        }
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
                    #if DEBUG
                    Text(model.usesCodePairing ? "Bluetooth and Wi-Fi" : "Internal test: Wi-Fi Aware")
                    Text(model.usesCodePairing
                         ? "Bluetooth connects your devices. Join the same Wi-Fi network for faster photo and video transfers."
                         : "Debug-only test mode. Turn it on on both supported test devices; turn it off on both to test the shipping connection.")
                        .font(.footnote).foregroundStyle(.secondary)
                    #else
                    Text("Bluetooth and Wi-Fi")
                    Text("Bluetooth connects your devices. Join the same Wi-Fi network for faster photo and video transfers.")
                        .font(.footnote).foregroundStyle(.secondary)
                    #endif
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
        .presentationDetents(Sheets.detents)
    }
}
