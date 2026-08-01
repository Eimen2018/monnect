import Foundation

/// Wraps blueutil. All calls run on a serial queue so we never hit the
/// Bluetooth stack with overlapping commands.
final class BluetoothEngine {
    static let shared = BluetoothEngine()

    private let queue = DispatchQueue(label: "monnect.blueutil")
    let blueutilPath: String?

    // Lets a release request (the other Mac pulling) interrupt an in-flight
    // claim loop instead of waiting behind it on the serial queue.
    private let abortLock = NSLock()
    private var abortClaim = false
    private func setAbort(_ v: Bool) { abortLock.lock(); abortClaim = v; abortLock.unlock() }
    private func shouldAbort() -> Bool { abortLock.lock(); defer { abortLock.unlock() }; return abortClaim }

    private init() {
        let candidates = ["/opt/homebrew/bin/blueutil", "/usr/local/bin/blueutil"]
        blueutilPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    private func run(_ args: [String]) -> (status: Int32, output: String) {
        guard let path = blueutilPath else { return (127, "blueutil not found") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return (126, "\(error)")
        }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    struct PairedDevice: Codable {
        let address: String
        let name: String?
    }

    /// All devices paired with this Mac. Returns nil when the Bluetooth API
    /// is inaccessible (missing TCC permission) as opposed to simply empty.
    func pairedDevices() -> [PairedDevice]? {
        queue.sync {
            let r = run(["--paired", "--format", "json"])
            guard r.status == 0,
                  let data = r.output.data(using: .utf8),
                  let devices = try? JSONDecoder().decode([PairedDevice].self, from: data) else {
                return nil
            }
            return devices
        }
    }

    func isConnected(_ address: String) -> Bool {
        queue.sync {
            let r = run(["--is-connected", address])
            return r.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }
    }

    /// One quiet pair+connect attempt, used by the background watcher after
    /// a claim window expires. Returns true when the device is connected.
    func attemptClaim(_ d: DeviceConfig) -> Bool {
        queue.sync {
            run(["--pair", d.address])
            if run(["--is-connected", d.address]).output
                .trimmingCharacters(in: .whitespacesAndNewlines) != "1" {
                run(["--connect", d.address])
            }
            return run(["--is-connected", d.address]).output
                .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }
    }

    /// Old-owner side of a switch: unpair so another Mac can claim.
    func releaseAll(_ devices: [DeviceConfig]) {
        setAbort(true)
        queue.sync {
            for d in devices {
                run(["--unpair", d.address])
            }
        }
    }

    /// New-owner side: clear stale records, then keep pairing until every
    /// device connects or the window closes. Magic devices answer a new host
    /// most reliably right after a power-cycle, hence the long patient loop.
    /// Returns the addresses that could NOT be claimed.
    func claimAll(_ devices: [DeviceConfig],
                  windowSeconds: TimeInterval = 90,
                  progress: @escaping (String) -> Void) -> [DeviceConfig] {
        queue.sync {
            setAbort(false)
            var pending = devices.filter { d in
                let r = run(["--is-connected", d.address])
                return r.output.trimmingCharacters(in: .whitespacesAndNewlines) != "1"
            }
            for d in pending {
                run(["--unpair", d.address])
            }
            let deadline = Date().addingTimeInterval(windowSeconds)
            while !pending.isEmpty && Date() < deadline && !shouldAbort() {
                for d in pending {
                    run(["--pair", d.address])
                    if run(["--is-connected", d.address]).output
                        .trimmingCharacters(in: .whitespacesAndNewlines) != "1" {
                        run(["--connect", d.address])
                    }
                    if run(["--is-connected", d.address]).output
                        .trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                        pending.removeAll { $0.address == d.address }
                        progress("\(d.name) connected")
                    }
                }
                if !pending.isEmpty { Thread.sleep(forTimeInterval: 1) }
            }
            return pending
        }
    }
}
