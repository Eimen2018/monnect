import AppKit
import IOKit
import IOKit.pwr_mgt

/// Sleep and wake, with the ability to hold sleep off briefly.
///
/// NSWorkspace's willSleep can't delay sleep, so work started there can
/// freeze halfway (an unpair interrupted mid-release). IOKit's system power
/// notifications wait for an acknowledgement — we ack once the work is done
/// (or after `maxSleepDelay`, whichever comes first).
///
/// Wake uses NSWorkspace's didWake (and screensDidWake as a backup) on
/// purpose: they fire only on a full, user-visible wake. Power Nap /
/// maintenance "dark wakes" run the app with the lid closed and the
/// display off, and nothing should claim devices during those.
@MainActor
final class PowerMonitor {
    /// Called before sleep. Call the completion when done; sleep waits.
    var onWillSleep: ((@escaping () -> Void) -> Void)?
    var onDidWake: (() -> Void)?

    /// IOKit waits up to ~30 s for an acknowledgement; stay well inside it.
    static let maxSleepDelay: TimeInterval = 20

    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    // IOMessage.h's iokit_common_msg() macros don't import into Swift.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280

    func start() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, argument in
            guard let refcon else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(refcon).takeUnretainedValue()
            // The notification port's source is on the main run loop.
            MainActor.assumeIsolated { monitor.handle(messageType, argument) }
        }, &notifier)
        if rootPort != 0, let notifyPort {
            CFRunLoopAddSource(CFRunLoopGetMain(),
                               IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(),
                               .commonModes)
        } else {
            DiagLog.log("EVENT IORegisterForSystemPower failed — sleep can't be delayed")
        }

        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onDidWake?() }
            }
        }
    }

    private func handle(_ messageType: UInt32, _ argument: UnsafeMutableRawPointer?) {
        let notificationID = Int(bitPattern: argument)
        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, notificationID)
        case Self.systemWillSleep:
            var acked = false
            let ack = { [rootPort] in
                guard !acked else { return }
                acked = true
                IOAllowPowerChange(rootPort, notificationID)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxSleepDelay) { ack() }
            if let onWillSleep {
                onWillSleep { DispatchQueue.main.async { ack() } }
            } else {
                ack()
            }
        default:
            break
        }
    }

    /// True when the main display is on — a full wake, not a dark wake.
    nonisolated static var displayAwake: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) == 0
    }

    // MARK: - Lid

    struct LidState {
        var closed: Bool
        /// False in clamshell mode with an external display: the lid is shut
        /// but the Mac is in use, and the user may wake it with the keyboard.
        var causesSleep: Bool
    }

    nonisolated static func lidState() -> LidState {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(service) }
        func flag(_ key: String) -> Bool? {
            guard service != 0,
                  let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() else { return nil }
            return value as? Bool
        }
        // Desktops have no AppleClamshellState: "never closed".
        return LidState(closed: flag("AppleClamshellState") ?? false,
                        causesSleep: flag("AppleClamshellCausesSleep") ?? true)
    }
}
