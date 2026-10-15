import AVFoundation
import SwiftUI

enum Role: String, Identifiable, CaseIterable {
    case camera, remote
    var id: String { rawValue }
}

/// Preferences shared by first-use setup and the session settings.
enum SessionPreferences {
    static let cameraSetup = "cameraSetupCompleted"
    static let remoteSetup = "remoteSetupCompleted"
    static let keepsCopies = "cameraKeepsCopies"
    static let sendsPhotos = "remoteSendsPhotos"
    static let sendsVideos = "remoteSendsVideos"
    static let livePreview = "remoteLivePreview"
}

struct RootView: View {
    @State private var role: Role?
    @State private var setupRole: Role?
    @State private var pendingRole: Role?
    @State private var photoAccess = PhotoLibraryAccess()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RolePickerView(onSelect: select)
            .fullScreenCover(item: $role) { role in
                Group {
                    switch role {
                    case .camera: CameraScreen { self.role = nil }
                    case .remote: RemoteScreen { self.role = nil }
                    }
                }
                .environment(photoAccess)
            }
            .sheet(item: $setupRole, onDismiss: {
                // Present the session only after its setup sheet has left the screen.
                if let pendingRole {
                    self.pendingRole = nil
                    role = pendingRole
                }
            }) { selected in
                RoleSetupView(role: selected, photoAccess: photoAccess) {
                    pendingRole = selected
                    setupRole = nil
                }
            }
            .task {
                photoAccess.refresh()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { photoAccess.refresh() }
            }
    }

    private func select(_ selected: Role) {
        let key = selected == .camera ? SessionPreferences.cameraSetup : SessionPreferences.remoteSetup
        if UserDefaults.standard.bool(forKey: key) {
            role = selected
        } else {
            setupRole = selected
        }
    }
}

private struct RoleSetupView: View {
    let role: Role
    let photoAccess: PhotoLibraryAccess
    let onContinue: () -> Void
    @State private var saveCopies = true
    @State private var isPreparing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: role == .camera ? "camera.fill" : "dot.radiowaves.left.and.right")
                        .font(.system(size: 38))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text(role == .camera ? "Ready for your close-up." : "Get everyone in the shot.")
                        .font(.largeTitle.bold())
                    Text(role == .camera
                         ? "This device takes photos and videos. Set it somewhere steady and connect a remote; the viewfinder and shutter appear once a remote is connected. When both devices share a Wi-Fi network, the remote can see a live view of what this camera sees."
                         : "Choose Camera on the other device. This device controls its shutter, shows a live view when both devices share a Wi-Fi network, and can save copies of your shots.")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 16) {
                        if role == .camera {
                            Label("Allow Camera to show the viewfinder and take photos. Microphone access is requested when you record video.", systemImage: "camera")
                        }
                        Label(usesInternalWiFiAware
                              ? "Internal test: Apple’s pairing prompt connects your devices over Wi-Fi Aware. Both test devices need the test mode on."
                              : "Allow Bluetooth to connect nearby devices. Local Network access allows faster photo and video transfers over a shared Wi-Fi network.",
                              systemImage: "antenna.radiowaves.left.and.right")
                        Label("Your shots go directly between the devices you pair. No account is needed.", systemImage: "lock.shield")
                    }
                    .font(.subheadline)
                    .labelStyle(.titleAndIcon)
                    Toggle(role == .camera ? "Save my shots to Photos" : "Save photo copies on this device", isOn: $saveCopies)
                        .font(.headline)
                    Text("Saving is optional. If enabled, Photos asks for permission to add your new shots. Shot Caller never reads your existing library. You can change this in session settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(action: prepare) {
                        HStack {
                            if isPreparing { ProgressView().tint(.white) }
                            Text(isPreparing ? "Getting ready…" : "Continue")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPreparing)
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }.disabled(isPreparing)
                }
            }
        }
        .interactiveDismissDisabled(isPreparing)
    }

    private var usesInternalWiFiAware: Bool {
        #if DEBUG
        TransportFactory.internalWiFiAwareEnabled
        #else
        false
        #endif
    }

    private func prepare() {
        guard !isPreparing else { return }
        isPreparing = true
        Task { @MainActor in
            if role == .camera, AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
            }
            if saveCopies { await photoAccess.requestIfNeeded() }
            UserDefaults.standard.set(saveCopies, forKey: role == .camera ? SessionPreferences.keepsCopies : SessionPreferences.sendsPhotos)
            UserDefaults.standard.set(true, forKey: role == .camera ? SessionPreferences.cameraSetup : SessionPreferences.remoteSetup)
            onContinue()
        }
    }
}
