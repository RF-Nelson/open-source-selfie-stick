#if os(iOS)
import DeviceDiscoveryUI
import Network
import Observation
import ShotCallerCore
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
            Text("On the remote, tap “Pair a camera” and follow the system prompt. When pairing finishes, close the system panel and tap “Done pairing” here.")
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
/// tapped; `onSelect` delivers the selected endpoint to the transport after the picker releases the service.
@available(iOS 26.0, *)
struct RemotePairButton: View {
    var onPaired: (WAEndpoint) -> Void = { _ in }

    var body: some View {
        if let service = WiFiAwarePairing.subscribableService {
            DevicePicker(
                WASubscriberBrowser.wifiAware(.connecting(to: .userSpecifiedDevices, from: service)),
                onSelect: { endpoint in onPaired(endpoint) }
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

/// Coordinates system pairing and data discovery. A remembered device isn't necessarily nearby;
/// people can always enter pairing again to add a different camera or remote.
@MainActor
@Observable
final class WiFiAwarePairingState {
    private(set) var hasPaired = false
    private(set) var isLoading = true
    private(set) var isPairing = false
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var handoffTask: Task<Void, Never>?
    @ObservationIgnored private var transport: (any PeerTransport)?
    @ObservationIgnored private var knownIDs: Set<UInt64> = []
    @ObservationIgnored private var pairingIDs: Set<UInt64> = []
    @ObservationIgnored private var pendingSelection: (() -> Void)?
    @ObservationIgnored private var automaticallyFinishPairing = false
    @ObservationIgnored private var ownsPairingService = false

    /// Only the camera automatically closes its advertiser when a new pairing is observed. The
    /// remote must keep DevicePicker alive until onSelect delivers the selected endpoint.
    func start(transport: any PeerTransport, automaticallyFinishPairing: Bool = false) {
        guard task == nil else { return }
        self.transport = transport
        self.automaticallyFinishPairing = automaticallyFinishPairing
        guard #available(iOS 26.0, *), transport is WiFiAwareTransport else {
            isLoading = false
            return
        }
        isLoading = true
        task = Task { [weak self] in
            do {
                let current = try await WAPairedDevice.allDevices.current() ?? [:]
                guard let self, !Task.isCancelled else { return }
                self.knownIDs = Set(current.keys)
                self.hasPaired = !current.isEmpty
                self.isLoading = false
                if current.isEmpty { self.beginPairing() }
                for try await devices in WAPairedDevice.allDevices {
                    guard !Task.isCancelled else { return }
                    self.knownIDs = Set(devices.keys)
                    self.hasPaired = !devices.isEmpty
                    if self.isPairing, self.automaticallyFinishPairing,
                       !self.knownIDs.subtracting(self.pairingIDs).isEmpty {
                        self.endPairing()
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.isLoading = false
                self?.error = "Couldn’t check paired devices. You can still try pairing, or use Automatic connection."
            }
        }
    }

    func beginPairing() {
        guard #available(iOS 26.0, *), let transport = transport as? WiFiAwareTransport,
              !isPairing, handoffTask == nil else { return }
        error = nil
        isLoading = true
        pairingIDs = knownIDs
        handoffTask = Task { [weak self] in
            await transport.suspendForPairing()
            guard let self, !Task.isCancelled else {
                transport.resumeAfterPairing()
                return
            }
            self.ownsPairingService = true
            self.isPairing = true
            self.isLoading = false
            self.handoffTask = nil
        }
    }

    func endPairing() {
        isPairing = false
        // onDisappear is the handoff boundary: resuming here would overlap the two publishers.
    }

    @available(iOS 26.0, *)
    func select(endpoint: WAEndpoint, onReady: @escaping (Peer) -> Void) {
        guard let transport = transport as? WiFiAwareTransport else { return }
        pendingSelection = {
            onReady(transport.registerPairedEndpoint(endpoint))
        }
        endPairing()
    }

    func pairingControlDidDisappear() {
        guard #available(iOS 26.0, *), let transport = transport as? WiFiAwareTransport,
              ownsPairingService, !isPairing else { return }
        ownsPairingService = false
        transport.resumeAfterPairing()
        let selection = pendingSelection
        pendingSelection = nil
        selection?()
    }

    func stop() {
        task?.cancel()
        task = nil
        handoffTask?.cancel()
        handoffTask = nil
        pendingSelection = nil
        isPairing = false
        // Never disconnect here: the discovery view disappears when its selected connection starts.
        pairingControlDidDisappear()
    }
}

#endif
