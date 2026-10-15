// Debug-only internal test mode (docs/TRANSPORT.md, 2026-10-10).
#if os(iOS) && DEBUG
import DeviceDiscoveryUI
import Network
import Observation
import ShotCallerCore
import SwiftUI
import WiFiAware

/// The one big pairing control. Both system views (`DevicePairingView`, `DevicePicker`) take a
/// label; this keeps them the same size as our own primary buttons.
struct PairButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: 360, minHeight: 56)
            .padding(.horizontal, 24)
            .background(Color.accentColor, in: Capsule())
    }
}

/// Camera side: `DevicePairingView` publishes the service and presents the system pairing UI when
/// tapped, making this device discoverable to a remote's picker. Mount it only while the transport
/// is suspended (`WiFiAwarePairingState.isPairing`): both would publish the same service.
@available(iOS 26.0, *)
struct CameraPairButton: View {
    var body: some View {
        if let service = WiFiAwarePairing.publishableService {
            DevicePairingView(
                WAPublisherListener.wifiAware(.connecting(to: service, from: .userSpecifiedDevices))
            ) {
                PairButtonLabel(title: "Pair remote", systemImage: "dot.radiowaves.left.and.right")
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
    }
}

/// Remote side: `DevicePicker` browses for pairable cameras and presents the system picker when
/// tapped. `onSelect` delivers the chosen endpoint once the picker has released the service.
@available(iOS 26.0, *)
struct RemotePairButton: View {
    var onPaired: (WAEndpoint) -> Void = { _ in }

    var body: some View {
        if let service = WiFiAwarePairing.subscribableService {
            DevicePicker(
                WASubscriberBrowser.wifiAware(.connecting(to: .userSpecifiedDevices, from: service)),
                onSelect: { endpoint in onPaired(endpoint) }
            ) {
                PairButtonLabel(title: "Pair camera", systemImage: "plus.circle")
            } fallback: {
                Text("Wi-Fi Aware isn’t available on this device.")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkMuted)
            }
        }
    }
}

/// Coordinates system pairing and data discovery, following Apple's sample: pair with the system
/// views, dismiss them, then let the listener/browser take the service. A picker selection is not
/// connected to directly; the remote waits for the browser to find that camera and connects to the
/// browsed endpoint. A remembered device isn't necessarily nearby; people can always enter pairing
/// again to add a different camera or remote.
@MainActor
@Observable
final class WiFiAwarePairingState {
    private(set) var hasPaired = false
    private(set) var isLoading = true
    private(set) var isPairing = false
    private(set) var error: String?
    /// The camera chosen in the system picker, until the browser reports it and we connect.
    private(set) var awaitingPeer: Peer?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var handoffTask: Task<Void, Never>?
    @ObservationIgnored private var transport: (any PeerTransport)?
    @ObservationIgnored private var knownIDs: Set<UInt64> = []
    @ObservationIgnored private var pairingIDs: Set<UInt64> = []
    @ObservationIgnored private var automaticallyFinishPairing = false
    @ObservationIgnored private var ownsPairingService = false
    @ObservationIgnored private var pairingToken = 0

    /// Only the camera automatically closes its pairing view when a new pairing is observed. The
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
                Trace.log("Wi-Fi Aware pairing state: \(current.count) paired device(s)")
                if current.isEmpty { self.beginPairing() }
                for try await devices in WAPairedDevice.allDevices {
                    guard !Task.isCancelled else { return }
                    let added = Set(devices.keys).subtracting(self.knownIDs)
                    if !added.isEmpty { Trace.log("Wi-Fi Aware pairing state: new paired device(s) \(added.sorted())") }
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
        awaitingPeer = nil
        isLoading = true
        pairingIDs = knownIDs
        handoffTask = Task { [weak self] in
            let token = await transport.suspendForPairing()
            guard let self, !Task.isCancelled else {
                // Stopped while suspending: hand the service back, unless a newer suspension owns it.
                transport.resumeAfterPairing(token: token)
                return
            }
            self.pairingToken = token
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

    /// The remote picked a camera in the system picker. Close the picker so the browser can take
    /// the service; the screen connects when that camera shows up in the browse results.
    @available(iOS 26.0, *)
    func select(endpoint: WAEndpoint) {
        guard let transport = transport as? WiFiAwareTransport else { return }
        awaitingPeer = transport.peer(forSelected: endpoint)
        endPairing()
    }

    /// Call with every change to the discovered cameras; returns the awaited camera once it appears.
    func awaitedCamera(in cameras: [Peer]) -> Peer? {
        guard let awaitingPeer, let found = cameras.first(where: { $0.id == awaitingPeer.id }) else { return nil }
        self.awaitingPeer = nil
        return found
    }

    func cancelAwaiting() {
        awaitingPeer = nil
    }

    func pairingControlDidDisappear() {
        guard #available(iOS 26.0, *), let transport = transport as? WiFiAwareTransport,
              ownsPairingService, !isPairing else { return }
        ownsPairingService = false
        transport.resumeAfterPairing(token: pairingToken)
    }

    func stop() {
        task?.cancel()
        task = nil
        handoffTask?.cancel()
        handoffTask = nil
        awaitingPeer = nil
        isPairing = false
        // Never disconnect here: the discovery view disappears when its selected connection starts.
        pairingControlDidDisappear()
    }
}

#endif
