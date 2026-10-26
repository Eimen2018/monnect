import Foundation
import SystemConfiguration

/// Resumes a continuation at most once — for callback APIs that can fire
/// both a result and a timeout.
final class OneShot<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    /// Returns false if it had already been resumed.
    @discardableResult
    func resume(_ value: T) -> Bool {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
        return c != nil
    }
}

extension Task where Success == Never, Failure == Never {
    static func sleep(seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// The name people know this Mac by, e.g. "Aymen's MacBook Pro". Read
/// from SystemConfiguration: Host.current() can block on DNS lookups.
var computerName: String {
    (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
}
