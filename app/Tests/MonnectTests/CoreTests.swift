import XCTest
import CryptoKit
@testable import Monnect

final class CoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("monnect-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Config

    func testConfigRoundTripIsPrivateFile() throws {
        let url = dir.appendingPathComponent("config.json")
        let config = Config(key: Config.newKey(), devices: [DeviceConfig(name: "Mouse", address: "AA:BB:CC:DD:EE:FF")])
        try ConfigStore.save(config, to: url)

        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        let loaded = try XCTUnwrap(ConfigStore.load(from: url))
        XCTAssertEqual(loaded.key, config.key)
        XCTAssertEqual(loaded.devices.first?.address, "aa-bb-cc-dd-ee-ff")
        XCTAssertTrue(loaded.releaseOnLidClose)
    }

    func testLegacyConfigMigratesToSameKeyOnBothMacs() throws {
        let legacy = #"{"token":"6F1C1D62-1111-2222-3333-444455556666","devices":[{"name":"Magic Mouse","address":"80-12-42-a0-54-e8"}],"releaseOnLidClose":false}"#
        let a = dir.appendingPathComponent("a/config.json")
        let b = dir.appendingPathComponent("b/config.json")
        for url in [a, b] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(legacy.utf8).write(to: url)
        }
        let ca = try XCTUnwrap(ConfigStore.load(from: a))
        let cb = try XCTUnwrap(ConfigStore.load(from: b))
        XCTAssertEqual(ca.key, cb.key, "both Macs must derive the same key from the shared token")
        XCTAssertNotEqual(ca.machineID, cb.machineID)
        XCTAssertNotNil(ca.keyData)
        XCTAssertFalse(ca.releaseOnLidClose)
        XCTAssertTrue(ca.migratedFromV1, "migrated keys are flagged for re-pairing")
        // Upgraded in place, private.
        XCTAssertEqual(ConfigStore.load(from: a)?.machineID, ca.machineID)
        let perms = try FileManager.default.attributesOfItem(atPath: a.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testWorldReadableConfigGetsTightened() throws {
        let url = dir.appendingPathComponent("config.json")
        try ConfigStore.save(Config(key: Config.newKey(), devices: []), to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        _ = ConfigStore.load(from: url)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testGarbageConfigMeansSetup() throws {
        let url = dir.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        XCTAssertNil(ConfigStore.load(from: url))
    }

    // MARK: Pairing crypto

    func testPairingRightCodeOpensPayload() throws {
        let host = Curve25519.KeyAgreement.PrivateKey()
        let joiner = Curve25519.KeyAgreement.PrivateKey()
        let salt = PairingCrypto.makeSalt()
        let hp = host.publicKey.rawRepresentation, jp = joiner.publicKey.rawRepresentation
        let kh = try PairingCrypto.deriveKey(privateKey: host, peerPublic: jp, salt: salt, code: "123456")
        let kj = try PairingCrypto.deriveKey(privateKey: joiner, peerPublic: hp, salt: salt, code: "123456")
        let mac = PairingCrypto.confirmMAC(key: kj, joinerPub: jp, hostPub: hp, salt: salt)
        XCTAssertTrue(PairingCrypto.verifyConfirm(mac, key: kh, joinerPub: jp, hostPub: hp, salt: salt))
        let sealed = try PairingCrypto.sealPayload(Data("secret".utf8), key: kh, joinerPub: jp, hostPub: hp, salt: salt)
        XCTAssertEqual(try PairingCrypto.openPayload(sealed, key: kj, joinerPub: jp, hostPub: hp, salt: salt),
                       Data("secret".utf8))
    }

    func testPairingWrongCodeFails() throws {
        let host = Curve25519.KeyAgreement.PrivateKey()
        let joiner = Curve25519.KeyAgreement.PrivateKey()
        let salt = PairingCrypto.makeSalt()
        let hp = host.publicKey.rawRepresentation, jp = joiner.publicKey.rawRepresentation
        let kh = try PairingCrypto.deriveKey(privateKey: host, peerPublic: jp, salt: salt, code: "123456")
        let kj = try PairingCrypto.deriveKey(privateKey: joiner, peerPublic: hp, salt: salt, code: "123457")
        let mac = PairingCrypto.confirmMAC(key: kj, joinerPub: jp, hostPub: hp, salt: salt)
        XCTAssertFalse(PairingCrypto.verifyConfirm(mac, key: kh, joinerPub: jp, hostPub: hp, salt: salt))
    }

    func testCodesAreLongAndNormalizable() {
        for _ in 0..<200 {
            let code = PairingCrypto.makeCode()
            XCTAssertEqual(code.count, 10)
            XCTAssertEqual(PairingCrypto.normalize(code), code)
            XCTAssertEqual(PairingCrypto.normalize(PairingCrypto.display(code).lowercased()), code)
        }
    }

    func testCodeFormattingWhileTyping() {
        XCTAssertEqual(PairingCrypto.formatTyping("78bmx"), "78BMX", "no dash yet, so backspace isn't trapped")
        XCTAssertEqual(PairingCrypto.formatTyping("78bmxk"), "78BMX-K")
        XCTAssertEqual(PairingCrypto.formatTyping("78BMX-K81JQ"), "78BMX-K81JQ")
        XCTAssertEqual(PairingCrypto.formatTyping("78 bmx k81jq extra"), "78BMX-K81JQ")
        XCTAssertEqual(PairingCrypto.formatTyping("٧٨bmx"), "78BMX")
        XCTAssertNotNil(PairingCrypto.normalize(PairingCrypto.formatTyping("78bmxk81jq")))
    }

    func testCodeNormalization() {
        XCTAssertEqual(PairingCrypto.normalize("k7qm2-xfd9p"), "K7QM2XFD9P")
        XCTAssertEqual(PairingCrypto.normalize(" K7QM2 XFD9P "), "K7QM2XFD9P")
        XCTAssertEqual(PairingCrypto.normalize("O1IL0-ABCDE"), "01110ABCDE", "O/I/L read as 0/1/1")
        XCTAssertEqual(PairingCrypto.normalize("١٢٣٤٥-ABCDE"), "12345ABCDE", "Arabic-Indic digits work")
        XCTAssertNil(PairingCrypto.normalize("123456"))
        XCTAssertNil(PairingCrypto.normalize("UUUUU-UUUUU"), "U isn't in the alphabet")
    }

    // MARK: Wire

    func testFrameHeaderRoundTrip() throws {
        let frame = try Frame.encode(["hello": "world"])
        let length = Frame.length(fromHeader: frame.prefix(4))
        XCTAssertEqual(length, frame.count - 4)
        XCTAssertNil(Frame.length(fromHeader: Data([0xFF, 0xFF, 0xFF, 0xFF])), "oversized frames are refused")
        XCTAssertNil(Frame.length(fromHeader: Data([0, 0, 0, 0])))
    }

    func testParseHostPort() {
        XCTAssertNotNil(parseHostPort("192.168.1.20:51234"))
        XCTAssertNotNil(parseHostPort(" [fe80::1]:80 "))
        XCTAssertNil(parseHostPort("192.168.1.20"))
        XCTAssertNil(parseHostPort(":80"))
    }

    func testFingerprintDependsOnKey() {
        let k1 = Data(repeating: 1, count: 32), k2 = Data(repeating: 2, count: 32)
        XCTAssertEqual(PeerSecret(key: k1).fingerprint, PeerSecret(key: k1).fingerprint)
        XCTAssertNotEqual(PeerSecret(key: k1).fingerprint, PeerSecret(key: k2).fingerprint)
        XCTAssertNotEqual(PeerSecret(key: k1).psk, k1, "the PSK is derived, not the raw key")
    }

    // MARK: Policies

    func testLidReleasePolicy() {
        typealias Lid = PowerMonitor.LidState
        XCTAssertTrue(SleepPolicy.mightRelease(lid: Lid(closed: true, causesSleep: true), holdingAny: true))
        XCTAssertFalse(SleepPolicy.mightRelease(lid: Lid(closed: true, causesSleep: false), holdingAny: true),
                       "clamshell mode with an external display keeps the devices")
        XCTAssertFalse(SleepPolicy.mightRelease(lid: Lid(closed: false, causesSleep: true), holdingAny: true))
        XCTAssertFalse(SleepPolicy.mightRelease(lid: Lid(closed: true, causesSleep: true), holdingAny: false))
    }

    func testWakeReclaimSkipsWhatPeerHolds() {
        let mouse = DeviceConfig(name: "Mouse", address: "aa-aa-aa-aa-aa-01")
        let keyboard = DeviceConfig(name: "Keyboard", address: "aa-aa-aa-aa-aa-02")
        XCTAssertEqual(SleepPolicy.devicesToReclaim(candidates: [mouse, keyboard], peerHolding: [mouse.address]),
                       [keyboard], "the keyboard isn't orphaned when the peer only has the mouse")
        XCTAssertEqual(SleepPolicy.devicesToReclaim(candidates: [mouse, keyboard], peerHolding: nil), [mouse, keyboard])
    }

    func testPeerClaimingDefersWakeReclaim() {
        let mouse = DeviceConfig(name: "Mouse", address: "aa-aa-aa-aa-aa-01")
        let keyboard = DeviceConfig(name: "Keyboard", address: "aa-aa-aa-aa-aa-02")
        XCTAssertEqual(SleepPolicy.devicesToReclaim(candidates: [mouse, keyboard], peerHolding: [],
                                                    peerClaiming: [mouse.address, keyboard.address]), [],
                       "a Mac waking up doesn't fight a pull in progress on the other one")
    }

    func testStaleRecordSelection() {
        let a = "aa-aa-aa-aa-aa-01", b = "aa-aa-aa-aa-aa-02", c = "aa-aa-aa-aa-aa-03"
        let devices = [a, b, c].map { DeviceConfig(name: $0, address: $0) }
        let paired: Set = [a, b, c], connected: Set = [c]
        // b is paired here but asleep, and the other Mac doesn't have it: keep.
        XCTAssertEqual(SleepPolicy.staleRecords(devices: devices, peerHadBefore: [a],
                                                isPaired: paired.contains, isHere: connected.contains), [a])
        // Never heard from the other Mac: every disconnected record may be stale.
        XCTAssertEqual(SleepPolicy.staleRecords(devices: devices, peerHadBefore: nil,
                                                isPaired: paired.contains, isHere: connected.contains), [a, b])
    }

    func testDeviceChoicesIncludeDevicesOnTheOtherMac() {
        let paired = [DeviceConfig(name: "AirPods", address: "11-11-11-11-11-11")]
        let configured = [DeviceConfig(name: "Magic Mouse", address: "22-22-22-22-22-22")]
        XCTAssertEqual(DevicePicker.choices(paired: paired, configured: configured).map(\.name), ["AirPods", "Magic Mouse"])
        XCTAssertTrue(DevicePicker.looksLikeMagicDevice(configured[0]))
        XCTAssertFalse(DevicePicker.looksLikeMagicDevice(paired[0]))
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.1.4"))
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2", than: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.9", than: "0.2.0"))
    }
}
