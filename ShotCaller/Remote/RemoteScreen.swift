import ShotCallerCore
import SwiftUI

@MainActor
struct RemoteScreen: View {
    let onClose: () -> Void

    @State private var model: RemoteModel?
    @State private var codeTarget: Peer?
    @State private var showSettings = false
    @State private var transport: (any PeerTransport)?
    @State private var confirmClose = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PhotoLibraryAccess.self) private var photoAccess

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            if let model {
                content(model)
            } else {
                ProgressView().tint(.white)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            UIApplication.shared.isIdleTimerDisabled = true
            if model == nil {
                let transport = TransportFactory.make(displayName: DeviceIdentity.displayName)
                self.transport = transport
                let model = RemoteModel(transport: transport, mediaStore: PhotoKitMediaStore(), appVersion: DeviceIdentity.appVersion)
                model.sendBackPhotos = UserDefaults.standard.object(forKey: SessionPreferences.sendsPhotos) as? Bool ?? true
                model.sendBackVideos = UserDefaults.standard.bool(forKey: SessionPreferences.sendsVideos)
                self.model = model
            }
            model?.start()
            TransportFactory.markStarted()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model?.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = phase == .active
            if phase == .active {
                photoAccess.refresh()
                model?.resume()
                if photoAccess.isGranted { Task { await model?.retrySavingCaptures() } }
            } else if phase == .background {
                model?.suspend()
            }
        }
        .confirmationDialog("Leave this session?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Leave session", role: .destructive) { onClose() }
            Button("Keep session open", role: .cancel) { }
        } message: {
            Text(model?.unsavedCaptureCount ?? 0 > 0
                 ? "Shots waiting to save on this device will be discarded. Save them before leaving to keep their originals."
                 : hasWaitingOriginals
                 ? "Some originals have not been saved on either device. Download them before leaving, or disconnecting will discard them from the camera."
                 : "The camera is recording or a transfer is in progress. Check the camera before leaving.")
        }
    }

    @ViewBuilder
    private func content(_ model: RemoteModel) -> some View {
        VStack(spacing: 0) {
            header(model)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            if photoAccess.isDenied && (model.sendBackPhotos || model.sendBackVideos) {
                PhotoAccessWarning(access: photoAccess)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            PendingSavesBanner(count: model.unsavedCaptureCount) { Task { await model.retrySavingCaptures() } }
                .padding(.horizontal, 16)
            switch model.connection {
            case .idle, .browsing:
                if let transport { DiscoveryView(model: model, transport: transport) { peer in
                    if model.requiresCode {
                        codeTarget = peer
                    } else {
                        model.connect(to: peer)   // Wi-Fi Aware: system already paired the devices
                    }
                } }
            case .connecting(let peer):
                ConnectingView(peer: peer, usesWiFiAware: !model.requiresCode) { model.disconnect() }
            case .connected:
                ControlDeck(model: model)
            }
        }
        .overlay(alignment: .top) {
            if let notice = model.notice {
                NoticeToast(text: notice)
                    .padding(.top, 64)
                    .onTapGesture { model.dismissNotice() }
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.notice)
        .sheet(item: $codeTarget) { peer in
            CodeEntrySheet(peer: peer) { code in model.connect(to: peer, code: code) }
        }
        .sheet(isPresented: $showSettings) {
            RemoteSettingsSheet(model: model)
        }
    }

    private func header(_ model: RemoteModel) -> some View {
        VStack(spacing: 8) {
            HStack {
                ControlButton(systemImage: "xmark", label: "Close remote") {
                    if model.unsavedCaptureCount > 0 || model.cameraState?.isRecording == true || model.isReceivingFile || hasWaitingOriginals {
                        confirmClose = true
                    } else { onClose() }
                }
                Spacer()
                Text("Remote").font(.headline).foregroundStyle(.white)
                Spacer()
                ControlButton(systemImage: "gearshape.fill", label: "Settings") { showSettings = true }
            }
            if case .connected(let peer) = model.connection {
                HStack(spacing: 8) {
                    StatusPill(text: model.camera?.displayName ?? peer.displayName, systemImage: "camera.fill", tint: Theme.success)
                    ChannelPill(fast: model.fileChannelFast)
                }
            }
        }
    }

    private var hasWaitingOriginals: Bool {
        guard let model else { return false }
        return model.captures.contains { $0.fileAvailable && $0.savedOnCamera == false && !model.isDownloaded($0) }
    }
}

private struct DiscoveryView: View {
    let model: RemoteModel
    let transport: any PeerTransport
    let onSelect: (Peer) -> Void
    @State private var pairingState = WiFiAwarePairingState()
    @State private var showHelp = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 52)).foregroundStyle(Theme.inkMuted)
                    .accessibilityHidden(true)
                Text(model.cameras.isEmpty ? "Let’s find your camera." : "Choose your camera")
                    .font(.title2.bold()).foregroundStyle(.white)
                Text(model.requiresCode
                     ? "Open Shot Caller on the other device and choose Camera. Keep Bluetooth on and both apps open."
                     : "Choose Wi-Fi Aware on both devices. Open Camera on the other device and pair it here.")
                    .font(.subheadline).foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                if !model.requiresCode, #available(iOS 26.0, *) {
                    if pairingState.isLoading {
                        ProgressView("Checking paired devices…").tint(.white)
                    } else if pairingState.isPairing {
                        RemotePairButton { endpoint in
                            pairingState.select(endpoint: endpoint) { model.connect(to: $0) }
                        }
                        .onDisappear { pairingState.pairingControlDidDisappear() }
                        Button("Done pairing") { pairingState.endPairing() }
                            .buttonStyle(.bordered).tint(.white)
                    } else {
                        Button { pairingState.beginPairing() } label: {
                            Label(pairingState.hasPaired ? "Pair another camera" : "Pair a camera", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if let error = pairingState.error {
                        Text(error).font(.footnote).foregroundStyle(.yellow)
                    }
                }
                if model.cameras.isEmpty && (model.requiresCode || !pairingState.isPairing) {
                    HStack {
                        ProgressView().tint(.white)
                        Text(model.isReconnecting ? "Reconnecting…" : "Looking for cameras…")
                            .font(.subheadline).foregroundStyle(Theme.inkMuted)
                    }
                }
                ForEach(model.cameras) { camera in
                    Button { onSelect(camera) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "camera.fill")
                                .font(.title3).foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.accentColor, in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(camera.displayName).font(.headline).foregroundStyle(.white)
                                Text(model.requiresCode ? "Enter the code shown on its screen" : "Paired · tap to connect")
                                    .font(.footnote).foregroundStyle(Theme.inkMuted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").foregroundStyle(Theme.inkMuted)
                        }
                        .padding(16)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .disabled(pairingState.isPairing)
                }
                Button("Can’t find your camera?") { showHelp.toggle() }
                    .frame(minHeight: 44)
                if showHelp {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Keep both devices nearby and unlocked, with Shot Caller in the foreground.")
                        Text(model.requiresCode
                             ? "Use Automatic on both home screens. Allow Bluetooth in Settings. Wi-Fi helps transfer files faster."
                             : "Use Wi-Fi Aware on both home screens, with Wi-Fi and Bluetooth on. Tap Pair a remote on the camera, then pair it here. To use another connection, close this session and turn Wi-Fi Aware off on both devices.")
                        Button("Open app settings") { openSettings() }
                        if !pairingState.isPairing {
                            Button("Search again") { model.restartBrowsing() }
                        }
                    }
                    .font(.subheadline).foregroundStyle(.white)
                    .padding(18).background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
                }
                if model.requiresCode {
                    Text("You are “\(model.localName)”").font(.footnote).foregroundStyle(Theme.inkMuted)
                }
            }
            .padding(24).frame(maxWidth: 520).frame(maxWidth: .infinity)
        }
        .task { if !model.requiresCode { pairingState.start(transport: transport) } }
        .onDisappear { pairingState.stop() }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct ConnectingView: View {
    let peer: Peer
    let usesWiFiAware: Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().tint(.white).controlSize(.large)
            Text("Connecting to \(peer.displayName)…")
                .font(.headline)
                .foregroundStyle(.white)
            if usesWiFiAware {
                Text("On the camera, finish Apple’s pairing prompt, then tap Done pairing if its pairing panel is still open.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .padding(.horizontal, 24)
            }
            Button("Cancel") { onCancel() }
                .buttonStyle(.bordered)
                .tint(.white)
            Spacer()
        }
    }
}

