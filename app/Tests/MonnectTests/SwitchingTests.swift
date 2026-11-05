import XCTest
import Network
@testable import Monnect

/// Polls until `condition` holds or `timeout` passes.
@MainActor
func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        await Task.sleep(seconds: 0.05)
    }
    return condition()
}

private extension SwitchEngine.Timing {
    static var fast: Self {
        var t = Self()
        t.window = 0.6
        t.pageTimeout = 0.05
        t.roundPause = 0.05
        t.peerCheckInterval = 0
        t.watcherPause = { $0 < 3 ? 0.1 : nil }
        return t
    }
}

@MainActor
final class SwitchEngineTests: XCTestCase {
    let mouse = FakeWorld.devices[0]
    let keyboard = FakeWorld.devices[1]

    func testClaimsFreeDevices() async {
        let world = FakeWorld()
        let bt = FakeBluetooth(world: world, owner: "me")
        let engine = SwitchEngine(backend: bt)
        engine.timing = .fast
        engine.claim(FakeWorld.devices, clearStale: []) { nil }
        let done = await waitUntil { engine.activity == .idle }
        XCTAssertTrue(done)
        XCTAssertTrue(bt.isHere(mouse.address) && bt.isHere(keyboard.address))
    }

    func testSleepyDeviceIsWatchedUntilItWakes() async {
        let world = FakeWorld()
        world.setAsleep(true, keyboard.address)
        let bt = FakeBluetooth(world: world, owner: "me")
        let engine = SwitchEngine(backend: bt)
        engine.timing = .fast
        engine.claim(FakeWorld.devices, clearStale: []) { nil }

        let waiting = await waitUntil { engine.activity == .waiting([self.keyboard]) }
        XCTAssertTrue(waiting, "after the window, the engine keeps watching the keyboard")
        XCTAssertTrue(bt.isHere(mouse.address))
        XCTAssertEqual(engine.pending, [keyboard])

        world.setAsleep(false, keyboard.address)
        let done = await waitUntil { engine.activity == .idle }
        XCTAssertTrue(done)
        XCTAssertTrue(bt.isHere(keyboard.address))
    }

    func testWatcherStopsForDevicesThePeerTook() async {
        let world = FakeWorld()
        world.setOwner("peer", of: keyboard.address)
        let bt = FakeBluetooth(world: world, owner: "me")
        let engine = SwitchEngine(backend: bt)
        engine.timing = .fast
        engine.claim(FakeWorld.devices, clearStale: []) { [keyboard] in [keyboard.address] }
        let done = await waitUntil { engine.activity == .idle }
        XCTAssertTrue(done, "watcher drops the keyboard instead of fighting the peer for it")
        XCTAssertTrue(bt.isHere(mouse.address))
        XCTAssertEqual(world.owner(of: keyboard.address), "peer")
    }

    func testGivesUpEventually() async {
        let world = FakeWorld()
        world.setAsleep(true, mouse.address)
        let engine = SwitchEngine(backend: FakeBluetooth(world: world, owner: "me"))
        engine.timing = .fast
        engine.claim([mouse], clearStale: []) { nil }
        let gaveUp = await waitUntil(8) { engine.activity == .gaveUp([self.mouse]) }
        XCTAssertTrue(gaveUp)
        XCTAssertTrue(engine.pending.isEmpty)
    }

    func testAsksForAWakeOnlyWhenADeviceIsSlow() async {
        let world = FakeWorld()
        world.setAsleep(true, keyboard.address)
        let engine = SwitchEngine(backend: FakeBluetooth(world: world, owner: "me"))
        engine.timing = .fast
        engine.timing.window = 3
        engine.timing.askToWakeAfter = 0.4
        engine.claim(FakeWorld.devices, clearStale: []) { nil }
        XCTAssertEqual(engine.activity, .claiming(note: "Switching…"), "no nudge up front")
        let asks = await waitUntil(2) {
            if case .claiming(let note) = engine.activity { return note.hasPrefix("Tap a key") && note.contains(self.keyboard.name) }
            return false
        }
        XCTAssertTrue(asks, "a device that hasn't answered gets a wake request")
        engine.cancel()
    }

