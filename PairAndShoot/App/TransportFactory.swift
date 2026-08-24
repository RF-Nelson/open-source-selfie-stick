import Foundation
import PairAndShootCore

/// Chooses the peer-to-peer transport. Wi-Fi Aware (iOS 26+) when available and enabled; otherwise
/// MultipeerConnectivity, which is also the fallback for iOS < 26 and for mixed-version pairs.
@MainActor
enum TransportFactory {
    /// UserDefaults flag toggled in Settings. Off by default until the Wi-Fi Aware system-pairing
    /// screen (DeviceDiscoveryUI) is wired up, so the app keeps using Multipeer for now.
    static let wifiAwarePreferenceKey = "useWiFiAware"

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
            return WiFiAwareTransport(displayName: displayName)
        }
        return MultipeerTransport(displayName: displayName)
    }
}
