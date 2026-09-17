import AVFoundation
import SwiftUI

enum Role: String, Identifiable, CaseIterable {
    case camera, remote
    var id: String { rawValue }
}

struct RootView: View {
    @State private var role: Role?
    @State private var photoAccess = PhotoLibraryAccess()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RolePickerView(photoAccess: photoAccess) { role = $0 }
            .fullScreenCover(item: $role) { role in
                Group {
                    switch role {
                    case .camera:
                        CameraScreen { self.role = nil }
                    case .remote:
                        RemoteScreen { self.role = nil }
                    }
                }
                .environment(photoAccess)
            }
            .task {
                // If a previous Wi-Fi Aware attempt crashed mid-start, fall back so we don't loop.
                TransportFactory.recoverIfWiFiAwareCrashed()
                // Ask for everything the app needs up front, so no prompt interrupts the first
                // capture: camera, then microphone (for video), then the photo library.
                if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                }
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                }
                await photoAccess.requestIfNeeded()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { photoAccess.refresh() }
            }
    }
}
