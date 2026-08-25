#if os(iOS)
import DeviceDiscoveryUI
import Network
import PairAndShootCore
import SwiftUI
import UIKit
import WiFiAware

/// Helpers for Wi-Fi Aware system pairing. Devices must be paired at the OS level (persistently)
/// before the transport can connect; these present the system pairing UI to do that once.
@available(iOS 26.0, *)
enum WiFiAwarePairing {
    static let serviceName = "_\(WireProtocol.serviceType)._udp"
    static var publishableService: WAPublishableService? { WAPublishableService.allServices[serviceName] }
    static var subscribableService: WASubscribableService? { WASubscribableService.allServices[serviceName] }

    /// Whether at least one device is already paired for our service.
    static var hasPairedDevice: Bool {
        get async {
            (try? await WAPairedDevice.allDevices.current())?.isEmpty == false
        }
    }
}

/// Camera side: presents the system UI that lets a nearby remote pair with this device.
@available(iOS 26.0, *)
struct CameraPairingSheet: UIViewControllerRepresentable {
    let service: WAPublishableService

    func makeUIViewController(context: Context) -> DDDevicePairingViewController {
        let provider = WAPublisherListener.wifiAware(.connecting(to: service, from: .userSpecifiedDevices))
        return DDDevicePairingViewController(listenerProvider: provider, access: .default)
    }

    func updateUIViewController(_ controller: DDDevicePairingViewController, context: Context) {}
}

/// Remote side: presents the system picker to find and pair a camera. Calls `onResult` when the user
/// finishes (a paired endpoint) or cancels/fails.
@available(iOS 26.0, *)
struct RemotePairingPicker: UIViewControllerRepresentable {
    let service: WASubscribableService
    let onResult: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let provider = WASubscriberBrowser.wifiAware(.connecting(to: .userSpecifiedDevices, from: service))
        guard let picker = DDDevicePickerViewController(browseDescriptor: provider.makeDescriptor(), parameters: nil, access: .default) else {
            DispatchQueue.main.async { onResult(false) }
            return UIViewController()
        }
        Task {
            let paired = (try? await picker.endpoint) != nil
            await MainActor.run { onResult(paired) }
        }
        return picker
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
#endif
