import Foundation

/// The new-owner side of a switch: keep paging the devices until each one
/// answers. Starts with a fast 90 s window (the user is wiggling the mouse),
/// then keeps watching with growing pauses so a device that slept through
/// the switch still joins when it wakes. One cancellable task — anything
/// that changes who should own the devices (the other Mac pulling, this Mac
/// sleeping, the user stopping it) cancels it.
@MainActor
final class SwitchEngine {
    struct Timing {
        var window: TimeInterval = 90
        /// How long one device gets to answer a page before we try the next.
        var pageTimeout: TimeInterval = 4
        var roundPause: TimeInterval = 0.5
        /// How often the watcher asks the other Mac what it holds.
        var peerCheckInterval: TimeInterval = 15
        /// A device released while in use answers within a few seconds on
        /// its own. One that hasn't by now is probably asleep: ask the user
        /// to wake it.
        var askToWakeAfter: TimeInterval = 6

        /// Pause between watcher rounds, by how long we've been watching;
        /// nil means give up.
        var watcherPause: (TimeInterval) -> TimeInterval? = { watched in
            switch watched {
            case ..<300: return 5
            case ..<1800: return 20
            case ..<(3 * 3600): return 60
            default: return nil
            }
        }
    }

    enum Activity: Equatable {
        case idle
        /// Inside the fast window.
        case claiming(note: String)
        /// Window over; still watching for these devices.
        case waiting([DeviceConfig])
        /// Stopped watching; these never answered.
        case gaveUp([DeviceConfig])
    }

    private let backend: BluetoothBackend
    var timing = Timing()
    var onChange: (() -> Void)?

    private(set) var activity: Activity = .idle {
        didSet { if activity != oldValue { onChange?() } }
    }
    /// Devices the running claim still wants. Shared with the other Mac so
    /// it knows we're after them.
    private(set) var pending: [DeviceConfig] = [] {
        didSet { if pending != oldValue { onChange?() } }
    }
    private var task: Task<Void, Never>?

    init(backend: BluetoothBackend) {
        self.backend = backend
    }

    var isClaiming: Bool {
        if case .claiming = activity { return true }
        return false
    }

    /// - Parameters:
    ///   - clearStale: addresses whose local record to drop first: devices
    ///     the other Mac had, so our old link key is stale and would make
    ///     the device refuse us. A device that's merely asleep but still
    ///     paired here keeps its record and reconnects natively.
    ///   - watchOnly: skip the fast window (resuming a watch after wake).
    ///   - peerHolding: asks the other Mac which devices it holds; nil when
    ///     it can't be reached. The watcher drops devices it has taken.
    func claim(_ devices: [DeviceConfig], clearStale: Set<String>, watchOnly: Bool = false,
               peerHolding: @escaping () async -> Set<String>?) {
        cancel()
        let targets = devices.filter { !backend.isHere($0.address) }
        guard !targets.isEmpty else { return }
        pending = targets
        activity = watchOnly ? .waiting(targets) : .claiming(note: "Switching…")
        task = Task { [weak self] in
            await self?.run(targets, clearStale: clearStale, watchOnly: watchOnly, peerHolding: peerHolding)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = []
        activity = .idle
    }

    /// Cancels, and returns only once the Bluetooth operation in flight has
    /// actually stopped — so whatever comes next (unpairing for the other
    /// Mac, sleeping) can't be undone by a pairing that finishes late.
    func cancelAndWait() async {
        let running = task
        cancel()
        await running?.value
    }

    private func run(_ targets: [DeviceConfig], clearStale: Set<String>, watchOnly: Bool,
                     peerHolding: () async -> Set<String>?) async {
        let names = { (d: [DeviceConfig]) in d.map(\.name).joined(separator: ", ") }
        DiagLog.log("EVENT claim start: [\(names(targets))] watchOnly=\(watchOnly)")
        for d in targets where clearStale.contains(d.address) && backend.isPaired(d.address) {
            if Task.isCancelled { return }
            await backend.unpair(d.address)
        }
        var remaining = targets
        let started = Date()
        let windowEnd = watchOnly ? started : started.addingTimeInterval(timing.window)
        var lastPeerCheck = Date.distantPast
        var rounds = 0

        while !remaining.isEmpty {
            if Task.isCancelled { return }
            let inWindow = Date() < windowEnd
            if !inWindow {
                if isClaiming {
                    DiagLog.log("EVENT claim window over, watching for [\(names(remaining))]")
                }
                activity = .waiting(remaining)
                if Date().timeIntervalSince(lastPeerCheck) >= timing.peerCheckInterval {
                    lastPeerCheck = Date()
                    if let held = await peerHolding() {
                        if Task.isCancelled { return }
                        let taken = remaining.filter { held.contains($0.address) }
                        if !taken.isEmpty {
                            DiagLog.log("EVENT other Mac has [\(names(taken))]; not watching for them")
                            remaining.removeAll { held.contains($0.address) }
                            pending = remaining
                            if remaining.isEmpty { break }
                        }
                    }
                }
                guard let pause = timing.watcherPause(Date().timeIntervalSince(windowEnd)) else {
                    DiagLog.log("EVENT gave up on [\(names(remaining))]")
                    pending = []
                    activity = .gaveUp(remaining)
                    task = nil
                    return
                }
                await Task.sleep(seconds: pause)
                if Task.isCancelled { return }
            }

            rounds += 1
            for d in remaining {
                if Task.isCancelled { return }
                let outcome = await backend.attemptClaim(d.address, pageTimeout: timing.pageTimeout)
                if Task.isCancelled { return }
                switch outcome {
                case .connected:
                    remaining.removeAll { $0.address == d.address }
                    pending = remaining
                    let secs = Int(Date().timeIntervalSince(started))
                    DiagLog.log("EVENT \(d.name) connected after \(secs)s (round \(rounds))")
                    if Date() < windowEnd { activity = .claiming(note: "\(d.name) connected") }
                case .failed(let why):
                    DiagLog.log("claim \(d.name): \(why)")
                case .noAnswer:
                    break
                }
            }
            if Date() < windowEnd && !remaining.isEmpty {
                if Date().timeIntervalSince(started) >= timing.askToWakeAfter {
                    activity = .claiming(note: "Tap a key or click to wake \(names(remaining))")
                }
                await Task.sleep(seconds: timing.roundPause)
            }
        }
        if Task.isCancelled { return }
        DiagLog.log("EVENT claim done in \(Int(Date().timeIntervalSince(started)))s")
        pending = []
        activity = .idle
        task = nil
    }
}
