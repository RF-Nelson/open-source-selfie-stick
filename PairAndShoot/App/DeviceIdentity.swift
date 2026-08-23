import Foundation
import UIKit

@MainActor
enum DeviceIdentity {
    static let nicknameKey = "nickname"

    /// What other devices see. Since iOS 16 `UIDevice.name` is just "iPhone" for everyone, so without a
    /// nickname the model name gets a short, stable suffix the person can read off the screen.
    static var displayName: String {
        let nickname = UserDefaults.standard.string(forKey: nicknameKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !nickname.isEmpty { return nickname }
        return "\(UIDevice.current.model) · \(suffix)"
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private static var suffix: String {
        let key = "deviceSuffix"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        let value = String((0..<2).map { _ in alphabet.randomElement()! })
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
}
