import Foundation

/// Diagnostic log at ~/Library/Logs/Monnect.log, rotated at 2 MB into
/// Monnect.1.log. Records Bluetooth operations and lifecycle events so
/// reliability problems can be diagnosed from evidence, not anecdotes.
enum DiagLog {
    static let url: URL = {
        // Dev/test instances (MONNECT_CONFIG_DIR) log next to their config.
        if let dir = ProcessInfo.processInfo.environment["MONNECT_CONFIG_DIR"] {
            return URL(fileURLWithPath: dir).appendingPathComponent("Monnect.log")
        }
        // Tests never write the real log.
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("Monnect-tests.log")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Monnect.log")
    }()

    private static let maxBytes: UInt64 = 2_000_000
    private static let queue = DispatchQueue(label: "monnect.diaglog")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                try? handle.write(contentsOf: data)
                if size > maxBytes { rotate() }
            } else {
                // Device addresses and computer names: private to this user.
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: data,
                                               attributes: [.posixPermissions: 0o600])
            }
        }
    }

    private static func rotate() {
        let old = url.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
}
