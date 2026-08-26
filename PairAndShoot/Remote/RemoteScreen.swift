import PairAndShootCore
import SwiftUI

@MainActor
struct RemoteScreen: View {
    let onClose: () -> Void

    @State private var model: RemoteModel?
    @State private var codeTarget: Peer?
    @State private var showSettings = false
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
            let model = self.model ?? RemoteModel(
                transport: TransportFactory.make(displayName: DeviceIdentity.displayName),
                mediaStore: PhotoKitMediaStore(),
                appVersion: DeviceIdentity.appVersion
            )
            self.model = model
            model.start()
            TransportFactory.markStarted()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model?.stop()
        }
    }

    @ViewBuilder
    private func content(_ model: RemoteModel) -> some View {
        VStack(spacing: 0) {
            header(model)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            if photoAccess.isDenied {
                PhotoAccessWarning(access: photoAccess)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            switch model.connection {
            case .idle, .browsing:
                DiscoveryView(model: model) { peer in
                    if model.requiresCode {
                        codeTarget = peer
                    } else {
                        model.connect(to: peer)   // Wi-Fi Aware: system already paired the devices
                    }
                }
            case .connecting(let peer):
                ConnectingView(peer: peer) { model.disconnect() }
            case .connected:
                ControlDeck(model: model, showSettings: $showSettings)
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
        HStack {
            ControlButton(systemImage: "xmark", label: "Close") { onClose() }
            Spacer()
            switch model.connection {
            case .connected(let peer):
                HStack(spacing: 8) {
                    StatusPill(text: model.camera?.displayName ?? peer.displayName, systemImage: "camera.fill", tint: Theme.success)
                    ChannelPill(fast: model.fileChannelFast)
                }
                Spacer()
                ControlButton(systemImage: "gearshape.fill", label: "Settings") { showSettings = true }
            default:
                StatusPill(text: "Remote", systemImage: "dot.radiowaves.left.and.right", tint: Theme.inkMuted)
                Spacer()
                ControlButton(systemImage: "gearshape.fill", label: "Settings") { showSettings = true }
            }
        }
    }
}

private struct DiscoveryView: View {
    let model: RemoteModel
    let onSelect: (Peer) -> Void
    @State private var pairingState = WiFiAwarePairingState()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            if !model.requiresCode, #available(iOS 26.0, *), !pairingState.hasPaired {
                RemotePairButton(onPaired: { model.restartBrowsing() })
            }
            if model.cameras.isEmpty {
                VStack(spacing: 14) {
                    ProgressView().tint(.white).controlSize(.large)
                    Text("Looking for cameras…")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Open Pair & Shoot on the other device and choose Camera. Both devices need Wi-Fi or Bluetooth on.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Cameras nearby")
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .tracking(1.4)
                        .foregroundStyle(Theme.inkMuted)
                    ForEach(model.cameras) { camera in
                        Button {
                            onSelect(camera)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "camera.fill")
                                    .font(.title3)
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Color.accentColor, in: Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(camera.displayName)
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                    Text("Tap, then enter the code on its screen")
                                        .font(.footnote)
                                        .foregroundStyle(Theme.inkMuted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(Theme.inkMuted)
                            }
                            .padding(16)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 480)
            }
            Spacer()
            // Wi-Fi Aware presents the system-assigned device names itself, so only show our own
            // local-name hint on the code-pairing (Multipeer) path where the app manages names.
            if model.requiresCode {
                Text("You are “\(model.localName)”")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkMuted)
                    .padding(.bottom, 16)
            }
        }
        .padding(.horizontal, 24)
        .onAppear { pairingState.start() }
        .onDisappear { pairingState.stop() }
    }
}

private struct ConnectingView: View {
    let peer: Peer
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().tint(.white).controlSize(.large)
            Text("Connecting to \(peer.displayName)…")
                .font(.headline)
                .foregroundStyle(.white)
            Button("Cancel") { onCancel() }
                .buttonStyle(.bordered)
                .tint(.white)
            Spacer()
        }
    }
}

private struct ControlDeck: View {
    let model: RemoteModel
    @Binding var showSettings: Bool
    @State private var downloadTarget: CaptureResult?

