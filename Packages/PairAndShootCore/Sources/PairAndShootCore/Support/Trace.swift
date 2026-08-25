import Foundation

/// A dead-simple append-only trace written to the app's Documents directory, so a debug build's
/// transport lifecycle can be pulled off the device with
/// `devicectl device copy from --domain-type appDataContainer` — independent of the (flaky) syslog.
public enum Trace {
    private static let queue = DispatchQueue(label: "pairandshoot.trace")
    private static let fileURL: URL? = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("transport.log")
    }()

    nonisolated(unsafe) private static var didReset = false

    /// Clears the file once per process launch, so a role's reconnect churn keeps accumulating into
    /// one trace instead of each new listener/browser wiping the previous connection's history.
    public static func reset() {
        queue.async {
            guard !didReset else { return }
            didReset = true
            guard let fileURL else { return }
            try? Data().write(to: fileURL)
        }
    }

    public static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        queue.async {
            guard let fileURL, let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
