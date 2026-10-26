import Foundation
import IOBluetooth
import CoreBluetooth

/// What switching needs from Bluetooth. The real one talks to IOBluetooth;
/// FakeBluetooth stands in for tests and for running two instances on one
/// Mac without touching real devices.
@MainActor
protocol BluetoothBackend: AnyObject {
    /// Called whenever any device connects or disconnects.
    var onConnectionChange: (() -> Void)? { get set }
    /// Begin watching connections. Deferred until setup is done, so the
    /// Bluetooth permission prompt doesn't fire before the welcome screen.
    func start()
    func pairedDevices() -> [DeviceConfig]
    func isPaired(_ address: String) -> Bool
    /// Paired with this Mac and connected right now.
    func isHere(_ address: String) -> Bool
    func unpair(_ address: String) async
    /// One quick attempt to take the device: page it, pair, connect.
    func attemptClaim(_ address: String, pageTimeout: TimeInterval) async -> ClaimOutcome
}

enum ClaimOutcome: Equatable {
    case connected
    /// The device didn't answer the page — asleep, out of range, or still
    /// paired to the other Mac. The normal case for a device that has dozed off.
    case noAnswer
    case failed(String)
}

@MainActor
func makeBluetoothBackend() -> BluetoothBackend {
    if let path = ProcessInfo.processInfo.environment["MONNECT_FAKE_BT"] {
        DiagLog.log("EVENT using fake Bluetooth at \(path)")
        return FakeBluetooth(world: .shared(atPath: path), owner: ConfigStore.directory.path)
    }
    return IOBluetoothBackend()
}

// MARK: - IOBluetooth

/// Talks to IOBluetooth in-process. Every call runs on the main thread and
/// nothing blocks: pages and pairings complete through delegate callbacks
/// on the main run loop.
@MainActor
final class IOBluetoothBackend: NSObject, BluetoothBackend {
    var onConnectionChange: (() -> Void)?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]

    /// Delegates and targets IOBluetooth doesn't retain, kept alive until
    /// a little after their callback (a late callback after stop() must
    /// never reach a freed object).
    private var inFlight: Set<NSObject> = []

    func start() {
        guard connectNotification == nil else { return }
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self, selector: #selector(deviceConnected(_:fromDevice:)))
        // Devices already connected never send a connect event; watch them now.
        for d in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] where d.isConnected() {
            watchDisconnect(of: d)
        }
    }

    private func watchDisconnect(of device: IOBluetoothDevice) {
        guard let address = device.addressString.map(DeviceConfig.normalize),
              disconnectNotifications[address] == nil else { return }
        disconnectNotifications[address] = device.register(
            forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:fromDevice:)))
    }

    private func retain(_ object: NSObject) { inFlight.insert(object) }

    private func releaseLater(_ object: NSObject) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.inFlight.remove(object)
        }
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, fromDevice device: IOBluetoothDevice) {
        watchDisconnect(of: device)
        onConnectionChange?()
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, fromDevice device: IOBluetoothDevice) {
        if let address = device.addressString.map(DeviceConfig.normalize) {
            disconnectNotifications.removeValue(forKey: address)?.unregister()
        }
        onConnectionChange?()
    }

    private func device(_ address: String) -> IOBluetoothDevice? {
        IOBluetoothDevice(addressString: address)
    }

    func pairedDevices() -> [DeviceConfig] {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices.compactMap { d in
            guard let address = d.addressString else { return nil }
            return DeviceConfig(name: d.name ?? address, address: address)
        }
    }

    func isPaired(_ address: String) -> Bool {
        device(address)?.isPaired() ?? false
    }

    func isHere(_ address: String) -> Bool {
        guard let d = device(address) else { return false }
        return d.isPaired() && d.isConnected()
    }

    func unpair(_ address: String) async {
        guard let d = device(address), d.isPaired() else { return }
        // There's no public unpair API. -remove is what System Settings'
        // "Forget This Device" and blueutil use; fine outside the App Store.
        let remove = NSSelectorFromString("remove")
        guard d.responds(to: remove) else {
            DiagLog.log("unpair \(address): -remove unavailable on this macOS")
            return
        }
        d.perform(remove)
        for _ in 0..<30 where d.isPaired() {
            await Task.sleep(seconds: 0.1)
        }
        DiagLog.log("unpair \(address) -> \(d.isPaired() ? "still paired" : "ok")")
    }

    func attemptClaim(_ address: String, pageTimeout: TimeInterval) async -> ClaimOutcome {
        guard let d = device(address) else { return .failed("invalid address") }
        if d.isPaired() && d.isConnected() { return .connected }

        if d.isPaired() {
            // Our own pairing, device asleep: a page reconnects it natively.
            let status = await openConnection(d, pageTimeout: pageTimeout)
            return status == kIOReturnSuccess && d.isConnected() ? .connected : .noAnswer
        }

        // Unpaired: pair straight away, as an app-requested pairing. Two
        // things measured on real hardware decide this:
        //  - Opening a connection to an unpaired device makes bluetoothd
        //    start a pairing of its own, which pops up the system's
        //    "Connection Request" dialog. IOBluetoothDevicePair marks the
        //    pairing as ours, and bluetoothd hands it to us silently.
        //  - Remote-name requests never call back on macOS 26+, so they're
        //    useless as a quick "are you awake?" probe.
        // Pairing pages for ~15 s by itself; `answerWithin` cuts a page off
        // after a few seconds so the next device gets its turn.
        let status = await pair(d, answerWithin: pageTimeout, finishWithin: 25)
        if status == kIOReturnTimeout || status == kIOReturnAborted { return .noAnswer }
        guard status == kIOReturnSuccess, d.isPaired() else {
            // 0x4 is a page timeout: asleep or still owned elsewhere.
            if status == 0x4 || status == 0x2 { return .noAnswer }
            DiagLog.log("pair \(address) -> failed 0x\(String(UInt32(bitPattern: status), radix: 16))")
            return .failed("pairing failed")
        }
        DiagLog.log("pair \(address) -> ok")
        if !d.isConnected() {
            _ = await openConnection(d, pageTimeout: 5)
        }
        return d.isPaired() && d.isConnected() ? .connected : .noAnswer
    }

    // MARK: Async wrappers
    //
    // Both honor task cancellation: cancelling a claim stops the page or
    // pairing in flight, so a Mac that agreed to release can't finish
    // pairing a moment later.

    private func openConnection(_ d: IOBluetoothDevice, pageTimeout: TimeInterval) async -> IOReturn {
        var once: OneShot<IOReturn>?
        let target = ConnectTarget { once?.resume($0) }
        retain(target)
        defer { releaseLater(target) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                once = OneShot(cont)
                if Task.isCancelled { once?.resume(kIOReturnAborted); return }
                // Page timeout is in baseband slots of 0.625 ms.
                let slots = BluetoothHCIPageTimeout(min(65535, max(1600, pageTimeout / 0.000625)))
                let started = d.openConnection(target, withPageTimeout: slots, authenticationRequired: false)
                if started != kIOReturnSuccess {
                    once?.resume(started)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + pageTimeout + 3) {
                    if once?.resume(kIOReturnTimeout) == true { d.closeConnection() }
                }
            }
        } onCancel: {
            DispatchQueue.main.async {
                if once?.resume(kIOReturnAborted) == true, !d.isPaired() { d.closeConnection() }
            }
        }
    }

    /// Pairs, giving up after `answerWithin` if the device hasn't come up
    /// on the link by then (asleep, or still owned by the other Mac). Once
    /// the link is up, pairing gets `finishWithin` to complete.
    private func pair(_ d: IOBluetoothDevice, answerWithin: TimeInterval, finishWithin: TimeInterval) async -> IOReturn {
        guard let pairing = IOBluetoothDevicePair(device: d) else { return kIOReturnError }
        var once: OneShot<IOReturn>?
        let delegate = PairDelegate { once?.resume($0) }
        retain(delegate)
        defer {
            pairing.delegate = nil
            releaseLater(delegate)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                once = OneShot(cont)
                if Task.isCancelled { once?.resume(kIOReturnAborted); return }
                pairing.delegate = delegate
                let started = pairing.start()
                if started != kIOReturnSuccess {
                    once?.resume(started)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + answerWithin) {
                    if d.isConnected() {
                        // It answered; pairing is under way. Let it finish.
                        DispatchQueue.main.asyncAfter(deadline: .now() + finishWithin) {
                            if once?.resume(kIOReturnTimeout) == true { pairing.stop() }
                        }
                    } else if once?.resume(kIOReturnTimeout) == true {
                        pairing.stop()
                    }
                }
            }
        } onCancel: {
            DispatchQueue.main.async {
                if once?.resume(kIOReturnAborted) == true { pairing.stop() }
            }
        }
    }
}

