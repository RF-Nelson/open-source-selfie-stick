import PairAndShootCore
import SwiftUI

/// Liquid Glass on iOS 26, a material below it.
struct GlassBackground: ViewModifier {
    var shape: AnyShape = AnyShape(Circle())

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

struct ControlButton: View {
    let systemImage: String
    let label: String
    var badge: String? = nil
    var isActive = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(isActive ? Color.black : Color.white)
                    .frame(width: 48, height: 48)
                    .background {
                        if isActive { Circle().fill(.white) }
                    }
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.yellow, in: Capsule())
                        .offset(x: 4, y: 2)
                }
            }
            .modifier(GlassBackground())
            // The visible control stays 48pt; the extra padding widens the tap target to ~56pt so
            // it isn't easy to miss (the close button especially, sitting over the live preview).
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}

struct ShutterButton: View {
    enum Look {
        case photo, record, stop, cancel, busy

        static func forState(_ state: CameraState?) -> Look {
            guard let state else { return .busy }
            if state.countdown != nil { return .cancel }
            if state.isBusy { return .busy }
            switch state.mode {
            case .photo: return .photo
            case .video: return state.isRecording ? .stop : .record
            }
        }
    }

    let look: Look
    var size: CGFloat = 88
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: size * 0.06)
                    .frame(width: size, height: size)
                switch look {
                case .photo:
                    Circle().fill(.white).frame(width: size * 0.8, height: size * 0.8)
                case .record:
                    Circle().fill(Theme.record).frame(width: size * 0.8, height: size * 0.8)
                case .stop:
                    RoundedRectangle(cornerRadius: size * 0.09).fill(Theme.record).frame(width: size * 0.4, height: size * 0.4)
                case .cancel:
                    Image(systemName: "xmark")
                        .font(.system(size: size * 0.34, weight: .bold))
                        .foregroundStyle(.white)
                case .busy:
                    ProgressView().tint(.white).controlSize(.large)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(ShutterPressStyle())
        .disabled(look == .busy)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch look {
        case .photo: "Take photo"
        case .record: "Start recording"
        case .stop: "Stop recording"
        case .cancel: "Cancel countdown"
        case .busy: "Working"
        }
    }
}

private struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ModeSwitch: View {
    let mode: CaptureMode
    let canRecord: Bool
    let isLocked: Bool
    let onSelect: (CaptureMode) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CaptureMode.allCases, id: \.self) { candidate in
                Button {
                    onSelect(candidate)
                } label: {
                    Text(candidate == .photo ? "PHOTO" : "VIDEO")
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(candidate == mode ? Color.black : Color.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background {
                            if candidate == mode { Capsule().fill(.white) }
                        }
                }
                .buttonStyle(.plain)
                .disabled(isLocked || (candidate == .video && !canRecord))
            }
        }
        .padding(4)
        .modifier(GlassBackground(shape: AnyShape(Capsule())))
        .opacity(isLocked ? 0.5 : 1)
    }
}

struct StatusPill: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text).lineLimit(1)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(GlassBackground(shape: AnyShape(Capsule())))
    }
}

struct CountdownOverlay: View {
    let seconds: Int

    var body: some View {
        Text("\(seconds)")
            .font(.numerals(180, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 16)
            .contentTransition(.numericText(countsDown: true))
            .animation(.snappy, value: seconds)
            .accessibilityLabel("\(seconds) seconds")
    }
}

struct RecordingBadge: View {
    let duration: TimeInterval
    var large = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.record)
                .frame(width: large ? 14 : 9, height: large ? 14 : 9)
            Text(Duration.seconds(Int(duration)).formatted(.time(pattern: .minuteSecond)))
                .font(large ? .numerals(64) : .footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .padding(.horizontal, large ? 0 : 12)
        .padding(.vertical, large ? 0 : 8)
        .background {
            if !large { Capsule().fill(.black.opacity(0.5)) }
        }
        .accessibilityLabel("Recording, \(Int(duration)) seconds")
    }
}

struct NoticeToast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 24)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct TransferBanner: View {
    let status: TransferStatus

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !status.isFinished {
                    ProgressView(value: status.fraction)
                        .tint(.white)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: 420)
    }

    private var kind: String { status.isVideo ? "video" : "photo" }

    private var title: String {
        switch status.phase {
        case .sending: "Sending \(kind) to the remote… \(Int(status.fraction * 100))%"
        case .sent: "Sent to the remote"
        case .receiving: "Receiving \(kind)… \(Int(status.fraction * 100))%"
        case .saving: "Saving to Photos…"
        case .saved: "Saved to Photos"
        case .failed(let reason): "Couldn't save the \(kind): \(reason)"
        }
    }

    private var icon: String {
        switch status.phase {
        case .sending, .sent: "arrow.up.circle"
        case .receiving: "arrow.down.circle"
        case .saving: "photo.badge.arrow.down"
        case .saved: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch status.phase {
        case .saved, .sent: Theme.success
        case .failed: Color.yellow
        default: Color.white
        }
    }
}

/// Shows a transfer while it runs and for a moment after it finishes.
struct TransferBannerHost: View {
    let transfer: TransferStatus?
    @State private var shown: TransferStatus?

    var body: some View {
        Group {
            if let shown {
                TransferBanner(status: shown)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: shown)
        .task(id: transfer) {
            guard let transfer else {
                shown = nil
                return
            }
            shown = transfer
            if transfer.isFinished {
                try? await Task.sleep(for: .seconds(2.5))
                if !Task.isCancelled { shown = nil }
            }
        }
    }
}

struct CaptureThumbnail: View {
    let result: CaptureResult?
    var size: CGFloat = 48

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(Theme.panelRaised)
                .frame(width: size, height: size)
            if let data = result?.thumbnailJPEG, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
            } else {
                Image(systemName: result?.kind == .video ? "video.fill" : "photo")
                    .font(.system(size: size * 0.36))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(width: size, height: size)
            }
            if let result, result.kind == .video {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill")
                    if let duration = result.duration {
                        Text(Duration.seconds(Int(duration)).formatted(.time(pattern: .minuteSecond)))
                    }
                }
                .font(.system(size: max(10, size * 0.09), weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(size * 0.05)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous).strokeBorder(.white.opacity(0.15)))
        .accessibilityLabel(result == nil ? "No captures yet" : (result?.kind == .video ? "Last video" : "Last photo"))
    }
}

/// Shown wherever a capture would be saved when Photos access has been refused.
struct PhotoAccessWarning: View {
    let access: PhotoLibraryAccess

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 3) {
                Text("Photos access is off")
                    .font(.subheadline.weight(.semibold))
                Text(access.status == .restricted
                     ? "This device doesn't allow saving to Photos, so nothing can be kept here."
                     : "Nothing can be saved to this device until you allow it in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if access.status == .denied {
                Button("Settings") { access.openSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.yellow)
            }
        }
        .padding(14)
        .background(Color.yellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.yellow.opacity(0.35)))
        .accessibilityElement(children: .combine)
    }
}


/// Opens the system Photos app so people can review what was saved this session.
enum ExternalApp {
    @MainActor static func openPhotos() {
        guard let url = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(url)
    }
}
