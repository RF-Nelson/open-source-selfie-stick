import Foundation

/// Resolves to whichever of two async results arrives first; the other is discarded. Used where a
/// caller must not wait on work it cannot cancel (a camera frame that never comes).
enum FirstResult {
    /// `work` races a deadline. Returns nil when the deadline wins; the work continues unobserved.
    static func of<T: Sendable>(timeout: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
        let box = Once<T?>()
        return await withCheckedContinuation { continuation in
            box.install(continuation)
            Task { box.resume(await work()) }
            Task {
                try? await Task.sleep(for: timeout)
                box.resume(nil)
            }
        }
    }

    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?

        func install(_ continuation: CheckedContinuation<T, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func resume(_ value: T) {
            let continuation = lock.withLock { () -> CheckedContinuation<T, Never>? in
                let current = self.continuation
                self.continuation = nil
                return current
            }
            continuation?.resume(returning: value)
        }
    }
}
