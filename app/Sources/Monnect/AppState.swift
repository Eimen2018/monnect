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

    func pullInputHere() {
        guard let config, let peer, phase == .idle || isErrorPhase else { return }
        phase = .releasingPeer
        peer.sendRelease { [weak self] err in
            Task { @MainActor in
                guard let self else { return }
                // Even if the peer is unreachable, try to claim: the devices
                // may already be free.
                if let err { NSLog("monnect: release failed: \(err)") }
                self.phase = .claiming("Power-cycle each device now (off, 3s, on)")
                Task.detached {
                    let failed = BluetoothEngine.shared.claimAll(config.devices) { note in
                        Task { @MainActor in self.phase = .claiming(note) }
                    }
                    await MainActor.run {
                        if failed.isEmpty {
                            self.phase = .idle
                        } else {
                            let names = failed.map(\.name).joined(separator: ", ")
                            self.phase = .error("Couldn't claim: \(names). Power-cycle and retry.")
                        }
                        self.refreshStates()
                    }
                }
            }
        }
    }
}
