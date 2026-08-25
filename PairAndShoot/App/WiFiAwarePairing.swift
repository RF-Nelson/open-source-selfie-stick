#if os(iOS)
import PairAndShootCore
import WiFiAware

/// Wi-Fi Aware service lookup. Services are declared under `WiFiAwareServices` in Info.plist and
/// surface here via `allServices`, keyed by the service name.
@available(iOS 26.0, *)
enum WiFiAwarePairing {
    static let serviceName = "_\(WireProtocol.serviceType)._udp"
    static var publishableService: WAPublishableService? { WAPublishableService.allServices[serviceName] }
    static var subscribableService: WASubscribableService? { WASubscribableService.allServices[serviceName] }
}
#endif
