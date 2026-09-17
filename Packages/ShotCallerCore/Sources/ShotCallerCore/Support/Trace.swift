import Foundation

/// A debug-only trace written to the app's Documents directory, so a development build's
/// transport lifecycle can be pulled off the device with
/// `devicectl device copy from --domain-type appDataContainer` — independent of the (flaky) syslog.
/// Release builds neither evaluate log messages nor persist peer names and connection details.
public enum Trace {
#if DEBUG
    private static let queue = DispatchQueue(label: "shotcaller.trace")
    private static let fileURL: URL? = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("transport.log")
    }()

    nonisolated(unsafe) private static var didReset = false
#endif

    /// Clears the file once per process launch, so a role's reconnect churn keeps accumulating into
    /// one trace instead of each new listener/browser wiping the previous connection's history.
    public static func reset() {
#if DEBUG
        queue.async {
            guard !didReset else { return }
            didReset = true
            guard let fileURL else { return }
            try? Data().write(to: fileURL)
        }
#endif
    }

    public static func log(_ message: @autoclosure () -> String) {
#if DEBUG
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message())\n"
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
#endif
    }
}
