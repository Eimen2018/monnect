import AppKit

/// Restarting Monnect mid-claim, for when this process's Bluetooth state
/// has gone stale (see BluetoothDaemon). The claim in progress is written
/// to a file the new instance picks up at launch.
enum Relaunch {
    struct Resume: Codable, Equatable {
        var devices: [String]
        /// Skip the fast window: the claim had already moved on to watching.
        var watchOnly: Bool
        var at: Date
    }

    /// A resume file older than this is left over from something else.
    static let maxResumeAge: TimeInterval = 60
    /// At most one relaunch per this long, so a daemon that keeps
    /// crashing can't put Monnect in a restart loop.
    static let minInterval: TimeInterval = 600
    /// A process younger than this pairs devices itself; an older one
    /// relaunches first. bluetoothd can forget a device that isn't paired
    /// here while it stays unpaired (seen after ~43 h, with no daemon
    /// restart), and IOBluetooth in an old process then pairs the empty
    /// address. A fresh process always gets it right.
    static let freshFor: TimeInterval = 60

    static func resumeURL(in directory: URL = ConfigStore.directory) -> URL {
        directory.appendingPathComponent("resume.json")
    }

    static func writeResume(_ resume: Resume, in directory: URL = ConfigStore.directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = resumeURL(in: directory)
        try JSONEncoder.monnect.encode(resume).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Reads and deletes the resume file; nil if missing or stale.
    static func takeResume(in directory: URL = ConfigStore.directory, now: Date = Date()) -> Resume? {
        let url = resumeURL(in: directory)
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard let resume = try? JSONDecoder.monnect.decode(Resume.self, from: data),
              now.timeIntervalSince(resume.at) < maxResumeAge, resume.at <= now.addingTimeInterval(5)
        else { return nil }
        return resume
    }

    static func allowed(lastRelaunch: Date?, now: Date = Date()) -> Bool {
        guard let lastRelaunch else { return true }
        return now.timeIntervalSince(lastRelaunch) >= minInterval || lastRelaunch > now
    }

    private static let lastRelaunchKey = "lastBluetoothRelaunch"

    /// Saves `resume`, starts a new instance once this one has exited, and
    /// quits. False (and nothing done) when relaunching isn't possible or
    /// happened too recently; the caller carries on as it was.
    @MainActor
    static func perform(_ resume: Resume) -> Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            DiagLog.log("EVENT relaunch skipped: not running from an app bundle")
            return false
        }
        let defaults = UserDefaults.standard
        guard allowed(lastRelaunch: defaults.object(forKey: lastRelaunchKey) as? Date) else {
            DiagLog.log("EVENT relaunch skipped: already relaunched in the last \(Int(minInterval / 60)) min")
            return false
        }
        do {
            try writeResume(resume)
        } catch {
            DiagLog.log("EVENT relaunch skipped: can't save the claim (\(error))")
            return false
        }
        // A detached shell waits for this process to exit, then reopens the
        // app; launchd adopts it when we quit.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c", "while /bin/kill -0 \"$2\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open -g \"$1\"",
            "monnect-relaunch", bundle.path, String(getpid()),
        ]
        // `open` hands its environment to the new instance; the test hook
        // must not survive the relaunch it triggers.
        var env = ProcessInfo.processInfo.environment
        env["MONNECT_SIMULATE_BT_RESTART"] = nil
        helper.environment = env
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
        } catch {
            try? FileManager.default.removeItem(at: resumeURL())
            DiagLog.log("EVENT relaunch skipped: helper didn't start (\(error))")
            return false
        }
        defaults.set(Date(), forKey: lastRelaunchKey)
        DiagLog.log("EVENT relaunching to refresh Bluetooth state")
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return true
    }
}
