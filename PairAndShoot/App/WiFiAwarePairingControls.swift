#if os(iOS)
import DeviceDiscoveryUI
import Network
import PairAndShootCore
import SwiftUI
import WiFiAware

/// Camera side: a Wi-Fi Aware pairing control. `DevicePairingView` publishes the service and presents
/// the system pairing UI when tapped, making this device discoverable to a remote's picker.
@available(iOS 26.0, *)
struct CameraPairButton: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Pair over Wi-Fi Aware")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundStyle(Theme.inkMuted)
            if let service = WiFiAwarePairing.publishableService {
                DevicePairingView(
                    WAPublisherListener.wifiAware(.connecting(to: service, from: .userSpecifiedDevices))
                ) {
                    Label("Pair a remote", systemImage: "dot.radiowaves.left.and.right")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Color.accentColor, in: Capsule())
                } fallback: {
                    Text("Wi-Fi Aware isn’t available on this device.")
                        .font(.footnote)
                        .foregroundStyle(Theme.inkMuted)
                }
            } else {
                Text("Wi-Fi Aware service isn’t configured.")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkMuted)
            }
            Text("On the other device open Remote and tap “Pair a camera,” then confirm on both.")
                .font(.footnote)
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: 360)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}

/// Remote side: `DevicePicker` browses for pairable cameras and presents the system picker when
/// tapped; `onSelect` delivers the paired endpoint. After pairing, the transport's browse finds the
/// now-paired camera and it appears in the list to connect.
@available(iOS 26.0, *)
struct RemotePairButton: View {
    var onPaired: () -> Void = {}

    var body: some View {
        if let service = WiFiAwarePairing.subscribableService {
            DevicePicker(
                WASubscriberBrowser.wifiAware(.connecting(to: .userSpecifiedDevices, from: service)),
                onSelect: { _ in onPaired() }
            ) {
                Label("Pair a camera", systemImage: "plus.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.14), in: Capsule())
            } fallback: {
                Text("Wi-Fi Aware isn’t available on this device.")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkMuted)
            }
        }
    }
}
#endif
