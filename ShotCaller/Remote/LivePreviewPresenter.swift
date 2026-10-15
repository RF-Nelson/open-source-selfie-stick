import ShotCallerCore
import SwiftUI
import UIKit

/// Turns the remote model's latest live-view frame into a display-ready image off the main actor, so
/// the stage draws a decoded bitmap instead of decoding a JPEG inside its body on every update. A
/// newer frame supersedes an older decode still in flight.
@MainActor
@Observable
final class LivePreviewPresenter {
    private(set) var image: UIImage?
    @ObservationIgnored private var generation = 0

    func show(_ frame: PreviewFrame?) {
        generation += 1
        let current = generation
        guard let frame else {
            image = nil
            return
        }
        let data = frame.jpeg
        Task.detached(priority: .userInitiated) { [weak self] in
            let decoded = UIImage(data: data)?.preparingForDisplay()
            await MainActor.run {
                guard let self, self.generation == current else { return }
                self.image = decoded
            }
        }
    }
}
