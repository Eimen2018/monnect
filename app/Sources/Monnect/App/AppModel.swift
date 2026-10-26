import AppKit
import Combine

/// The app's brain: owns the config, the switch engine, and the link to the
/// other Mac, and decides who should have the devices when. Everything runs
/// on the main actor; Bluetooth and networking never block it.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var config: Config?
    @Published private(set) var here: Set<String> = []
    @Published private(set) var activity: SwitchEngine.Activity = .idle
    /// A step that comes before claiming ("Asking … to let go").
    @Published private(set) var busyNote: String?
    /// A one-off message about the last switch, e.g. that it lost a tie.
    @Published private(set) var notice: String?
    @Published private(set) var peerOnline = false
    @Published private(set) var peerState: PeerState?
    @Published private(set) var updateAvailable: LatestRelease?
    @Published private(set) var launchAtLogin = LaunchAtLogin.isEnabled
    /// Where the setup window starts next time it opens.
    @Published var setupEntry: SetupEntry = .welcome

    let backend: BluetoothBackend
    let permission = BluetoothPermission()
    let engine: SwitchEngine
    private let power = PowerMonitor()
    private(set) var peer: PeerLink?

    private var isAsleep = false
    /// Released on lid-close sleep: reclaim on wake unless the other Mac
    /// took them.
    private var releasedOnSleep = false
    /// A claim that sleep interrupted, to pick up again on wake.
    private var suspendedClaim: [DeviceConfig] = []
    private var suspendedWasWatching = false
    /// When the user here last clicked Pull — breaks ties if both Macs pull.
    private var userPullAt: Date?
    /// Bumped whenever who-should-have-the-devices changes (a pull, a
    /// release, sleep, a new config). An async step that wakes up to a
    /// different epoch drops what it was about to do.
    private var epoch = 0
    private var timers: [Timer] = []
    /// Bonjour on/off; tests connect two instances by address instead.
    var advertise = true

    /// Where this instance keeps its config. Tests pass a temp file.
    let configURL: URL

    init(backend: BluetoothBackend? = nil, configURL: URL = ConfigStore.fileURL, startServices: Bool = true) {
        self.configURL = configURL
        self.backend = backend ?? makeBluetoothBackend()
        engine = SwitchEngine(backend: self.backend)
        engine.onChange = { [weak self] in self?.engineChanged() }
        self.backend.onConnectionChange = { [weak self] in self?.refreshHere() }
        guard startServices else { return }

        power.onWillSleep = { [weak self] done in
            guard let self else { return done() }
            self.willSleep(done: done)
        }
        power.onDidWake = { [weak self] in self?.didWake() }
        power.start()

        apply(ConfigStore.load(from: configURL))
        timers = [
            Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            },
            Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkForUpdates() }
            },
        ]
        checkForUpdates()
    }

    // MARK: - Derived state

    var needsSetup: Bool { config == nil }

    var allHere: Bool {
        guard let config, !config.devices.isEmpty else { return false }
        return config.devices.allSatisfy { here.contains($0.address) }
    }

    var isBusy: Bool { busyNote != nil || engine.isClaiming }

    var peerName: String { peerState?.name ?? "your other Mac" }

    enum DeviceLocation { case here, otherMac, nowhere }

    func location(of device: DeviceConfig) -> DeviceLocation {
        if here.contains(device.address) { return .here }
        if peerOnline, peerState?.holding.contains(device.address) == true { return .otherMac }
        return .nowhere
    }

    // MARK: - Config

    /// Starts (or restarts) everything for a config; nil tears it down.
    func apply(_ newConfig: Config?) {
        epoch += 1
        engine.cancel()
        busyNote = nil
        peer?.stop()
        peer = nil
        config = newConfig
        peerOnline = false
        peerState = nil
        guard let newConfig, let key = newConfig.keyData else {
            refreshHere()
            return
        }
        backend.start()
        let link = PeerLink(key: key, machineID: newConfig.machineID, advertise: advertise) { [weak self] in
            self?.currentState() ?? PeerState(name: computerName, awake: false, holding: [], claiming: [],
                                               devices: [], devicesUpdatedAt: .distantPast)
        }
        link.onRelease = { [weak self] request in
            guard let self else {
                return PeerResponse(ok: false, error: "shutting down", from: "", state: request.state)
            }
            return await self.handleRelease(request)
        }
        link.onPeerUpdate = { [weak self] in self?.peerChanged() }
        link.paused = isAsleep
        link.start()
        peer = link
        refreshHere()
    }

    private func save(_ update: (inout Config) -> Void) {
        guard var config else { return }
        update(&config)
        do {
            try ConfigStore.save(config, to: configURL)
            self.config = config
        } catch {
            DiagLog.log("EVENT saving config failed: \(error)")
        }
    }

    func setReleaseOnLidClose(_ on: Bool) { save { $0.releaseOnLidClose = on } }

    func setCheckForUpdates(_ on: Bool) {
        save { $0.checkForUpdates = on }
        if on { checkForUpdates() } else { updateAvailable = nil }
    }

    func setDevices(_ devices: [DeviceConfig]) {
        save {
            $0.devices = devices
            $0.devicesUpdatedAt = Date()
        }
        refreshHere()
        // Tell the other Mac now rather than at the next heartbeat.
        Task { _ = await peer?.hello() }
    }

    func setLaunchAtLogin(_ on: Bool) {
        LaunchAtLogin.set(on)
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    /// Saves a config from setup and starts using it.
    func finishSetup(_ config: Config) throws {
        try ConfigStore.save(config, to: configURL)
        apply(config)
        DiagLog.log("EVENT setup complete: \(config.devices.map(\.name).joined(separator: ", "))")
    }

    /// The config to hand a joining Mac. A key carried over from v0.1 was
    /// derived from a token that once crossed the network in cleartext, so
    /// pairing replaces it with a fresh one first (the other Mac then joins
    /// with the new key; until it does, the two can't talk).
    func configForPairing() -> Config? {
        guard let config else { return nil }
        guard config.migratedFromV1 else { return config }
        var fresh = config
        fresh.key = Config.newKey()
        fresh.migratedFromV1 = false
        do {
            try ConfigStore.save(fresh, to: configURL)
        } catch {
            DiagLog.log("EVENT key rotation failed: \(error)")
            return config
        }
        DiagLog.log("EVENT rotated the v0.1-derived key for pairing")
        apply(fresh)
        return fresh
    }

    func resetSetup() {
        DiagLog.log("EVENT setup reset")
        ConfigStore.delete(at: configURL)
        apply(nil)
        setupEntry = .welcome
    }

    // MARK: - State

    func refreshHere() {
        guard let config else { here = []; return }
        let now = Set(config.devices.map(\.address).filter { backend.isHere($0) })
        if now != here { here = now }
    }

    private func tick() {
        refreshHere()
        // Wake watchdog: if both wake notifications were somehow missed,
        // don't stay "asleep" (paused, unable to pull) until a relaunch.
        if isAsleep, PowerMonitor.displayAwake, !SleepPolicy.mightRelease(lid: PowerMonitor.lidState(), holdingAny: true) {
            DiagLog.log("EVENT wake detected by watchdog")
            didWake()
        }
    }

    private func currentState() -> PeerState {
        PeerState(name: computerName,
                  awake: !isAsleep,
                  holding: config?.devices.map(\.address).filter { backend.isHere($0) } ?? [],
                  claiming: engine.pending.map(\.address),
                  devices: config?.devices ?? [],
                  devicesUpdatedAt: config?.devicesUpdatedAt ?? .distantPast)
    }

    private func engineChanged() {
        activity = engine.activity
        refreshHere()
    }

    private func peerChanged() {
        guard let peer else { return }
        peerOnline = peer.peerOnline
        peerState = peer.peer?.state
        // The device list follows whichever Mac changed it last.
        if let state = peer.peer?.state, let config,
           state.devicesUpdatedAt > config.devicesUpdatedAt, state.devices != config.devices,
           !state.devices.isEmpty {
            DiagLog.log("EVENT adopting device list from \(state.name)")
            save {
                $0.devices = state.devices
                $0.devicesUpdatedAt = state.devicesUpdatedAt
            }
            refreshHere()
        }
    }

    private func peerHolding() async -> Set<String>? {
        guard let response = await peer?.hello() else { return nil }
        return Set(response.state.holding)
    }

    // MARK: - Switching

    func pull() {
        guard let config, let peer, !isAsleep, !isBusy, !allHere else { return }
        permission.refresh()
        guard permission.status == .allowed else {
            notice = "Monnect needs Bluetooth access — System Settings → Privacy & Security → Bluetooth."
            return
        }
        DiagLog.log("EVENT pull initiated by user")
        let now = Date()
        userPullAt = now
        notice = nil
        epoch += 1
        let myEpoch = epoch
        releasedOnSleep = false
        suspendedClaim = []
        // What the other Mac last told us it had, before it lets go.
        let peerHadBefore = peer.peer.map { Set($0.state.holding) }
        let peerSaidAsleep = peer.peer?.state.awake == false
        busyNote = "Asking \(peerName) to let go…"
        Task {
            await engine.cancelAndWait()
            guard epoch == myEpoch else { return }
            // Right after launch or wake the other Mac may not be found yet,
            // so keep asking for a few seconds — unless it last told us it
            // was going to sleep (a lid-close release already let go).
            let response = peerSaidAsleep
                ? await peer.requestRelease(requestedAt: now, timeout: 2, within: 3)
                : await peer.requestReleaseRetrying(requestedAt: now, for: 6)
            guard epoch == myEpoch, !isAsleep else { return }
            busyNote = nil
            if let response, !response.ok, response.error == PeerResponse.newerPull {
                DiagLog.log("EVENT pull lost the tie to \(response.state.name)")
                notice = "\(response.state.name) pulled at the same moment and keeps the devices."
                return
            }
            DiagLog.log("EVENT release: \(response.map { $0.ok ? "ok" : ($0.error ?? "refused") } ?? "no answer")")
            let stale = SleepPolicy.staleRecords(devices: config.devices, peerHadBefore: peerHadBefore,
                                                 isPaired: backend.isPaired, isHere: backend.isHere)
            var askedAgain = false
            engine.claim(config.devices, clearStale: stale) {
                let held = await self.peerHolding()
                // The user pulled these. If the other Mac still has some once
                // the window's over (it took them back, or never heard us),
                // ask once more before giving them up.
                if let held, !askedAgain, !held.isDisjoint(with: Set(self.engine.pending.map(\.address))),
                   self.epoch == myEpoch {
                    askedAgain = true
                    DiagLog.log("EVENT other Mac still holds pulled devices; asking again")
                    if let again = await self.peer?.requestRelease(requestedAt: now), again.ok {
                        return Set(again.state.holding)
                    }
                }
                return held
            }
        }
    }

    func stopWaiting() {
        DiagLog.log("EVENT user stopped waiting")
        engine.cancel()
        notice = nil
    }

    /// Unpairs the devices here so the other Mac (or a cable) can have them.
    func releaseHere() {
        guard let config else { return }
        DiagLog.log("EVENT release initiated by user")
        epoch += 1
        releasedOnSleep = false
        suspendedClaim = []
        Task {
            await engine.cancelAndWait()
            for d in config.devices { await backend.unpair(d.address) }
            refreshHere()
        }
    }

    private func handleRelease(_ request: PeerRequest) async -> PeerResponse {
        // Both Macs pulled within seconds: the later click wins.
        if let mine = userPullAt, Date().timeIntervalSince(mine) < 10,
           let theirs = request.requestedAt, theirs < mine {
            DiagLog.log("EVENT refusing release: our pull is newer")
            return PeerResponse(ok: false, error: PeerResponse.newerPull, from: peer?.machineID ?? "",
                                state: currentState())
        }
        epoch += 1
        busyNote = nil
        userPullAt = nil
        releasedOnSleep = false
        suspendedClaim = []
        // Stop our own claim *and* whatever pairing it had in flight before
        // unpairing — otherwise it could finish after we answered "ok".
        await engine.cancelAndWait()
        if let config {
            for d in config.devices { await backend.unpair(d.address) }
        }
        refreshHere()
        return PeerResponse(ok: true, from: peer?.machineID ?? "", state: currentState())
    }

    // MARK: - Sleep and wake

    private func willSleep(done: @escaping () -> Void) {
        let firstSleep = !isAsleep
        isAsleep = true
        epoch += 1
        peer?.paused = true
        busyNote = nil
        // Nothing claims while asleep — not even during Power Nap wakes.
        if !engine.pending.isEmpty {
            suspendedClaim = engine.pending
            if case .waiting = engine.activity { suspendedWasWatching = true } else { suspendedWasWatching = false }
        }
        Task {
            await engine.cancelAndWait()
            await releaseOnLidCloseIfUseful(firstSleep: firstSleep)
            done()
        }
    }

    private func releaseOnLidCloseIfUseful(firstSleep: Bool) async {
        guard let config, config.releaseOnLidClose, let peer else { return }
        let lid = PowerMonitor.lidState()
        let held = config.devices.filter { backend.isPaired($0.address) }
        guard SleepPolicy.mightRelease(lid: lid, holdingAny: !held.isEmpty) else {
            if firstSleep {
                DiagLog.log("EVENT willSleep: lidClosed=\(lid.closed) causesSleep=\(lid.causesSleep) held=\(held.count) — keeping devices")
            }
            return
        }
        // Only worth it if the other Mac is awake to take them; otherwise
        // keeping the pairing lets the lid reopen with a native reconnect.
        // (Re-checked when a Power Nap wake ends: if the other Mac has woken
        // up and is in use since, now's the time to let go.)
        let response = await peer.hello(timeout: 2.5, within: 6)
        let peerAwake = response?.state.awake == true
        DiagLog.log("EVENT willSleep: lid closed, other Mac \(response == nil ? "unreachable" : (peerAwake ? "awake" : "asleep"))")
        guard peerAwake else { return }
        releasedOnSleep = true   // before unpairing, in case sleep wins
        suspendedClaim = []
        for d in held { await backend.unpair(d.address) }
        DiagLog.log("EVENT released on lid close: \(held.map(\.name).joined(separator: ", "))")
    }

    private func didWake() {
        guard isAsleep else { return }   // didWake and screensDidWake both fire
        isAsleep = false
        epoch += 1
        let myEpoch = epoch
        peer?.paused = false
        peer?.restartDiscovery()
        let wasReleased = releasedOnSleep
        let suspended = suspendedClaim
        let wasWatching = suspendedWasWatching
        releasedOnSleep = false
        suspendedClaim = []
        DiagLog.log("EVENT didWake: releasedOnSleep=\(wasReleased) suspended=\(suspended.count)")
        guard let config, let peer, wasReleased || !suspended.isEmpty else { return refreshHere() }

        busyNote = "Woke up — checking where your devices are…"
        Task {
            let response = await peer.helloRetrying(for: 15)
            guard epoch == myEpoch, !isAsleep else { return }
            busyNote = nil
            let wanted = SleepPolicy.devicesToReclaim(
                candidates: wasReleased ? config.devices : suspended,
                peerHolding: response.map { Set($0.state.holding) },
                peerClaiming: response.map { Set($0.state.claiming) })
            DiagLog.log("EVENT wake: other Mac \(response.map { "holds \($0.state.holding), claiming \($0.state.claiming)" } ?? "unreachable"); reclaiming [\(wanted.map(\.name).joined(separator: ", "))]")
            guard !wanted.isEmpty else { return refreshHere() }
            engine.claim(wanted, clearStale: [], watchOnly: !wasReleased && wasWatching) {
                await self.peerHolding()
            }
        }
    }

    // MARK: - Updates

    private func checkForUpdates() {
        guard config?.checkForUpdates ?? true else { return }
        UpdateChecker.fetchLatest { [weak self] latest in
            Task { @MainActor in
                guard let self, let latest,
                      UpdateChecker.isNewer(latest.version, than: UpdateChecker.currentVersion) else { return }
                if self.updateAvailable != latest {
                    DiagLog.log("EVENT update available: v\(latest.version)")
                }
                self.updateAvailable = latest
            }
        }
    }
}

