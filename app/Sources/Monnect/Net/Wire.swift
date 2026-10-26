import Foundation
import Network

/// Length-prefixed JSON frames: a 4-byte big-endian length, then the body.
/// TCP is a byte stream; the prefix is how the reader knows a message is
/// whole instead of hoping one read returns exactly one message.
enum Frame {
    static let maxLength = 1 << 16

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let body = try JSONEncoder.monnect.encode(value)
        guard body.count <= maxLength else { throw POSIXError(.EMSGSIZE) }
        var length = UInt32(body.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(body)
        return data
    }

    static func length(fromHeader header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let n = header.reduce(0) { ($0 << 8) | Int($1) }
        return (1...maxLength).contains(n) ? n : nil
    }
}

extension NWConnection {
    /// Starts the connection (TLS handshake included) and waits for it to
    /// be ready. False on failure, refusal, or timeout; the caller cancels.
    func startAndWait(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { cont in
            let once = OneShot(cont)
            stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(true)
                // .waiting means no route or refused; don't sit around for it.
                case .failed, .cancelled, .waiting: once.resume(false)
                default: break
                }
            }
            start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.resume(false) }
        }
    }

    func sendFrame<T: Encodable>(_ value: T) async -> Bool {
        guard let data = try? Frame.encode(value) else { return false }
        return await withCheckedContinuation { cont in
            send(content: data, completion: .contentProcessed { error in
                cont.resume(returning: error == nil)
            })
        }
    }

    func receiveFrame<T: Decodable>(_ type: T.Type, timeout: TimeInterval) async -> T? {
        await withCheckedContinuation { cont in
            let once = OneShot<T?>(cont)
            receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, error in
                guard error == nil, let header, let length = Frame.length(fromHeader: header) else {
                    once.resume(nil)
                    return
                }
                self.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                    guard error == nil, let body, body.count == length else {
                        once.resume(nil)
                        return
                    }
                    once.resume(try? JSONDecoder.monnect.decode(T.self, from: body))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        }
    }
}

/// This Mac's IPv4 addresses on Wi-Fi/Ethernet, for "connect by address"
/// fallbacks on networks where Bonjour doesn't get through.
func localIPv4Addresses() -> [String] {
    var result: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let ifa = ptr.pointee
        guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
              ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
              String(cString: ifa.ifa_name).hasPrefix("en") else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                       nil, 0, NI_NUMERICHOST) == 0 {
            result.append(String(cString: host))
        }
    }
    return result
}

/// Parses "192.168.1.20:51234" (or "[fe80::1]:51234").
func parseHostPort(_ text: String) -> NWEndpoint? {
    let s = text.trimmingCharacters(in: .whitespaces)
    guard let colon = s.lastIndex(of: ":"),
          let port = NWEndpoint.Port(String(s[s.index(after: colon)...])) else { return nil }
    var host = String(s[..<colon])
    if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    guard !host.isEmpty else { return nil }
    return .hostPort(host: NWEndpoint.Host(host), port: port)
}
