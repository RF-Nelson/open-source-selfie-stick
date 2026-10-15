import SwiftUI

/// The policy is bundled from docs/PRIVACY.md so the in-app and published copies share one source.
struct PrivacyHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Connect your devices") {
                    Text("You need two iPhones or iPads with Shot Caller installed. Choose Camera on the one taking the picture and Remote on the one in your hand. On the remote, select the camera and enter the four-digit code shown on its screen.")
                    Text("Keep Bluetooth on and both apps open. Bluetooth carries the camera controls. Joining both devices to the same Wi-Fi network makes full photo and video transfers much faster; without it, copies can still be downloaded over Bluetooth.")
                    Text("On a shared Wi-Fi network the remote also shows a live view of what the camera sees, a few frames a second. Those frames go straight to the remote and are not saved on either device. The camera shows who is watching; disconnecting the remote ends it, and the remote can turn live view off in its settings.")
                    Text("If the camera does not appear on the remote: check that Bluetooth is allowed for Shot Caller in Settings on both devices, keep the devices within a few metres of each other, and make sure both are running the current version of the app.")
                }
                Section("Copies and permissions") {
                    Text("Choose where to keep full copies in each role's settings. The remote receives a small preview of each capture. If a full copy is waiting, tap Download or connect both devices to the same Wi-Fi network.")
                    Text("Camera access is needed only on the camera device. Allow Microphone to record videos with sound; if it is denied, videos record without sound. Photos access saves pictures and videos without reading your existing library. You can change permissions in Settings.")
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
