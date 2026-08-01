import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case releasingPeer
        case claiming(String)
        case error(String)
    }

    @Published var phase: Phase = .idle
    @Published var connected: [String: Bool] = [:]   // address -> connected here
    @Published var peerVisible = false
    @Published var configMissing = false
    @Published var blueutilMissing = false

    let config: Config?
    private(set) var peer: PeerService?
    private var pollTimer: Timer?

    init() {
        config = Config.load()
        configMissing = (config == nil)
        blueutilMissing = (BluetoothEngine.shared.blueutilPath == nil)
        guard let config else { return }

        let peer = PeerService(token: config.token, devicesProvider: { config.devices })
        peer.onPeersChanged = { [weak self] names in
            Task { @MainActor in self?.peerVisible = !names.isEmpty }
        }
        peer.startListening()
        peer.startBrowsing()
        self.peer = peer

        // When this Mac sleeps because the lid was closed, give up the
        // peripherals: a closed MacBook can't use them, but its Bluetooth
        // still answers their reconnect pages from sleep, which makes the
        // other Mac's claim a coin toss. Releasing on clamshell sleep makes
        // the handoff deterministic. Idle sleep (lid open) is left alone.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.releaseOnClamshellSleep() }
        }
        // The other half of lid-close release: on wake, if the other Mac
        // didn't take the devices while we slept, reclaim them automatically
        // so reopening the lid never requires a manual pull.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reclaimAfterWakeIfUnclaimed() }
        }

        refreshStates()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .idle || self.isErrorPhase else { return }
                self.refreshStates()
            }
        }
    }

    private var isErrorPhase: Bool {
        if case .error = phase { return true }
        return false
    }

    var allHere: Bool {
        guard let config, !config.devices.isEmpty else { return false }
        return config.devices.allSatisfy { connected[$0.address] == true }
    }

    var iconName: String {
        if phase != .idle && !isErrorPhase { return "keyboard.badge.ellipsis" }
        return allHere ? "keyboard.fill" : "keyboard"
    }

    func refreshStates() {
        guard let config else { return }
        Task.detached { [weak self] in
            var result: [String: Bool] = [:]
            for d in config.devices {
                result[d.address] = BluetoothEngine.shared.isConnected(d.address)
            }
            let snapshot = result
            await MainActor.run { self?.connected = snapshot }
        }
    }

    private var releasedOnSleep = false

    private func releaseOnClamshellSleep() {
        guard let config, config.releaseOnLidClose ?? true else { return }
        let devices = config.devices
        Task.detached { [weak self] in
            guard Self.isLidClosed() else { return }
            let held = devices.filter { BluetoothEngine.shared.isConnected($0.address) }
            guard !held.isEmpty else { return }
            BluetoothEngine.shared.releaseAll(held)
            NSLog("monnect: released \(held.count) device(s) on lid-close sleep")
            await MainActor.run { self?.releasedOnSleep = true }
        }
    }

    private func reclaimAfterWakeIfUnclaimed() {
        guard releasedOnSleep else { return }
        releasedOnSleep = false
        guard let config, let peer else { return }
        phase = .claiming("Woke up — checking where the devices are…")
        // Give Wi-Fi and Bonjour a moment to come back before asking around.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            peer.queryHolding { held in
                Task { @MainActor in
                    let ours = Set(config.devices.map(\.address))
                    if let held, !ours.isDisjoint(with: Set(held)) {
                        // The other Mac took them while we slept — theirs now.
                        self.phase = .idle
                        self.refreshStates()
                        return
                    }
                    self.phase = .claiming("Reclaiming — wiggle the mouse / tap a key")
                    self.runClaim(config: config)
                }
            }
        }
    }

    private var watcherTask: Task<Void, Never>?

    /// Shared claim tail used by pull and wake-reclaim. Devices that miss
    /// the 90 s window aren't abandoned — a background watcher keeps trying
    /// so they join whenever they finally wake up.
    private func runClaim(config: Config) {
        watcherTask?.cancel()
        Task.detached {
            let failed = BluetoothEngine.shared.claimAll(config.devices) { note in
                Task { @MainActor in self.phase = .claiming(note) }
            }
            await MainActor.run {
                if failed.isEmpty {
                    self.phase = .idle
                } else {
                    let names = failed.map(\.name).joined(separator: ", ")
                    self.phase = .error("Waiting for \(names) — power-cycle it and it will join automatically")
                    self.startWatcher(for: failed, config: config)
                }
                self.refreshStates()
            }
        }
    }

    /// Patiently retries pairing the given devices every few seconds,
    /// forever, until they connect here or the other Mac takes them.
    private func startWatcher(for devices: [DeviceConfig], config: Config) {
        watcherTask?.cancel()
        let peer = self.peer
        watcherTask = Task.detached { [weak self] in
            var remaining = devices
            var peerTookThem = false
            while !Task.isCancelled && !remaining.isEmpty {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled { return }
                if let peer {
                    let held: [String]? = await withCheckedContinuation { cont in
                        peer.queryHolding { cont.resume(returning: $0) }
                    }
                    if let held, remaining.contains(where: { held.contains($0.address) }) {
                        peerTookThem = true
                        break
                    }
                }
                for d in remaining {
                    if Task.isCancelled { return }
                    if BluetoothEngine.shared.attemptClaim(d) {
                        remaining.removeAll { $0.address == d.address }
                        await MainActor.run { self?.refreshStates() }
                    }
                }
            }
            let settled = remaining.isEmpty || peerTookThem
            await MainActor.run {
                guard let self else { return }
                if settled { self.phase = .idle }
                self.refreshStates()
            }
        }
    }

    nonisolated private static func isLidClosed() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        p.arguments = ["-r", "-k", "AppleClamshellState", "-d", "4"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.contains("\"AppleClamshellState\" = Yes")
    }

    func pullInputHere() {
        guard let config, let peer, phase == .idle || isErrorPhase else { return }
        watcherTask?.cancel()
        phase = .releasingPeer
        peer.sendRelease { [weak self] err in
            Task { @MainActor in
                guard let self else { return }
                // Even if the peer is unreachable, try to claim: the devices
                // may already be free.
                if let err { NSLog("monnect: release failed: \(err)") }
                self.phase = .claiming("Power-cycle each device now (off, 3s, on)")
                self.runClaim(config: config)
            }
        }
    }
}
