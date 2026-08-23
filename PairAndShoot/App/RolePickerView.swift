import SwiftUI

struct RolePickerView: View {
    let onSelect: (Role) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 14) {
                    AppMark()
                    Text("Pair & Shoot")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("Turn a second iPhone or iPad into a remote control for this one's camera.")
                        .font(.body)
                        .foregroundStyle(.secondary)
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
            }
            .padding(24)
        }
        .background(Color(.systemGroupedBackground))
    }
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
        "Open Pair & Shoot on both devices.",
        "Choose Camera on one and Remote on the other.",
        "Type the camera's 4-digit code on the remote. Then shoot.",
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
            Text("Works over Wi-Fi or Bluetooth. Photos come back to the remote in a few seconds on Wi-Fi; videos stay on the camera unless you ask for them.")
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
