import SwiftUI
import ShotCallerCore

@main
struct ShotCallerApp: App {
    init() {
        // Truncate the on-device trace log once per launch, whichever transport runs. Previously only
        // WiFiAwareTransport reset it, so Multipeer-only launches accumulated stale lines across runs
        // and made the log ambiguous (e.g. old Wi-Fi Aware "listener" lines bleeding into an MPC run).
        Trace.reset()
        // Debug only: if the internal Wi-Fi Aware test mode crashed while starting last time, turn it
        // off before the home screen can offer a role.
        TransportFactory.recoverIfWiFiAwareCrashed()
        #if DEBUG
        // Simulator screenshots: stage the session (names, preferences) before any screen reads them.
        _ = ScreenshotMode.current
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