    var body: some View {
        let state = model.cameraState
        let capabilities = model.camera?.capabilities ?? CameraCapabilities()
        VStack(spacing: 20) {
            Spacer(minLength: 12)
            stage(state)
            Spacer(minLength: 12)
            TransferBannerHost(transfer: model.transfer)
            HStack(spacing: 18) {
                ControlButton(
                    systemImage: (state?.flash ?? .off) == .off ? "bolt.slash.fill" : ((state?.flash ?? .off) == .auto ? "bolt.badge.automatic.fill" : "bolt.fill"),
                    label: "Flash",
                    isActive: (state?.flash ?? .off) != .off,
                    isEnabled: capabilities.hasFlash && state != nil
                ) { model.cycleFlash() }
                ControlButton(
                    systemImage: "timer",
                    label: "Timer",
                    badge: model.timerSeconds == 0 ? nil : "\(model.timerSeconds)s",
                    isActive: model.timerSeconds != 0
                ) { model.timerSeconds = model.timerSeconds == 0 ? 3 : (model.timerSeconds == 3 ? 10 : 0) }
                ControlButton(
                    systemImage: "arrow.triangle.2.circlepath.camera",
                    label: "Switch camera",
                    isEnabled: capabilities.hasFrontCamera && state?.isRecording != true && state != nil
                ) { model.flipCamera() }
            }
            ModeSwitch(mode: state?.mode ?? .photo, canRecord: capabilities.canRecordVideo, isLocked: state?.isRecording ?? true) {
                model.setMode($0)
            }
            ShutterButton(look: .forState(state), size: 124) { model.shutter() }
                .disabled(model.isReceivingFile)
                .opacity(model.isReceivingFile ? 0.4 : 1)
            Text(model.isReceivingFile ? "Downloading… shutter paused" : hint(state))
                .font(.footnote)
                .foregroundStyle(Theme.inkMuted)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
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
            Text("You're connected over Bluetooth, so this \(ByteCountFormatter.string(fromByteCount: Int64(capture.byteCount), countStyle: .file)) \(capture.kind == .video ? "video" : "photo") takes about \(model.estimatedBluetoothSeconds(for: capture)) seconds. On the same Wi-Fi it would arrive in a second or two.")
        }
    }

    @ViewBuilder
    private func stage(_ state: CameraState?) -> some View {
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
            VStack(spacing: 12) {
                Button {
                    ExternalApp.openPhotos()
                } label: {
                    CaptureThumbnail(result: model.lastCapture, size: 300)
                }
                .buttonStyle(.plain)
                if let capture = model.lastCapture, model.canDownloadFullFile(capture) {
                    Button {
                        downloadTarget = capture
                    } label: {
                        Label("Download full \(capture.kind == .video ? "video" : "photo")", systemImage: "arrow.down.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.success)
                } else if let capture = model.lastCapture, model.isDownloading(capture) {
                    Button(role: .destructive) {
                        model.cancelDownload(capture)
                    } label: {
                        Label("Cancel download", systemImage: "xmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                Button {
                    ExternalApp.openPhotos()
                } label: {
                    Label("Open Photos", systemImage: "photo.on.rectangle.angled")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.white)
                Text(model.lastCapture == nil
                     ? "Shots you take appear here and in Photos"
                     : "\(model.captures.count) this session · tap to open Photos")
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
        }
    }

    private func hint(_ state: CameraState?) -> String {
        guard let state else { return "" }
        switch state.mode {
        case .photo:
            return model.sendBackPhotos ? "Photos come back to this device" : "Photos stay on the camera"
        case .video:
            return model.sendBackVideos ? "Videos come back to this device (Wi-Fi recommended)" : "Videos stay on the camera"
        }
    }
}

private struct RemoteSettingsSheet: View {
    @Bindable var model: RemoteModel
    @AppStorage(DeviceIdentity.nicknameKey) private var nickname = ""
    @AppStorage(TransportFactory.wifiAwarePreferenceKey) private var useWiFiAware = false
    @Environment(\.dismiss) private var dismiss
    @Environment(PhotoLibraryAccess.self) private var photoAccess

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Photos", isOn: $model.sendBackPhotos)
                    Toggle("Videos", isOn: $model.sendBackVideos)
                    Button {
                        ExternalApp.openPhotos()
                    } label: {
                        Label("Open Photos", systemImage: "photo.on.rectangle.angled")
                    }
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
                if TransportFactory.wifiAwareSupported {
                    Section {
                        Toggle("Use Wi-Fi Aware", isOn: $useWiFiAware)
                    } header: {
                        Text("Experimental")
                    } footer: {
                        Text("Connect over Wi‑Fi Aware instead of the default Bluetooth + Wi‑Fi. Both devices need iOS 26 and must be paired in the system pairing prompt. Applies next time you open the remote.")
                    }
                }
                if model.connection.isConnected {
                    Section {
                        Button("Disconnect from camera", role: .destructive) {
                            model.disconnect()
                            dismiss()
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
        .presentationDetents([.medium, .large])
    }
}
