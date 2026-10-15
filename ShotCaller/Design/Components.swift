import ShotCallerCore
import SwiftUI

/// Liquid Glass on iOS 26, a material below it.
/// A half-height sheet on iPad opens as a short form sheet that only grows once scrolled (seen
/// 2026-10-15): iPad sheets open full; iPhone keeps the half-height detent.
enum Sheets {
    static var detents: Set<PresentationDetent> {
        UIDevice.current.userInterfaceIdiom == .pad ? [.large] : [.medium, .large]
    }
}

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
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(isActive ? Color.black : Color.white)
                .frame(width: 48, height: 48)
                .background {
                    if isActive { Circle().fill(.white) }
                }
                .modifier(GlassBackground())
                // The badge sits ON TOP of the glass as an overlay; keeping it inside the glass layer
                // let the tap re-composite momentarily draw it behind the button.
                .overlay(alignment: .bottomTrailing) {
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
                // The visible control stays 48pt; the extra padding widens the tap target to ~56pt so
                // it isn't easy to miss (the close button especially, sitting over the live preview).
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(label)
        .accessibilityValue(badge ?? (isActive ? "On" : ""))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
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
                        .frame(minHeight: 44)
                        .background {
                            if candidate == mode { Capsule().fill(.white) }
                        }
                }
                .buttonStyle(.plain)
                .disabled(isLocked || (candidate == .video && !canRecord))
                .accessibilityLabel(candidate == .photo ? "Photo mode" : "Video mode")
                .accessibilityAddTraits(candidate == mode ? [.isSelected] : [])
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

/// How captures travel on the current link: a fast Wi-Fi lane, or Bluetooth alone (control always
/// rides Bluetooth; the Wi-Fi lane is the bonus that makes photos/videos fast). Renders nothing when
/// the transport is single-channel and the speed is unknown (`fast == nil`).
struct ChannelPill: View {
    let fast: Bool?

    var body: some View {
        if let fast {
            StatusPill(text: fast ? "Wi-Fi" : "Bluetooth",
                       systemImage: fast ? "wifi" : "antenna.radiowaves.left.and.right",
                       tint: fast ? Theme.success : Theme.inkMuted)
        }
    }
}

struct CountdownOverlay: View {
    let seconds: Int
    var size: CGFloat = 180

    var body: some View {
        Text("\(seconds)")
            .font(.numerals(size, weight: .bold))
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

/// On the camera while a remote receives the live view: who is watching. Ending it is the same as
/// ending the session (disconnect the remote); a separate Stop was dropped on 2026-10-11.
struct LiveViewSharingPill: View {
    let viewer: String

    var body: some View {
        StatusPill(text: "Sharing live view with \(viewer)", systemImage: "dot.radiowaves.up.forward", tint: .white)
    }
}

/// The remote's live view: the latest frame, aspect-fit, with the status and the camera's countdown
/// or recording clock over it. Frames are small JPEGs the camera already rotated upright.
struct LiveViewStage: View {
    /// The decoded picture (see `LivePreviewPresenter`); `frame` supplies its dimensions.
    let image: UIImage?
    let frame: PreviewFrame?
    let status: RemoteModel.PreviewStatus
    let state: CameraState?

    private var aspect: CGFloat {
        guard let frame, frame.width > 0, frame.height > 0 else { return 4.0 / 3.0 }
        return CGFloat(frame.width) / CGFloat(frame.height)
    }

    private var isStalled: Bool { status == .stalled }

    private var caption: String? {
        switch status {
        case .starting: frame == nil ? "Connecting live view…" : nil
        case .stalled: "Live view paused"
        case .paused(let words): words
        case .live, .off, .unavailable: nil
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.panel)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .opacity(isStalled ? 0.45 : 1)
                    .animation(.easeOut(duration: 0.25), value: isStalled)
            } else if status == .starting {
                ProgressView().tint(.white)
            }
            if let seconds = state?.countdown {
                CountdownOverlay(seconds: seconds, size: 120)
            }
            VStack {
                HStack {
                    StatusPill(text: status == .live ? "Live" : (status == .starting ? "Connecting" : "Paused"),
                               systemImage: status == .live ? "dot.radiowaves.left.and.right" : (status == .starting ? "ellipsis" : "pause.fill"),
                               tint: status == .live ? Theme.success : Theme.inkMuted)
                    Spacer()
                    if let state, state.isRecording {
                        RecordingBadge(duration: state.recordingDuration)
                    }
                }
                Spacer()
                if let caption {
                    Text(caption)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.55), in: Capsule())
                }
            }
            .padding(12)
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status == .live ? "Live view from the camera" : (caption ?? "Live view"))
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
                    .fixedSize(horizontal: false, vertical: true)
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
        case .failed(let reason): "Transfer didn’t finish: \(reason)"
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

/// Shows a transfer live while it runs (progress updates as it goes) and hides a moment after it
/// finishes. Bound directly to `transfer` so the progress bar tracks every update.
struct TransferBannerHost: View {
    let transfer: TransferStatus?
    @State private var hidden = false

    var body: some View {
        Group {
            if let transfer, !hidden {
                TransferBanner(status: transfer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: transfer == nil || hidden)
        .task(id: transfer) {
            hidden = false
            guard let transfer, transfer.isFinished else { return }
            if case .failed = transfer.phase { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            hidden = true
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
        .accessibilityElement(children: .contain)
    }
}


/// A thumbnail is a preview, not proof that the original has been saved.
struct CapturePreviewSheet: View {
    let capture: CaptureResult
    let savedHere: Bool
    @Environment(\.dismiss) private var dismiss

    private var duration: String? {
        capture.duration.map { Duration.seconds(Int($0)).formatted(.time(pattern: .minuteSecond)) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if capture.kind == .video {
                        // Set expectations before the image: this sheet never plays video.
                        Label(duration.map { "Still frame from your \($0) video" } ?? "Still frame from your video",
                              systemImage: "video.fill")
                            .font(.headline)
                        Text(savedHere
                             ? "The app doesn’t play video. Watch it in the Photos app on this device."
                             : "The app doesn’t play video. Once the original is saved or downloaded, watch it in Photos.")
                            .foregroundStyle(.secondary)
                    }
                    if let data = capture.thumbnailJPEG, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .overlay(alignment: .bottomLeading) {
                                if capture.kind == .video {
                                    Text("STILL FRAME")
                                        .font(.caption2.weight(.bold)).tracking(1.2)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(.black.opacity(0.6), in: Capsule())
                                        .padding(12)
                                }
                            }
                            .accessibilityLabel(capture.kind == .video ? "Still frame from the video" : "Photo preview")
                    }
                    Label(savedHere ? "Saved to Photos on this device" : "Original not on this device",
                          systemImage: savedHere ? "checkmark.circle" : "photo")
                        .font(.headline)
                    Text(savedHere
                         ? "Open the Photos app to view, edit, or share the original."
                         : "This is a small preview. Check the session’s save or download status for the original.")
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(capture.kind == .video ? "Last video" : "Last photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct PendingSavesBanner: View {
    let count: Int
    let retry: () -> Void
    @Environment(PhotoLibraryAccess.self) private var photoAccess

    var body: some View {
        if count > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(count) \(count == 1 ? "shot is" : "shots are") waiting to save", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))
                Text("Keep this session open until your originals are saved.")
                    .font(.footnote)
                Button(photoAccess.isDenied ? "Open Settings" : "Retry saving") {
                    if photoAccess.isDenied { photoAccess.openSettings() } else { retry() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .foregroundStyle(.white)
            .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
