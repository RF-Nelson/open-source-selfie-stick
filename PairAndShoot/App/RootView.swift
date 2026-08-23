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
                await photoAccess.requestIfNeeded()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { photoAccess.refresh() }
            }
    }
}
