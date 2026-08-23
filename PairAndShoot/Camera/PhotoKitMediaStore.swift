import Foundation
import PairAndShootCore
import Photos

/// Saves captures into the Photos library with add-only permission: the app can add pictures but never read them.
struct PhotoKitMediaStore: MediaStore {
    func savePhoto(data: Data, fileExtension: String) async throws {
        try await ensureAuthorized()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = "PairAndShoot.\(fileExtension)"
            request.addResource(with: .photo, data: data, options: options)
        }
    }

    func saveVideo(fileURL: URL) async throws {
        try await ensureAuthorized()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            request.addResource(with: .video, fileURL: fileURL, options: options)
        }
    }

    private func ensureAuthorized() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard status == .authorized || status == .limited else {
            throw CameraDeviceError.permissionDenied("photo library")
        }
    }
}
