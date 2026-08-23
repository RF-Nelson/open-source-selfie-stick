#if targetEnvironment(simulator)
import Foundation
import PairAndShootCore
import UIKit

/// The Simulator has no camera. This produces a generated JPEG so the rest of the app can be exercised.
final class SimulatedCameraDevice: CameraDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var settings = CameraSettings()
    private var count = 0

    func start() async throws -> CameraCapabilities {
        CameraCapabilities(hasFlash: true, hasFrontCamera: true, canRecordVideo: false)
    }

    func stop() async {}

    func apply(_ settings: CameraSettings) async throws {
        lock.withLock { self.settings = settings }
    }

    func capturePhoto() async throws -> CapturedPhoto {
        let (settings, index) = lock.withLock { () -> (CameraSettings, Int) in
            count += 1
            return (self.settings, count)
        }
        let image = await MainActor.run {
            let size = CGSize(width: 1200, height: 1600)
            return UIGraphicsImageRenderer(size: size).image { context in
                let colors = [UIColor.systemIndigo.cgColor, UIColor.systemTeal.cgColor] as CFArray
                let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
                let text = "Simulated photo #\(index)\n\(settings.position.rawValue) camera · flash \(settings.flash.rawValue)"
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 56, weight: .semibold),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: style,
                ]
                text.draw(in: CGRect(x: 60, y: size.height / 2 - 100, width: size.width - 120, height: 240), withAttributes: attributes)
            }
        }
        guard let data = image.jpegData(compressionQuality: 0.85) else { throw CameraDeviceError.failed("Couldn't render the simulated photo.") }
        return CapturedPhoto(data: data, fileExtension: "jpg")
    }

    func startRecording() async throws {
        throw CameraDeviceError.failed("Video isn't available in the Simulator.")
    }

    func stopRecording() async throws -> RecordedMovie {
        throw CameraDeviceError.notRecording
    }

    func recordingDuration() async -> TimeInterval { 0 }
}
#endif
