import Observation
import Photos
import UIKit

/// Add-only access to the Photos library, asked for once when the app first opens so the
/// permission prompt never interrupts the first shot. Both roles need it: the camera keeps
/// its copies here, the remote saves what it receives.
@MainActor
@Observable
final class PhotoLibraryAccess {
    private(set) var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)

    var isGranted: Bool { status == .authorized || status == .limited }
    var isDenied: Bool { status == .denied || status == .restricted }

    /// Shows the system prompt the first time; later launches just read the stored answer.
    func requestIfNeeded() async {
        refresh()
        guard status == .notDetermined else { return }
        status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    /// Call when the app returns to the foreground: the person may have changed the setting.
    func refresh() {
        status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
