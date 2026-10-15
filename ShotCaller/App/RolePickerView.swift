import SwiftUI

struct RolePickerView: View {
    let onSelect: (Role) -> Void
    @State private var showPrivacy = false
    #if DEBUG
    @AppStorage(TransportFactory.internalWiFiAwareKey) private var internalWiFiAware = false
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 14) {
                    AppMark()
                    Text("Shot Caller")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("Two devices. Everyone in the shot.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    Text("You’ll need two iPhones or iPads with Shot Caller installed.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .padding(.top, 24)

                VStack(spacing: 14) {
                    RoleCard(
                        title: "This device is the camera",
                        detail: "Set it down or hand it to a friend. It takes the photos and videos.",
                        systemImage: "camera.fill"
                    ) { onSelect(.camera) }
                    RoleCard(
                        title: "This device is the remote",
                        detail: "Keep it in your hand. It presses the shutter and can receive copies.",
                        systemImage: "dot.radiowaves.left.and.right"
                    ) { onSelect(.remote) }
                }

                HowItWorks()
                #if DEBUG
                internalTestOptions
                #endif
                Button { showPrivacy = true } label: {
                    Label("Privacy & help", systemImage: "hand.raised")
                        .frame(minHeight: 44)
                }
            }
            .padding(24)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $showPrivacy) { PrivacyHelpView() }
    }

    #if DEBUG
    /// Debug builds only: the Wi-Fi Aware transport as an internal test mode. Release builds have no
    /// connection choice at all; see TransportFactory.
    @ViewBuilder
    private var internalTestOptions: some View {
        if TransportFactory.wifiAwareSupported {
            VStack(alignment: .leading, spacing: 12) {
                Label("Internal test (Debug build)", systemImage: "wrench.and.screwdriver")
                    .font(.headline)
                Toggle("Internal test: Wi-Fi Aware", isOn: $internalWiFiAware)
                Text("Replaces the normal connection with Apple’s Wi-Fi Aware pairing. Both test devices need this on, iOS 26 and supported hardware. Not in the App Store build.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        }
    }
    #endif
}

private struct AppMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 92, height: 92)
            Image(systemName: "button.programmable")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }
}

private struct RoleCard: View {
    let title: String
    let detail: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.accentColor, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(18)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct HowItWorks: View {
    private let steps = [
        "Open Shot Caller on both devices.",
        "Choose Camera on one and Remote on the other.",
        "Choose the camera on the remote, enter the code shown on the camera, and take your shot.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How it works")
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22, height: 22)
                        .background(Color.accentColor.opacity(0.14), in: Circle())
                    Text(step)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
            }
            Text("Keep Bluetooth on and Shot Caller open on both devices. Join the same Wi-Fi network for faster photo and video transfers. No internet connection or account is needed. Videos stay on the camera unless you request copies.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

#Preview {
    RolePickerView { _ in }
}
