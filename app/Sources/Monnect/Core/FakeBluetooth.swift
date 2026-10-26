import Foundation

/// A pretend world of two Magic devices, each owned by at most one Mac.
/// Mirrors the firmware rule that matters: a device answers a new host only
/// once its owner has let go. In memory for tests; backed by a JSON file
/// (MONNECT_FAKE_BT=<path>) so two app instances on one Mac share it.
final class FakeWorld: @unchecked Sendable {
    static let devices = [
        DeviceConfig(name: "Fake Magic Mouse", address: "aa-aa-aa-aa-aa-01"),
        DeviceConfig(name: "Fake Magic Keyboard", address: "aa-aa-aa-aa-aa-02"),
    ]

    private let path: String?
    private let lock = NSLock()
    private var owners: [String: String] = [:]   // address -> owner ("" = free)
    /// Devices that are "asleep": they ignore pages until woken.
    private var asleep: Set<String> = []

    init(path: String? = nil) {
        self.path = path
    }

    static func shared(atPath path: String) -> FakeWorld { FakeWorld(path: path) }

    func owner(of address: String) -> String {
        withState { $0.owners[address] ?? "" }
    }

    func setOwner(_ owner: String, of address: String) {
        withState { $0.owners[address] = owner }
    }

    func setAsleep(_ isAsleep: Bool, _ address: String) {
        withState { if isAsleep { $0.asleep.insert(address) } else { $0.asleep.remove(address) } }
    }

    func isAsleep(_ address: String) -> Bool {
        withState { $0.asleep.contains(address) }
    }

    private struct Stored: Codable {
        var owners: [String: String]
        var asleep: Set<String>
    }

    private func withState<R>(_ body: (inout (owners: [String: String], asleep: Set<String>)) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        guard let path else {
            var state = (owners: owners, asleep: asleep)
            let r = body(&state)
            owners = state.owners
            asleep = state.asleep
            return r
        }
        // Cross-process: lock the file, read, mutate, write back.
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        let data = FileManager.default.contents(atPath: path) ?? Data()
        let stored = (try? JSONDecoder().decode(Stored.self, from: data)) ?? Stored(owners: [:], asleep: [])
        var state = (owners: stored.owners, asleep: stored.asleep)
        let r = body(&state)
        if let out = try? JSONEncoder().encode(Stored(owners: state.owners, asleep: state.asleep)) {
            ftruncate(fd, 0)
            _ = out.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        }
        return r
    }
}

@MainActor
final class FakeBluetooth: BluetoothBackend {
    var onConnectionChange: (() -> Void)?
    let world: FakeWorld
    let owner: String
    var attempts = 0
    /// How long one claim attempt takes (a page or pairing in flight).
    var latency: TimeInterval = 0.05

    init(world: FakeWorld, owner: String) {
        self.world = world
        self.owner = owner
    }

    func start() {}

    func pairedDevices() -> [DeviceConfig] { FakeWorld.devices }

    func isPaired(_ address: String) -> Bool { world.owner(of: address) == owner }

    func isHere(_ address: String) -> Bool { isPaired(address) }

    func unpair(_ address: String) async {
        guard isPaired(address) else { return }
        world.setOwner("", of: address)
        DiagLog.log("fake unpair \(address)")
        onConnectionChange?()
    }

    func attemptClaim(_ address: String, pageTimeout: TimeInterval) async -> ClaimOutcome {
        attempts += 1
        if isHere(address) { return .connected }
        await Task.sleep(seconds: latency)
        // Like the real backend: a cancelled attempt never completes.
        if Task.isCancelled { return .noAnswer }
        guard world.owner(of: address).isEmpty, !world.isAsleep(address) else { return .noAnswer }
        world.setOwner(owner, of: address)
        DiagLog.log("fake claim \(address) -> ok")
        onConnectionChange?()
        return .connected
    }
}