    func testCancelAndWaitStopsAnAttemptInFlight() async {
        let world = FakeWorld()
        let bt = FakeBluetooth(world: world, owner: "me")
        bt.latency = 0.5
        let engine = SwitchEngine(backend: bt)
        engine.timing = .fast
        engine.claim([mouse], clearStale: []) { nil }
        await Task.sleep(seconds: 0.1)   // the attempt is mid-flight
        await engine.cancelAndWait()
        await Task.sleep(seconds: 0.6)
        XCTAssertEqual(world.owner(of: mouse.address), "", "a cancelled claim must not finish pairing afterwards")
    }

    func testStaleRecordsAreOnlyCleared() async {
        let world = FakeWorld()
        world.setOwner("me", of: mouse.address)
        let bt = FakeBluetooth(world: world, owner: "me")
        let engine = SwitchEngine(backend: bt)
        engine.timing = .fast
        // isHere == isPaired in the fake, so nothing is pending: no unpair happens.
        engine.claim([mouse], clearStale: [mouse.address]) { nil }
        XCTAssertEqual(engine.activity, .idle)
        XCTAssertEqual(world.owner(of: mouse.address), "me")
    }

    func testCancelStopsPaging() async {
        let world = FakeWorld()
        world.setAsleep(true, mouse.address)
        let bt = FakeBluetooth(world: world, owner: "me")
        let engine = SwitchEngine(backend: bt)
        engine.timing = .fast
        engine.claim([mouse], clearStale: []) { nil }
        await Task.sleep(seconds: 0.3)
        engine.cancel()
        let attempts = bt.attempts
        await Task.sleep(seconds: 0.5)
        XCTAssertLessThanOrEqual(bt.attempts, attempts + 1)
        XCTAssertEqual(engine.activity, .idle)
    }
}

/// Two full app instances on loopback: real Network.framework, real
/// TLS-PSK, fake Bluetooth.
@MainActor
final class TwoMacTests: XCTestCase {
    let mouse = FakeWorld.devices[0]
    let keyboard = FakeWorld.devices[1]

    private func makePair(keyA: String = Config.newKey(), keyB: String? = nil)
        async throws -> (AppModel, AppModel, FakeWorld) {
        let world = FakeWorld()
        let key = keyA
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("monnect-\(UUID().uuidString)")
        let a = AppModel(backend: FakeBluetooth(world: world, owner: "A"),
                         configURL: dir.appendingPathComponent("a/config.json"), startServices: false)
        let b = AppModel(backend: FakeBluetooth(world: world, owner: "B"),
                         configURL: dir.appendingPathComponent("b/config.json"), startServices: false)
        for m in [a, b] {
            m.advertise = false
            m.engine.timing.window = 2
            m.engine.timing.pageTimeout = 0.05
        }
        a.apply(Config(key: key, devices: FakeWorld.devices))
        b.apply(Config(key: keyB ?? key, devices: FakeWorld.devices))
        let ready = await waitUntil { a.peer?.listenPort != nil && b.peer?.listenPort != nil }
        XCTAssertTrue(ready)
        a.peer?.setManualEndpoint(.hostPort(host: "127.0.0.1", port: .init(rawValue: b.peer!.listenPort!)!))
        b.peer?.setManualEndpoint(.hostPort(host: "127.0.0.1", port: .init(rawValue: a.peer!.listenPort!)!))
        addTeardownBlock { @MainActor in
            a.apply(nil)
            b.apply(nil)
            try? FileManager.default.removeItem(at: dir)
        }
        return (a, b, world)
    }

    func testHelloOverTLSPSK() async throws {
        let (a, b, world) = try await makePair()
        world.setOwner("A", of: mouse.address)
        a.refreshHere()
        let response = await b.peer?.hello()
        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(response?.state.holding, [mouse.address])
        XCTAssertEqual(response?.state.awake, true)
        XCTAssertTrue(b.peerOnline)
        let aSawB = await waitUntil { a.peerOnline }
        XCTAssertTrue(aSawB, "the receiving side learns about the caller too")
    }

    func testWrongKeyIsRejected() async throws {
        let (_, b, _) = try await makePair(keyB: Config.newKey())
        let response = await b.peer?.hello(timeout: 2)
        XCTAssertNil(response, "a Mac with a different key can't talk to us")
        XCTAssertFalse(b.peerOnline)
    }

