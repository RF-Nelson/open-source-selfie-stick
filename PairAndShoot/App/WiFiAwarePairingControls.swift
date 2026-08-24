#if os(iOS)
import PairAndShootCore
import SwiftUI

/// Dark-screen card prompting the camera's owner to make it pairable over Wi-Fi Aware.
@available(iOS 26.0, *)
struct CameraPairButton: View {
    @State private var showing = false

    var body: some View {
        VStack(spacing: 10) {
            Text("Pair over Wi-Fi Aware")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundStyle(Theme.inkMuted)
            Button {
                showing = true
            } label: {
                Label("Pair a remote", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            Text("On the other device open Remote and tap “Pair a camera,” then confirm on both.")
                .font(.footnote)
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: 360)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .sheet(isPresented: $showing) {
            if let service = WiFiAwarePairing.publishableService {
                CameraPairingSheet(service: service).ignoresSafeArea()
            } else {
                PairingUnavailable()
            }
        }
    }
}

/// Button the remote shows to find and pair a camera over Wi-Fi Aware.
@available(iOS 26.0, *)
struct RemotePairButton: View {
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Label("Pair a camera", systemImage: "plus.circle")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .sheet(isPresented: $showing) {
            if let service = WiFiAwarePairing.subscribableService {
                RemotePairingPicker(service: service) { _ in showing = false }.ignoresSafeArea()
            } else {
                PairingUnavailable()
            }
        }
    }
}

private struct PairingUnavailable: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle)
            Text("Wi-Fi Aware isn’t available on this device.")
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}
#endif
