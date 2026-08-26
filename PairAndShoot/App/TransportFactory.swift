import Foundation
import PairAndShootCore

/// Chooses the peer-to-peer transport. Wi-Fi Aware (iOS 26+) when available and enabled; otherwise
/// MultipeerConnectivity, which is also the fallback for iOS < 26 and for mixed-version pairs.
@MainActor
enum TransportFactory {
    /// UserDefaults flag toggled in Settings. Off by default until the Wi-Fi Aware system-pairing
    /// screen (DeviceDiscoveryUI) is wired up, so the app keeps using Multipeer for now.
    static let wifiAwarePreferenceKey = "useWiFiAware"
    /// Set true while a Wi-Fi Aware transport is starting; cleared once it starts. If it's still set
    /// at the next launch, the last attempt didn't finish (likely crashed), so we turn Wi-Fi Aware
    /// off to avoid a crash loop the user can't escape (Settings lives behind a role screen).
    static let wifiAwarePendingKey = "wifiAwareStartPending"
    /// UserDefaults flag toggled in Settings. Routes to the Bluetooth-only transport (control works with
    /// no Wi-Fi at all; photos/videos can't travel back). Stage 1 of the layered design — a debug/opt-in
    /// path for now, to be superseded by the automatic layered transport.
    static let bluetoothPreferenceKey = "useBluetooth"

    static var bluetoothEnabled: Bool {
        UserDefaults.standard.bool(forKey: bluetoothPreferenceKey)
    }

    /// Whether this device can do Wi-Fi Aware at all (iOS 26 + hardware support).
    static var wifiAwareSupported: Bool {
        if #available(iOS 26.0, *) { return WiFiAwareTransport.isSupported }
        return false
    }

    static var wifiAwareEnabled: Bool {
        wifiAwareSupported && UserDefaults.standard.bool(forKey: wifiAwarePreferenceKey)
    }

    static func make(displayName: String) -> any PeerTransport {
        if bluetoothEnabled {
            // Bluetooth-primary with an automatic Wi-Fi fast lane for file transfer when reachable.
            return LayeredTransport(displayName: displayName)
        }
        if #available(iOS 26.0, *), wifiAwareEnabled {
            UserDefaults.standard.set(true, forKey: wifiAwarePendingKey)
            return WiFiAwareTransport(displayName: displayName)
        }
        return MultipeerTransport(displayName: displayName)
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
