import AVFoundation
import CoreImage
import Foundation
import ImageIO
import ShotCallerCore

/// Turns the capture session's video frames into the small upright JPEGs of the live view, on demand.
///
/// It sits on an `AVCaptureVideoDataOutput` as the sample-buffer delegate and does nothing with a
/// frame unless a request is armed: with no request the buffer is returned to AVFoundation at once,
/// so an enabled-but-idle tap costs almost nothing. One request is served at a time; a new request
/// replaces an unanswered one (which resolves to nil). Encoding happens on the output's serial queue,
/// never on the main actor, and only the finished `Data` crosses into the model.
final class PreviewFrameEncoder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private struct Request {
        let token: UUID
        let maxEdge: Int
        let maxBytes: Int
        let orientation: CGImagePropertyOrientation
        let continuation: CheckedContinuation<PreviewFrame?, Never>
    }

    private let lock = NSLock()
    private var pending: Request?
    private let context = CIContext(options: [.cacheIntermediates: false, .name: "ShotCaller.preview"])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Successive JPEG qualities tried until a frame fits `maxBytes`; then the frame is skipped.
    private let qualities: [CGFloat] = [0.6, 0.4, 0.25]

    /// Waits for the next frame and encodes it; nil when none arrives within `timeout` or none fits.
    func nextFrame(maxEdge: Int, maxBytes: Int, orientation: CGImagePropertyOrientation, timeout: TimeInterval) async -> PreviewFrame? {
        let token = UUID()
        return await withCheckedContinuation { continuation in
            let replaced = lock.withLock { () -> Request? in
                let previous = pending
                pending = Request(token: token, maxEdge: maxEdge, maxBytes: maxBytes, orientation: orientation, continuation: continuation)
                return previous
            }
            replaced?.continuation.resume(returning: nil)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.expire(token)
            }
        }
    }

    /// Drops any armed request (when the tap is detached) so no caller waits on a dead output.
    func cancelPending() {
        let request = lock.withLock { () -> Request? in
            let current = pending
            pending = nil
            return current
        }
        request?.continuation.resume(returning: nil)
    }

    private func expire(_ token: UUID) {
        let request = lock.withLock { () -> Request? in
            guard pending?.token == token else { return nil }
            let current = pending
            pending = nil
            return current
        }
        request?.continuation.resume(returning: nil)
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate (the output's serial queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let request = lock.withLock({ () -> Request? in
            let current = pending
            pending = nil
            return current
        }) else { return }   // nobody asked: hand the buffer straight back
        request.continuation.resume(returning: encode(sampleBuffer, for: request))
    }

    private func encode(_ sampleBuffer: CMSampleBuffer, for request: Request) -> PreviewFrame? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(request.orientation)
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)
        guard longEdge > 0 else { return nil }
        let scale = min(1, CGFloat(request.maxEdge) / longEdge)
        if scale < 1 {
            image = image.samplingLinear().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        // Pin the origin and crop to whole pixels so the JPEG covers exactly the dimensions advertised.
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y))
        let width = Int(image.extent.width.rounded(.down))
        let height = Int(image.extent.height.rounded(.down))
        guard width > 0, height > 0 else { return nil }
        image = image.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        for quality in qualities {
            let options: [CIImageRepresentationOption: Any] = [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
            ]
            guard let data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else { return nil }
            if data.count <= request.maxBytes {
                return PreviewFrame(jpeg: data, width: width, height: height)
            }
        }
        return nil   // too detailed to fit at any quality: skip this one
    }
}