private final class ConnectTarget: NSObject {
    private var done: ((IOReturn) -> Void)?
    init(done: @escaping (IOReturn) -> Void) { self.done = done }

    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        done?(status)
        done = nil
    }
}

private final class PairDelegate: NSObject, IOBluetoothDevicePairDelegate {
    private var done: ((IOReturn) -> Void)?
    init(done: @escaping (IOReturn) -> Void) { self.done = done }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        done?(error)
        done = nil
    }

    // Magic devices pair "Just Works" with no PIN. Should one ask to
    // confirm a number anyway, accept: the user started this switch.
    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        DiagLog.log("pair: confirming numeric value \(numericValue)")
        (sender as? IOBluetoothDevicePair)?.replyUserConfirmation(true)
    }

    func devicePairingPINCodeRequest(_ sender: Any!) {
        DiagLog.log("pair: device asked for a PIN — not supported")
        (sender as? IOBluetoothDevicePair)?.stop()
        done?(kIOReturnUnsupported)
        done = nil
    }

    func devicePairingUserPasskeyNotification(_ sender: Any!, passkey: BluetoothPasskey) {
        DiagLog.log("pair: device shows passkey \(passkey)")
    }
}

// MARK: - Permission

/// Bluetooth privacy permission. IOBluetooth and CoreBluetooth share the
/// same TCC entry; CoreBluetooth is the one that can ask for it.
@MainActor
final class BluetoothPermission: NSObject, ObservableObject, CBCentralManagerDelegate {
    enum Status { case notDetermined, allowed, denied }
    @Published private(set) var status: Status = BluetoothPermission.current
    private var manager: CBCentralManager?

    static var current: Status {
        if ProcessInfo.processInfo.environment["MONNECT_FAKE_BT"] != nil { return .allowed }
        switch CBManager.authorization {
        case .allowedAlways: return .allowed
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Shows the system prompt the first time; afterwards just refreshes.
    func request() {
        guard status == .notDetermined else { refresh(); return }
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    func refresh() { status = Self.current }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { refresh() }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!
}
