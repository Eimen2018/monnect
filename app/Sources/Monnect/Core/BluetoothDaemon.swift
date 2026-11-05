import Darwin

/// macOS's Bluetooth daemon, bluetoothd — identified by pid and start time
/// so a restart is told apart even if the pid gets reused.
///
/// Why it matters (macOS 27, seen on real hardware): when bluetoothd
/// restarts — it crashes on wake now and then — while our devices are
/// unpaired here, IOBluetooth in this process keeps device objects the new
/// daemon no longer knows. Pairing one sends the daemon an empty address
/// (00:00:00:00:00:00); it reports success without pairing anything and
/// crashes again. Only a fresh process gets valid device objects. Devices
/// paired here are unaffected: their record survives the restart.
struct BluetoothDaemon: Equatable {
    let pid: pid_t
    let startedSec: Int
    let startedUsec: Int32

    /// The running bluetoothd, or nil if it isn't running (mid-restart).
    static func current() -> BluetoothDaemon? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return nil }
        let stride = MemoryLayout<kinfo_proc>.stride
        // Room for processes started between the two calls.
        let capacity = size / stride + 32
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return nil }
        for p in procs.prefix(size / stride) {
            var comm = p.kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) {
                String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if name == "bluetoothd" {
                return BluetoothDaemon(pid: p.kp_proc.p_pid,
                                       startedSec: Int(p.kp_proc.p_starttime.tv_sec),
                                       startedUsec: p.kp_proc.p_starttime.tv_usec)
            }
        }
        return nil
    }
}
