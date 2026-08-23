import SwiftUI

enum Role: String, Identifiable, CaseIterable {
    case camera, remote
    var id: String { rawValue }
}

struct RootView: View {
    @State private var role: Role?

    var body: some View {
        RolePickerView { role = $0 }
            .fullScreenCover(item: $role) { role in
                switch role {
                case .camera:
                    CameraScreen { self.role = nil }
                case .remote:
                    RemoteScreen { self.role = nil }
                }
            }
    }
}
