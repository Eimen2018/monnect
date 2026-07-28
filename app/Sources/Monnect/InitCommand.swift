import Foundation

/// `Monnect init [--token <token>]` — interactive first-run setup.
/// Lists paired Bluetooth devices, lets the user pick the peripherals to
/// switch, and writes config.json. Both Macs must share the same token;
/// the first run generates one and prints the command for the second Mac.
enum InitCommand {
    static func run(args: [String]) -> Int32 {
        let engine = BluetoothEngine.shared
        guard engine.blueutilPath != nil else {
            err("blueutil is required. Install it with:  brew install blueutil")
            return 1
        }
        guard let paired = engine.pairedDevices() else {
            err("""
            Could not read Bluetooth devices. Grant Bluetooth access to this \
            terminal app in System Settings > Privacy & Security > Bluetooth, \
            restart the terminal, and run `Monnect init` again.
            """)
            return 1
        }
        guard !paired.isEmpty else {
            err("""
            No paired Bluetooth devices found. Pair your mouse/keyboard with \
            this Mac first (plug in its cable once), then rerun `Monnect init`.
            """)
            return 1
        }

        print("Paired Bluetooth devices:\n")
        for (i, d) in paired.enumerated() {
            print(String(format: "  %2d) %@  [%@]", i + 1, d.name ?? "<unnamed>", d.address))
        }
        print("\nNumbers of the devices to switch (e.g. \"1 3\"): ", terminator: "")
        guard let line = readLine() else { return 1 }
        var devices: [DeviceConfig] = []
        for part in line.split(separator: " ") {
            guard let n = Int(part), n >= 1, n <= paired.count else {
                err("invalid selection: \(part)")
                return 1
            }
            let d = paired[n - 1]
            devices.append(DeviceConfig(name: d.name ?? d.address, address: d.address))
        }
        guard !devices.isEmpty else {
            err("nothing selected")
            return 1
        }

        // --token <t> joins an existing setup; otherwise start a new one.
        var token: String
        if let idx = args.firstIndex(of: "--token"), idx + 1 < args.count {
            token = args[idx + 1]
        } else {
            token = UUID().uuidString
        }

        let url = Config.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            print("Config already exists at \(url.path). Overwrite? [y/N] ", terminator: "")
            guard readLine()?.lowercased() == "y" else {
                print("aborted")
                return 1
            }
        }

        let config = Config(token: token, devices: devices)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: url)
        } catch {
            err("failed to write config: \(error)")
            return 1
        }

        print("""

        Wrote \(url.path)

        Next steps:
          1. On your OTHER Mac, install Monnect and run:
               Monnect init --token \(token)
             (same token = the two Macs trust each other)
          2. Launch Monnect.app on both Macs and allow the Bluetooth,
             local network, and firewall prompts.
          3. Add Monnect to Login Items on both Macs so it survives reboots.

        Then click the menu bar icon on whichever Mac should have the
        peripherals and choose "Pull Input Here".
        """)
        return 0
    }

    private static func err(_ msg: String) {
        FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    }
}