    func testPullMovesDevicesAcross() async throws {
        let (a, b, world) = try await makePair()
        world.setOwner("A", of: mouse.address)
        world.setOwner("A", of: keyboard.address)
        a.refreshHere()
        XCTAssertTrue(a.allHere)

        b.pull()
        let moved = await waitUntil { b.allHere }
        XCTAssertTrue(moved)
        a.refreshHere()
        XCTAssertTrue(a.here.isEmpty)
        XCTAssertEqual(b.activity, .idle)
    }

    func testIncomingReleaseStopsOurClaim() async throws {
        let (a, b, world) = try await makePair()
        // A is watching for a sleepy keyboard when B pulls.
        world.setAsleep(true, keyboard.address)
        a.engine.timing.window = 0.2
        a.engine.timing.watcherPause = { _ in 0.1 }
        a.engine.claim(FakeWorld.devices, clearStale: []) { nil }
        let watching = await waitUntil { if case .waiting = a.activity { return true }; return false }
        XCTAssertTrue(watching)

        b.pull()
        let aStopped = await waitUntil { a.activity == .idle && a.engine.pending.isEmpty }
        XCTAssertTrue(aStopped, "a release from the other Mac cancels our watcher")
        world.setAsleep(false, keyboard.address)
        let bGotAll = await waitUntil(6) { b.allHere }
        XCTAssertTrue(bGotAll)
        await Task.sleep(seconds: 0.5)
        XCTAssertEqual(world.owner(of: keyboard.address), "B", "A doesn't grab it back")
    }

    /// IOBluetooth can still call a device connected for a moment after
    /// -remove. The release reply (and any hello right after) must not
    /// report it as held, or the pulling Mac's watcher stops waiting for it
    /// and the device ends up paired to neither Mac (seen 2026-11-05).
    func testReleaseReplyDoesNotListJustReleasedDevices() async throws {
        let (a, b, world) = try await makePair()
        (a.backend as? FakeBluetooth)?.connectedLagAfterUnpair = 1.5
        world.setOwner("A", of: mouse.address)
        world.setOwner("A", of: keyboard.address)
        a.refreshHere()

        let reply = await b.peer?.requestRelease(requestedAt: Date())
        XCTAssertEqual(reply?.ok, true)
        XCTAssertEqual(reply?.state.holding, [], "released devices aren't reported as held")
        let hello = await b.peer?.hello()
        XCTAssertEqual(hello?.state.holding, [], "nor a moment later")
        XCTAssertEqual(world.owner(of: mouse.address), "")
    }

    func testWatcherKeepsWaitingForLaggyReleasedDevices() async throws {
        let (a, b, world) = try await makePair()
        (a.backend as? FakeBluetooth)?.connectedLagAfterUnpair = 1.5
        world.setOwner("A", of: mouse.address)
        world.setOwner("A", of: keyboard.address)
        a.refreshHere()
        // B is watching (devices "asleep" to it) and asks A again after its window.
        world.setAsleep(true, mouse.address)
        b.engine.timing.window = 0.2
        b.engine.timing.peerCheckInterval = 0
        b.engine.timing.watcherPause = { _ in 0.1 }
        b.pull()
        let released = await waitUntil(4) { world.owner(of: self.keyboard.address) == "B" }
        XCTAssertTrue(released)
        await Task.sleep(seconds: 0.5)
        XCTAssertEqual(b.engine.pending, [mouse], "B still waits for the mouse A let go of")
        world.setAsleep(false, mouse.address)
        let got = await waitUntil(4) { b.allHere }
        XCTAssertTrue(got)
    }

    func testDeviceListSyncsToTheOtherMac() async throws {
        let (a, b, _) = try await makePair()
        a.setDevices([mouse])
        let synced = await waitUntil { b.config?.devices == [self.mouse] }
        XCTAssertTrue(synced)
    }
}

