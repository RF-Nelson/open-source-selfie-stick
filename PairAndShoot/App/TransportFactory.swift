import Foundation
import PairAndShootCore

/// Chooses the peer-to-peer transport. By default the layered transport — Bluetooth for control
/// everywhere, with an automatic Wi-Fi fast lane for file transfer when the two devices are reachable.
/// Wi-Fi Aware (iOS 26+) stays available as an experimental opt-in for devices that want the system
/// pairing path instead.
@MainActor
enum TransportFactory {
    /// UserDefaults flag toggled in Settings. Opts into the experimental Wi-Fi Aware path instead of
    /// the default layered transport.
    static let wifiAwarePreferenceKey = "useWiFiAware"
    /// Set true while a Wi-Fi Aware transport is starting; cleared once it starts. If it's still set
    /// at the next launch, the last attempt didn't finish (likely crashed), so we turn Wi-Fi Aware
    /// off to avoid a crash loop the user can't escape (Settings lives behind a role screen).
    static let wifiAwarePendingKey = "wifiAwareStartPending"

    /// Whether this device can do Wi-Fi Aware at all (iOS 26 + hardware support).
    static var wifiAwareSupported: Bool {
        if #available(iOS 26.0, *) { return WiFiAwareTransport.isSupported }
        return false
    }

    static var wifiAwareEnabled: Bool {
        wifiAwareSupported && UserDefaults.standard.bool(forKey: wifiAwarePreferenceKey)
    }

    static func make(displayName: String) -> any PeerTransport {
        if #available(iOS 26.0, *), wifiAwareEnabled {
            UserDefaults.standard.set(true, forKey: wifiAwarePendingKey)
            return WiFiAwareTransport(displayName: displayName)
        }
        // Default: Bluetooth control + automatic Wi-Fi fast lane for files when reachable.
        return LayeredTransport(displayName: displayName)
    }

    /// Call once a transport has begun advertising/browsing without crashing.
    static func markStarted() {
        UserDefaults.standard.set(false, forKey: wifiAwarePendingKey)
    }

    /// Call at launch: recover from a Wi-Fi Aware start that crashed by turning the option off.
    static func recoverIfWiFiAwareCrashed() {
        if UserDefaults.standard.bool(forKey: wifiAwarePendingKey) {
            UserDefaults.standard.set(false, forKey: wifiAwarePreferenceKey)
            UserDefaults.standard.set(false, forKey: wifiAwarePendingKey)
        }
    }
}
