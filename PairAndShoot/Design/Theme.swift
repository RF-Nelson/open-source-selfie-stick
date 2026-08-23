import SwiftUI

/// The operating screens (camera and remote) are always dark, like every camera app: the content
/// is the picture, the chrome stays out of its way. The role picker follows the system appearance.
enum Theme {
    static let record = Color(red: 0.96, green: 0.27, blue: 0.23)
    static let canvas = Color.black
    static let panel = Color(white: 0.11)
    static let panelRaised = Color(white: 0.17)
    static let inkMuted = Color.white.opacity(0.62)
    static let success = Color(red: 0.36, green: 0.80, blue: 0.55)
}

extension Font {
    /// Big numerals for countdowns, codes and clocks.
    static func numerals(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}
