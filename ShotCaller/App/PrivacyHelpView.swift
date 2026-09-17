import SwiftUI

/// The policy is bundled from docs/PRIVACY.md so the in-app and published copies share one source.
struct PrivacyHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Connect your devices") {
                    Text("Open Shot Caller on both devices. With Automatic connection selected, choose Camera on the one taking the picture and Remote on the one in your hand. On the remote, select the camera and enter its four-digit code.")
                    Text("Keep Bluetooth and Wi-Fi on, and keep both apps open. Bluetooth carries camera controls. Wi-Fi transfers full photos and videos faster when available.")
                    Text("For Wi-Fi Aware, turn it on in the Connection section of both home screens before choosing roles. Both devices need compatible hardware and iOS 26 or later. Open the camera's pairing control, then pair it from the remote using Apple's system prompt. No four-digit app code is needed.")
                    Text("After confirming system pairing, tap Done pairing on the camera if its pairing panel is still open. This lets the selected remote connect, including when you pair a device you have used before.")
                }
                Section("Copies and permissions") {
                    Text("Choose where to keep full copies in each role's settings. The remote receives a small preview of each capture. If a full copy is waiting, tap Download or connect both devices to the same Wi-Fi network.")
                    Text("Camera access is needed only on the camera device. Allow Microphone to record videos with sound; photos still work if it is denied. Photos access saves pictures and videos without reading your existing library. You can change permissions in Settings.")
                }
                Section("Privacy") {
                    NavigationLink {
                        PrivacyPolicyView()
                    } label: {
                        Label("Privacy policy", systemImage: "hand.raised")
                    }
                    Text("No account, advertising, or analytics. Your captures travel directly between the devices you pair.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Link(destination: URL(string: "https://github.com/RF-Nelson/open-source-selfie-stick/issues")!) {
                        Label("Contact support on GitHub", systemImage: "arrow.up.right.square")
                    }
                } header: {
                    Text("Help and feedback")
                } footer: {
                    Text("GitHub reports are public and require a GitHub account to post. Include your device models, iOS versions, and what happened. Keep private photos, pairing codes, and personal information out of your report.")
                }
                Section {
                    LabeledContent("Version", value: DeviceIdentity.appVersion)
                }
            }
            .navigationTitle("Privacy & Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct PrivacyPolicyView: View {
    private let paragraphs: [String] = {
        guard let url = Bundle.main.url(forResource: "PRIVACY", withExtension: "md"),
              let policy = try? String(contentsOf: url, encoding: .utf8) else {
            return ["The privacy policy could not be opened. Please contact support through the Privacy & Help screen."]
        }
        return policy.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("# ") }
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    if paragraph.hasPrefix("## ") {
                        Text(String(paragraph.dropFirst(3)))
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.top, 8)
                    } else {
                        Text(.init(paragraph))
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Privacy policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
