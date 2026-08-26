import AVFoundation
import Foundation
import ImageIO
import PairAndShootCore
import UIKit

/// Small JPEG previews that ride along with capture results (a few tens of kilobytes).
struct ImageThumbnailMaker: ThumbnailMaker {
    private let maxPixels = 360

    func thumbnail(forPhoto data: Data) async -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.7)
    }

    func compressedPhoto(data: Data, quality: TransferQuality) async -> Data? {
        let target: (maxPixels: Int, jpeg: CGFloat)
        switch quality {
        case .full: return nil   // send the original
        case .high: target = (2400, 0.8)
        case .medium: target = (1280, 0.62)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target.maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: target.jpeg)
    }

    func thumbnail(forVideoAt url: URL) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.7)
    }
}