@MainActor
final class PairingTests: XCTestCase {
    private func startHost() async -> (PairingHost, String, String) {
        let payload = PairPayload(key: Config.newKey(), devices: FakeWorld.devices, devicesUpdatedAt: Date())
        let host = PairingHost(payload: payload, advertise: false)
        host.start()
        _ = await waitUntil {
            if case .waiting = host.status { return true }
            return false
        }
        guard case let .waiting(code, _) = host.status, let port = host.port else {
            XCTFail("host didn't start")
            return (host, "", "")
        }
        return (host, code, "127.0.0.1:\(port)")
    }

    func testJoinWithRightCode() async throws {
        let (host, code, address) = await startHost()
        defer { host.stop() }
        let result = try await PairingJoin.run(code: code, address: address)
        XCTAssertEqual(result.payload.devices, FakeWorld.devices)
        XCTAssertEqual(Data(base64Encoded: result.payload.key)?.count, 32)
        let paired = await waitUntil { if case .paired = host.status { return true }; return false }
        XCTAssertTrue(paired)
    }

    func testWrongCodeIsRefusedAndCapped() async throws {
        let (host, code, address) = await startHost()
        defer { host.stop() }
        let wrong = String(code.reversed()) == code ? "0000000000" : String(code.reversed())
        do {
            _ = try await PairingJoin.run(code: wrong, address: address)
            XCTFail("wrong code must not pair")
        } catch let error as PairingJoin.Failure {
            XCTAssertEqual(error, .wrongCode)
        }
        if case .waiting = host.status {} else { XCTFail("one stray guess must not burn the code") }
        for _ in 1..<PairingHost.maxAttempts {
            _ = try? await PairingJoin.run(code: wrong, address: address)
        }
        if case .failed = host.status {} else { XCTFail("too many wrong guesses end the code") }
        do {
            _ = try await PairingJoin.run(code: code, address: address)
            XCTFail("an ended code must not pair")
        } catch {}
    }

    func testNewCodeIgnoresTheOldOne() async throws {
        let (host, oldCode, _) = await startHost()
        defer { host.stop() }
        host.start()   // "Show New Code"
        _ = await waitUntil { if case .waiting = host.status { return true }; return false }
        guard case let .waiting(newCode, _) = host.status, let port = host.port else { return XCTFail() }
        XCTAssertNotEqual(oldCode, newCode)
        let result = try await PairingJoin.run(code: newCode, address: "127.0.0.1:\(port)")
        XCTAssertEqual(result.payload.devices, FakeWorld.devices)
    }

    func testRejectsMalformedCodes() async {
        do {
            _ = try await PairingJoin.run(code: "123456", address: "127.0.0.1:1")
            XCTFail()
        } catch let error as PairingJoin.Failure {
            XCTAssertEqual(error, .badCode)
        } catch {
            XCTFail("\(error)")
        }
    }
}

/// bluetoothd restarted while the devices weren't paired here: this
/// process's IOBluetooth state is stale, so Monnect relaunches instead of
/// pairing (which would fail and crash the daemon again).
@MainActor
final class StaleBluetoothTests: XCTestCase {
    let mouse = FakeWorld.devices[0]
    let keyboard = FakeWorld.devices[1]

    func testEngineHandsTheClaimToARelaunch() async {
        let bt = FakeBluetooth(world: FakeWorld(), owner: "me")
        bt.daemonRestarted = true
        let engine = SwitchEngine(backend: bt)
        engine.timing = .fast
        var handed: ([DeviceConfig], Bool)?
        engine.onStaleBluetooth = { remaining, inWindow in
            handed = (remaining, inWindow)
            return true
        }
        engine.claim(FakeWorld.devices, clearStale: []) { nil }
        let stopped = await waitUntil { handed != nil && engine.activity == .idle }
        XCTAssertTrue(stopped)
        XCTAssertEqual(handed?.0, FakeWorld.devices)
        XCTAssertEqual(handed?.1, true)
        XCTAssertEqual(bt.attempts, 0, "no pairing attempt with stale Bluetooth state")
        XCTAssertTrue(engine.pending.isEmpty)
    }

