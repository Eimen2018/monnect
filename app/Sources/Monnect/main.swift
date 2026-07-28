import Foundation

// CLI mode: `Monnect pull` / `Monnect release` / `Monnect status` run the
// same engine without the menu bar UI — used for scripting and testing.
let cliArgs = Array(CommandLine.arguments.dropFirst())

if let cmd = cliArgs.first {
    if cmd == "init" {
        exit(InitCommand.run(args: Array(cliArgs.dropFirst())))
    }
    guard let config = Config.load() else {
        FileHandle.standardError.write(
            "no config at \(Config.fileURL.path) — run `Monnect init` first\n".data(using: .utf8)!)
        exit(2)
    }
    switch cmd {
    case "status":
        for d in config.devices {
            let here = BluetoothEngine.shared.isConnected(d.address)
            print("\(d.name): \(here ? "here" : "away")")
        }
        exit(0)

    case "release":
        BluetoothEngine.shared.releaseAll(config.devices)
        print("released \(config.devices.count) device(s)")
        exit(0)

    case "pull":
        let peer = PeerService(token: config.token, devicesProvider: { config.devices })
        peer.startBrowsing()
        // Give Bonjour a moment to find the other Mac.
        Thread.sleep(forTimeInterval: 2)
        let sema = DispatchSemaphore(value: 0)
        var releaseError: String?
        peer.sendRelease { err in
            releaseError = err
            sema.signal()
        }
        sema.wait()
        if let releaseError {
            print("release: \(releaseError) — claiming anyway")
        } else {
            print("other Mac released the devices")
        }
        print("claiming — power-cycle each device now (off, 3s, on)")
        let failed = BluetoothEngine.shared.claimAll(config.devices) { note in
            print(note)
        }
        if failed.isEmpty {
            print("all devices are on this Mac")
            exit(0)
        }
        for d in failed { print("FAILED: \(d.name)") }
        exit(1)

    default:
        print("usage: Monnect [init|pull|release|status]")
        exit(64)
    }
}

// No arguments: run the menu bar app.
MonnectApp.main()