/// The switching decisions, kept pure so they can be tested.
enum SleepPolicy {
    /// Release on sleep only when the lid closing is what put the Mac to
    /// sleep. In clamshell mode with an external display the lid is shut but
    /// the Mac is in use — and its keyboard must stay able to wake it.
    static func mightRelease(lid: PowerMonitor.LidState, holdingAny: Bool) -> Bool {
        lid.closed && lid.causesSleep && holdingAny
    }

    /// After wake: reclaim what the other Mac neither holds nor is busy
    /// claiming (its user may have just pulled). Unreachable (nil) means
    /// nothing to defer to.
    static func devicesToReclaim(candidates: [DeviceConfig], peerHolding: Set<String>?,
                                 peerClaiming: Set<String>? = nil) -> [DeviceConfig] {
        let theirs = (peerHolding ?? []).union(peerClaiming ?? [])
        return candidates.filter { !theirs.contains($0.address) }
    }

    /// Which local pairing records are stale before a pull. A device the
    /// other Mac had was re-paired there, so our record's link key is dead.
    /// A device that's paired here but disconnected while the other Mac
    /// doesn't have it is just asleep — keep its record so it reconnects
    /// natively. Never heard from the other Mac: assume the worst.
    static func staleRecords(devices: [DeviceConfig], peerHadBefore: Set<String>?,
                             isPaired: (String) -> Bool, isHere: (String) -> Bool) -> Set<String> {
        Set(devices.map(\.address).filter { address in
            guard isPaired(address), !isHere(address) else { return false }
            return peerHadBefore?.contains(address) ?? true
        })
    }
}