    func testEngineCarriesOnWhenRelaunchIsRefused() async {
        let bt = FakeBluetooth(world: FakeWorld(), owner: "me")
        bt.daemonRestarted = true
        let engine = SwitchEngine(backend: bt)
        engine.timing = .fast
        var asked = 0
        engine.onStaleBluetooth = { _, _ in asked += 1; return false }
        engine.claim(FakeWorld.devices, clearStale: []) { nil }
        let done = await waitUntil { engine.activity == .idle }
        XCTAssertTrue(done)
        XCTAssertTrue(bt.isHere(mouse.address) && bt.isHere(keyboard.address))
        XCTAssertEqual(asked, 1, "asks once per claim, not once per device")
    }

    func testNoRelaunchWhileTheDaemonIsTheSame() async {
        let bt = FakeBluetooth(world: FakeWorld(), owner: "me")
        let engine = SwitchEngine(backend: bt)
        engine.timing = .fast
        var asked = false
        engine.onStaleBluetooth = { _, _ in asked = true; return true }
        engine.claim(FakeWorld.devices, clearStale: []) { nil }
        let done = await waitUntil { engine.activity == .idle }
        XCTAssertTrue(done)
        XCTAssertFalse(asked)
        XCTAssertTrue(bt.isHere(mouse.address))
    }

    func testPullRelaunchesAndTheNewInstanceFinishes() async {
        let world = FakeWorld()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("monnect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = Config(key: Config.newKey(), devices: FakeWorld.devices)

        let staleBT = FakeBluetooth(world: world, owner: "me")
        staleBT.daemonRestarted = true
        let old = AppModel(backend: staleBT, configURL: dir.appendingPathComponent("config.json"),
                           startServices: false)
        old.advertise = false
        old.engine.timing.pageTimeout = 0.05
        var resume: Relaunch.Resume?
        old.relaunch = { resume = $0; return true }
        old.apply(config)
        old.engine.claim(config.devices, clearStale: []) { nil }
        let handed = await waitUntil { resume != nil }
        XCTAssertTrue(handed)
        XCTAssertEqual(resume?.devices, FakeWorld.devices.map(\.address))
        XCTAssertEqual(resume?.watchOnly, false)
        XCTAssertEqual(staleBT.attempts, 0)
        old.apply(nil)

        // The relaunched process: fresh Bluetooth state.
        let fresh = AppModel(backend: FakeBluetooth(world: world, owner: "me"),
                             configURL: dir.appendingPathComponent("config.json"), startServices: false)
        fresh.advertise = false
        fresh.engine.timing.pageTimeout = 0.05
        fresh.apply(config)
        defer { fresh.apply(nil) }
        fresh.resumeAfterRelaunch(resume)
        let claimed = await waitUntil { fresh.allHere }
        XCTAssertTrue(claimed)
    }

    func testResumeFileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("monnect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let resume = Relaunch.Resume(devices: [mouse.address], watchOnly: true, at: now)
        try Relaunch.writeResume(resume, in: dir)
        XCTAssertEqual(Relaunch.takeResume(in: dir, now: now.addingTimeInterval(2))?.devices, [mouse.address])
        XCTAssertNil(Relaunch.takeResume(in: dir, now: now), "taking it deletes it")

        try Relaunch.writeResume(resume, in: dir)
        XCTAssertNil(Relaunch.takeResume(in: dir, now: now.addingTimeInterval(Relaunch.maxResumeAge + 1)),
                     "an old file is ignored")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Relaunch.resumeURL(in: dir).path))
    }

    func testRelaunchIsRateLimited() {
        let now = Date()
        XCTAssertTrue(Relaunch.allowed(lastRelaunch: nil, now: now))
        XCTAssertFalse(Relaunch.allowed(lastRelaunch: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(Relaunch.allowed(lastRelaunch: now.addingTimeInterval(-Relaunch.minInterval), now: now))
        XCTAssertTrue(Relaunch.allowed(lastRelaunch: now.addingTimeInterval(3600), now: now),
                      "a clock that moved backwards doesn't block relaunches forever")
    }

    func testFindsTheRealDaemon() {
        // bluetoothd runs on every Mac with Bluetooth; CI without it just skips.
        guard let daemon = BluetoothDaemon.current() else { return }
        XCTAssertGreaterThan(daemon.pid, 0)
        XCTAssertEqual(BluetoothDaemon.current(), daemon, "same daemon, same identity")
    }
}
