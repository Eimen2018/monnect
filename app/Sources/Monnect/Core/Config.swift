import Foundation
import CryptoKit

struct DeviceConfig: Codable, Identifiable, Hashable {
    let name: String
    /// Lowercase, dash-separated, e.g. "80-12-42-a0-54-e8".
    let address: String
    var id: String { address }

    init(name: String, address: String) {
        self.name = name
        self.address = DeviceConfig.normalize(address)
    }

    static func normalize(_ address: String) -> String {
        address.lowercased().replacingOccurrences(of: ":", with: "-")
    }
}

/// Everything one Mac needs to switch peripherals with the other. Both
/// Macs hold the same `key` and `devices`; `machineID` is per Mac.
struct Config: Codable, Equatable {
    var version = 2
    /// 32 random bytes, base64. Keys the TLS-PSK channel between the Macs.
    var key: String
    /// This Mac's identity on the network. Generated locally; pairing never
    /// copies it, so two Macs can't end up with the same one.
    var machineID: String
    var devices: [DeviceConfig]
    /// When the device list last changed. The Macs sync the newer list.
    var devicesUpdatedAt: Date
    /// Unpair when this Mac sleeps because its lid closed while the other
    /// Mac is awake, so the other Mac's claim never races a sleeping one.
    var releaseOnLidClose = true
    /// Daily check against GitHub Releases for a newer version.
    var checkForUpdates = true
    /// The key was derived from a v0.1 token, which crossed the network in
    /// cleartext. Pairing again replaces it.
    var migratedFromV1 = false

    init(key: String, machineID: String = UUID().uuidString, devices: [DeviceConfig],
         devicesUpdatedAt: Date = Date()) {
        self.key = key
        self.machineID = machineID
        self.devices = devices
        self.devicesUpdatedAt = devicesUpdatedAt
    }

    static func newKey() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
    }

    var keyData: Data? {
        guard let d = Data(base64Encoded: key), d.count == 32 else { return nil }
        return d
    }

    enum CodingKeys: String, CodingKey {
        case version, key, machineID, devices, devicesUpdatedAt, releaseOnLidClose, checkForUpdates, migratedFromV1
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 2
        key = try c.decode(String.self, forKey: .key)
        machineID = try c.decode(String.self, forKey: .machineID)
        devices = try c.decode([DeviceConfig].self, forKey: .devices)
        devicesUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .devicesUpdatedAt) ?? .distantPast
        releaseOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .releaseOnLidClose) ?? true
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? true
        migratedFromV1 = try c.decodeIfPresent(Bool.self, forKey: .migratedFromV1) ?? false
    }
}

/// The v0.1 config: a shared UUID token sent in cleartext.
private struct LegacyConfig: Decodable {
    let token: String
    let devices: [DeviceConfig]
    let releaseOnLidClose: Bool?
    let checkForUpdates: Bool?
}

enum ConfigStore {
    static var directory: URL {
        // Override for running two instances on one Mac (development, tests).
        if let dir = ProcessInfo.processInfo.environment["MONNECT_CONFIG_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Monnect", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    /// Loads the config, upgrading a v0.1 one in place. Returns nil when
    /// there is none (or it's unreadable), which means "run setup".
    static func load(from url: URL = fileURL) -> Config? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        tightenPermissions(url)
        if let config = try? JSONDecoder.monnect.decode(Config.self, from: data), config.keyData != nil {
            return config
        }
        if let legacy = try? JSONDecoder.monnect.decode(LegacyConfig.self, from: data) {
            var config = Config(key: migratedKey(fromToken: legacy.token), devices: legacy.devices,
                                devicesUpdatedAt: .distantPast)
            config.releaseOnLidClose = legacy.releaseOnLidClose ?? true
            config.checkForUpdates = legacy.checkForUpdates ?? true
            config.migratedFromV1 = true
            try? save(config, to: url)
            DiagLog.log("EVENT migrated v0.1 config")
            return config
        }
        return nil
    }

    /// Both Macs derive the same key from their shared v0.1 token, so an
    /// upgrade keeps them paired without running setup again.
    static func migratedKey(fromToken token: String) -> String {
        Data(SHA256.hash(data: Data("monnect-v2-migrate|\(token)".utf8))).base64EncodedString()
    }

    /// Atomic write, created 0600 from the start: the key never sits in a
    /// file other users can read, not even for a moment.
    static func save(_ config: Config, to url: URL = fileURL) throws {
        // Tests must never touch the real config.
        precondition(NSClassFromString("XCTestCase") == nil || url != fileURL
                     || ProcessInfo.processInfo.environment["MONNECT_CONFIG_DIR"] != nil,
                     "test tried to write the real config")
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder.monnect
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)

        let tmp = dir.appendingPathComponent(".config.json.\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        fsync(fd)
        close(fd)
        guard written == data.count, rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            throw POSIXError(.EIO)
        }
    }

    static func delete(at url: URL = fileURL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func tightenPermissions(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let perms = attrs[.posixPermissions] as? Int, perms & 0o077 != 0 else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// ISO 8601 with milliseconds. Plain .iso8601 drops fractions, and device
/// lists changed within the same second must still compare as newer.
private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()

extension JSONEncoder {
    static var monnect: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(isoFractional.string(from: date))
        }
        return e
    }
}

extension JSONDecoder {
    static var monnect: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = isoFractional.date(from: s) ?? isoPlain.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
            }
            return date
        }
        return d
    }
}
