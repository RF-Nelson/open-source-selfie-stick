import PairAndShootCore
import SwiftUI

struct CodeEntrySheet: View {
    let peer: Peer
    let onSubmit: (PairingCode) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                VStack(spacing: 8) {
                    Text("Enter the code shown on")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(peer.displayName)
                        .font(.title2.weight(.semibold))
                }
                .multilineTextAlignment(.center)

                ZStack {
                    HStack(spacing: 14) {
                        ForEach(0..<PairingCode.length, id: \.self) { index in
                            DigitBox(digit: digit(at: index), isCurrent: focused && text.count == index)
                        }
                    }
                    TextField("", text: $text)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($focused)
                        .frame(width: 1, height: 1)
                        .opacity(0.02)
                        .accessibilityLabel("Pairing code")
                }
                .contentShape(Rectangle())
                .onTapGesture { focused = true }

                Button {
                    submit()
                } label: {
                    Text("Connect")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(PairingCode(text) == nil)
                .frame(maxWidth: 320)

                Spacer()
            }
            .padding(.top, 32)
            .padding(.horizontal, 24)
            .onAppear { focused = true }
            .onChange(of: text) { _, newValue in
                let digits = String(newValue.filter(\.isNumber).prefix(PairingCode.length))
                if digits != newValue { text = digits }
                if digits.count == PairingCode.length { submit() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func digit(at index: Int) -> String {
        guard index < text.count else { return "" }
        return String(text[text.index(text.startIndex, offsetBy: index)])
    }

    private func submit() {
        guard let code = PairingCode(text) else { return }
        onSubmit(code)
        dismiss()
    }
}

private struct DigitBox: View {
    let digit: String
    let isCurrent: Bool

    var body: some View {
        Text(digit)
            .font(.numerals(34, weight: .bold))
            .monospacedDigit()
            .frame(width: 58, height: 72)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isCurrent ? Color.accentColor : Color.clear, lineWidth: 2)
            )
    }
}

#Preview {
    CodeEntrySheet(peer: Peer(id: "cam", displayName: "iPhone · A7")) { _ in }
}
