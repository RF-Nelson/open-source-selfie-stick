import SwiftUI
import PairAndShootCore

@main
struct PairAndShootApp: App {
    init() {
        // Truncate the on-device trace log once per launch, whichever transport runs. Previously only
        // WiFiAwareTransport reset it, so Multipeer-only launches accumulated stale lines across runs
        // and made the log ambiguous (e.g. old Wi-Fi Aware "listener" lines bleeding into an MPC run).
        Trace.reset()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
