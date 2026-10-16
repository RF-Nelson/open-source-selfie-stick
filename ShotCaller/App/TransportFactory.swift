import Foundation
import ShotCallerCore

/// Chooses the peer-to-peer transport. The shipping app always uses the layered transport: Bluetooth
/// for control everywhere, with an automatic Wi-Fi fast lane for file transfer when the two devices
/// are reachable. That path works on every supported device, so two devices can never end up on
/// transports that cannot see each other.
///
/// Wi-Fi Aware (iOS 26+, supported hardware only) exists in Debug builds as an internal test mode
/// while its reliability is being proven; see docs/TRANSPORT.md for the design of its return as an
/// opt-in transfer upgrade inside a connected session. Release builds compile none of this selection.
@MainActor
enum TransportFactory {
    static func make(displayName: String) -> any PeerTransport {
        #if DEBUG
        // Simulator screenshots: both roles in one process over a linked in-memory pair.
        if let mode = ScreenshotMode.current { return mode.transport(for: mode.scene.role) }
        if #available(iOS 26.0, *), internalWiFiAwareEnabled {
            UserDefaults.standard.set(true, forKey: wifiAwarePendingKey)
            return WiFiAwareTransport(displayName: displayName)
        }
        #endif
        return LayeredTransport(displayName: displayName)
    }

    /// Call once a transport has begun advertising/browsing without crashing.
    static func markStarted() {
        #if DEBUG
        UserDefaults.standard.set(false, forKey: wifiAwarePendingKey)
        #endif
    }

    /// Call at launch. Debug only: recover from an internal Wi-Fi Aware start that crashed by turning
    /// the test mode off, so a crash loop cannot trap the tester.
    static func recoverIfWiFiAwareCrashed() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: wifiAwarePendingKey) {
            UserDefaults.standard.set(false, forKey: internalWiFiAwareKey)
            UserDefaults.standard.set(false, forKey: wifiAwarePendingKey)
        }
        #endif
    }

    #if DEBUG
    /// Internal test mode, Debug builds only. A new key: the old `useWiFiAware` preference that once
    /// chose the transport in every build is never read again.
    static let internalWiFiAwareKey = "internalWiFiAwareTestMode"
    /// Set true while a Wi-Fi Aware transport is starting; cleared once it starts.
    static let wifiAwarePendingKey = "wifiAwareStartPending"

    /// Whether this device can do Wi-Fi Aware at all (iOS 26 + hardware support).
    static var wifiAwareSupported: Bool {
        if #available(iOS 26.0, *) { return WiFiAwareTransport.isSupported }
        return false
    }

    static var internalWiFiAwareEnabled: Bool {
        wifiAwareSupported && UserDefaults.standard.bool(forKey: internalWiFiAwareKey)
    }
    #endif
}