private struct ControlDeck: View {
    let model: RemoteModel
    @State private var downloadTarget: CaptureResult?
    @State private var previewCapture: CaptureResult?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                let wide = geometry.size.width > 650 && geometry.size.width > geometry.size.height
                if wide {
                    HStack(spacing: 40) {
                        stage(model.cameraState, previewSize: min(300, geometry.size.height * 0.55))
                            .frame(maxWidth: .infinity)
                        controls.frame(maxWidth: 340)
                    }
                    .padding(24)
                    .frame(minHeight: geometry.size.height)
                } else {
                    VStack(spacing: 24) {
                        stage(model.cameraState, previewSize: min(240, geometry.size.width - 64))
                        controls
                    }
                    .padding(24)
                    .frame(maxWidth: 520)
                    .frame(minHeight: geometry.size.height)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(item: $previewCapture) { capture in
            CapturePreviewSheet(capture: capture, savedHere: model.isDownloaded(capture))
        }
        .confirmationDialog(
            "Download over Bluetooth?",
            isPresented: Binding(get: { downloadTarget != nil }, set: { if !$0 { downloadTarget = nil } }),
            presenting: downloadTarget
        ) { capture in
            if capture.kind == .photo {
                Button("Full quality · ~\(model.estimatedBluetoothSeconds(for: capture, quality: .full)) sec") {
                    model.requestFullFile(capture, quality: .full)
                }
                Button("Reduced · ~\(model.estimatedBluetoothSeconds(for: capture, quality: .high)) sec") {
                    model.requestFullFile(capture, quality: .high)
                }
                Button("Small · ~\(model.estimatedBluetoothSeconds(for: capture, quality: .medium)) sec") {
                    model.requestFullFile(capture, quality: .medium)
                }
            } else {
                Button("Download · ~\(model.estimatedBluetoothSeconds(for: capture)) sec") {
                    model.requestFullFile(capture, quality: .full)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { capture in
            Text("Over Bluetooth, this \(ByteCountFormatter.string(fromByteCount: Int64(capture.byteCount), countStyle: .file)) \(capture.kind == .video ? "video" : "photo") may take about \(model.estimatedBluetoothSeconds(for: capture)) seconds. Keeping Wi-Fi on or joining the same network can make transfers faster.")
        }
    }

    private var controls: some View {
        let state = model.cameraState
        let capabilities = model.camera?.capabilities ?? CameraCapabilities()
        return VStack(spacing: 18) {
            TransferBannerHost(transfer: model.transfer)
            HStack(spacing: 18) {
                ControlButton(
                    systemImage: (state?.flash ?? .off) == .off ? "bolt.slash.fill" : ((state?.flash ?? .off) == .auto ? "bolt.badge.automatic.fill" : "bolt.fill"),
                    label: "Flash \(state?.flash.rawValue ?? "off")",
                    isActive: (state?.flash ?? .off) != .off,
                    isEnabled: capabilities.hasFlash && state != nil && state?.isBusy != true
                ) { model.cycleFlash() }
                ControlButton(systemImage: "timer", label: "Timer",
                              badge: model.timerSeconds == 0 ? "Off" : "\(model.timerSeconds)s",
                              isActive: model.timerSeconds != 0,
                              isEnabled: state?.isRecording != true && state?.isBusy != true) {
                    model.timerSeconds = model.timerSeconds == 0 ? 3 : (model.timerSeconds == 3 ? 10 : 0)
                }
                ControlButton(systemImage: "arrow.triangle.2.circlepath.camera", label: "Switch camera",
                              isEnabled: capabilities.hasFrontCamera && state?.isRecording != true && state?.isBusy != true && state != nil) {
                    model.flipCamera()
                }
            }
            ModeSwitch(mode: state?.mode ?? .photo, canRecord: capabilities.canRecordVideo,
                       isLocked: state == nil || state?.isRecording == true || state?.isBusy == true || state?.countdown != nil) {
                model.setMode($0)
            }
            ShutterButton(look: .forState(state), size: 116) { model.shutter() }
                .disabled(model.isReceivingFile && state?.isRecording != true && state?.countdown == nil)
                .opacity(model.isReceivingFile && state?.isRecording != true ? 0.4 : 1)
            Text(model.isReceivingFile && state?.isRecording != true ? "Downloading… shutter paused" : hint(state))
                .font(.footnote).foregroundStyle(Theme.inkMuted).multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func stage(_ state: CameraState?, previewSize: CGFloat) -> some View {
        if let seconds = state?.countdown {
            CountdownOverlay(seconds: seconds)
                .frame(height: 220)
        } else if let state, state.isRecording {
            VStack(spacing: 8) {
                RecordingBadge(duration: state.recordingDuration, large: true)
                Text("Recording on the camera")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkMuted)
            }
            .frame(height: 220)
        } else if state == nil {
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("Waiting for the camera…")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkMuted)
            }
            .frame(height: 220)
        } else {
            VStack(spacing: 22) {
                Button {
                    previewCapture = model.lastCapture
                } label: {
                    CaptureThumbnail(result: model.lastCapture, size: previewSize)
                }
                .buttonStyle(.plain)
                .disabled(model.lastCapture == nil)
                .accessibilityHint("Shows a preview and whether the original is saved here")
                if let capture = model.lastCapture, model.canDownloadFullFile(capture) {
                    Button {
                        downloadTarget = capture
                    } label: {
                        Label("Download full \(capture.kind == .video ? "video" : "photo")", systemImage: "arrow.down.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Theme.success)
                } else if let capture = model.lastCapture, model.isDownloading(capture) {
                    Button(role: .destructive) {
                        model.cancelDownload(capture)
                    } label: {
                        Label("Cancel download", systemImage: "xmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)
                }
                Text(model.lastCapture == nil
                     ? "Your latest shot will appear here."
                     : "\(model.captures.count) this session · tap for preview")
                    .font(.caption).foregroundStyle(Theme.inkMuted)
                if let capture = model.lastCapture {
                    Text(model.isDownloaded(capture) ? "Saved to Photos on this device" : "Preview received · original not saved here yet")
                        .font(.footnote).foregroundStyle(Theme.inkMuted).multilineTextAlignment(.center)
                }
            }
        }
    }

    private func hint(_ state: CameraState?) -> String {
        guard let state else { return "" }
        switch state.mode {
        case .photo:
            return model.sendBackPhotos ? "Photo copies are requested on this device" : "Photo copies are off on this device"
        case .video:
            return model.sendBackVideos ? "Video copies are requested (Wi-Fi recommended)" : "Video copies are off on this device"
        }
    }
}

private struct RemoteSettingsSheet: View {
    @Bindable var model: RemoteModel
    @AppStorage(DeviceIdentity.nicknameKey) private var nickname = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(PhotoLibraryAccess.self) private var photoAccess
    @State private var confirmDisconnect = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Photos", isOn: $model.sendBackPhotos)
                    Toggle("Videos", isOn: $model.sendBackVideos)
                } header: {
                    Text("Send copies to this device")
                } footer: {
                    if photoAccess.isDenied {
                        Text("Photos access is off, so copies can't be saved here until you allow it in Settings.")
                    } else {
                        Text("Photos arrive in a few seconds over Wi-Fi. Videos are large: a one-minute clip can take several minutes over Bluetooth. Either way the camera keeps its own copy unless you turn that off on the camera.")
                    }
                }
                Section {
                    Picker("Timer", selection: $model.timerSeconds) {
                        Text("Off").tag(0)
                        Text("3 seconds").tag(3)
                        Text("10 seconds").tag(10)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Countdown")
                } footer: {
                    Text("The camera shows the countdown on its screen so everyone in the shot can see it.")
                }
                Section {
                    TextField("Nickname", text: $nickname)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Name")
                } footer: {
                    Text("The camera currently sees this device as “\(model.localName)”. A nickname applies the next time you open the remote.")
                }
                Section("Connection") {
                    Text(model.requiresCode ? "Automatic · Bluetooth and Wi-Fi" : "Wi-Fi Aware")
                    Text("To change the connection, close this session and choose the same option on both home screens.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if model.connection.isConnected {
                    Section {
                        Button("Disconnect from camera", role: .destructive) {
                            if model.captures.contains(where: { $0.fileAvailable && $0.savedOnCamera == false && !model.isDownloaded($0) }) || model.isReceivingFile || model.cameraState?.isRecording == true {
                                confirmDisconnect = true
                            } else {
                                model.disconnect()
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .confirmationDialog("Disconnect from the camera?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                model.disconnect()
                dismiss()
            }
        } message: {
            Text("Wait for recording and downloads to finish. Any originals waiting on the camera with no copy in Photos will be discarded when you disconnect.")
        }
        .onChange(of: model.sendBackPhotos) { _, value in
            UserDefaults.standard.set(value, forKey: SessionPreferences.sendsPhotos)
            if value { Task { await photoAccess.requestIfNeeded() } }
        }
        .onChange(of: model.sendBackVideos) { _, value in
            UserDefaults.standard.set(value, forKey: SessionPreferences.sendsVideos)
            if value { Task { await photoAccess.requestIfNeeded() } }
        }
        .presentationDetents([.medium, .large])
    }
}
