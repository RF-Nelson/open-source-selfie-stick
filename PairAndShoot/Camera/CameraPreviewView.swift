import AVFoundation
import PairAndShootCore
import SwiftUI
import UIKit

/// Bridges the SwiftUI focus tap to the UIKit preview: converts a tap point to a device point and
/// shows the focus indicator. Focus is driven from a SwiftUI gesture in `CameraScreen` (not a UIKit
/// recognizer on the preview) so that controls layered on top win the tap — otherwise a tap on the
/// close button reads as a focus tap on the frame behind it.
@MainActor
final class PreviewController {
    weak var view: PreviewUIView?

    /// Returns the capture-device point for a tap in the preview's coordinate space, and flashes the
    /// focus indicator there. Returns nil when there is no preview yet.
    func focus(at layerPoint: CGPoint) -> CGPoint? {
        guard let view else { return nil }
        view.showFocusIndicator(at: layerPoint)
        return view.devicePoint(for: layerPoint)
    }
}

/// Full-bleed live preview. Owns its own rotation coordinator so the preview follows the horizon
/// without the capture actor ever touching a layer.
struct CameraPreviewView: UIViewRepresentable {
    let source: PreviewSource
    let position: CameraPosition
    let controller: PreviewController

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = source.session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.position = position
        view.refreshRotation()
        controller.view = view
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        controller.view = view
        if view.position != position {
            view.position = position
            view.refreshRotation()
        } else if view.needsRotationSetup {
            view.refreshRotation()
        }
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var position: CameraPosition = .back
    var needsRotationSetup: Bool { rotationCoordinator == nil }

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private let focusIndicator = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        focusIndicator.layer.borderColor = UIColor.systemYellow.cgColor
        focusIndicator.layer.borderWidth = 1.5
        focusIndicator.layer.cornerRadius = 4
        focusIndicator.frame = CGRect(x: 0, y: 0, width: 72, height: 72)
        focusIndicator.alpha = 0
        focusIndicator.isUserInteractionEnabled = false
        addSubview(focusIndicator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func devicePoint(for layerPoint: CGPoint) -> CGPoint {
        previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
    }

    func showFocusIndicator(at layerPoint: CGPoint) {
        focusIndicator.center = layerPoint
        focusIndicator.transform = CGAffineTransform(scaleX: 1.4, y: 1.4)
        focusIndicator.alpha = 1
        UIView.animate(withDuration: 0.25) {
            self.focusIndicator.transform = .identity
        }
        UIView.animate(withDuration: 0.3, delay: 0.8) {
            self.focusIndicator.alpha = 0
        }
    }

    func refreshRotation() {
        guard let session = previewLayer.session else { return }
        let device = session.inputs
            .compactMap { ($0 as? AVCaptureDeviceInput)?.device }
            .first { $0.hasMediaType(.video) }
        guard let device else {
            rotationCoordinator = nil
            return
        }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        apply(angle: coordinator.videoRotationAngleForHorizonLevelPreview)
        let box = WeakBox(self)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor in
                box.value?.apply(angle: angle)
            }
        }
    }

    private func apply(angle: CGFloat) {
        guard let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }
}

final class WeakBox<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}
