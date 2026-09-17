import Observation
import Photos
import UIKit

/// Add-only access to Photos, requested after the user chooses a role and opts to save copies.
/// The app can add captures without reading the person's existing library.
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
