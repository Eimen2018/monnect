import Foundation
import Network

/// Peer-to-peer channel between the two Macs. Each instance advertises
/// itself over Bonjour (_monnect._tcp) and browses for the other one.
/// The only message is "release": the receiver unpairs the configured
/// devices so the sender can claim them.
final class PeerService {
    static let serviceType = "_monnect._tcp"

    private let queue = DispatchQueue(label: "monnect.network")
    private let instanceName: String
    private let hostPrefix: String
    private let token: String
    private let devicesProvider: () -> [DeviceConfig]

    /// Instances on the SAME Mac (menu bar app + CLI) must not treat each
    /// other as the peer, so identity is machine-level, not process-level.
    private func isSelf(_ name: String) -> Bool { name.hasPrefix(hostPrefix) }

    private var listener: NWListener?
    private var browser: NWBrowser?
    private(set) var peerNames: [String] = []
    var onPeersChanged: (([String]) -> Void)?

    init(token: String, devicesProvider: @escaping () -> [DeviceConfig]) {
        self.token = token
        self.devicesProvider = devicesProvider
        let host = Host.current().localizedName ?? "Mac"
        self.hostPrefix = "\(host)::"
        self.instanceName = "\(host)::\(ProcessInfo.processInfo.processIdentifier)"
    }

    // MARK: - Server side

    func startListening() {
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: instanceName, type: Self.serviceType)
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(connection: conn)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("monnect: failed to start listener: \(error)")
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self, let data,
                  let msg = try? JSONDecoder().decode(PeerMessage.self, from: data) else {
                connection.cancel()
                return
            }
            guard msg.token == self.token else {
                self.reply(connection, PeerReply(ok: false, error: "bad token"))
                return
            }
            switch msg.cmd {
            case "release":
                // Blocking Bluetooth work off the network queue.
                DispatchQueue.global().async {
                    BluetoothEngine.shared.releaseAll(self.devicesProvider())
                    self.reply(connection, PeerReply(ok: true, error: nil))
                }
            case "ping":
                self.reply(connection, PeerReply(ok: true, error: nil))
            default:
                self.reply(connection, PeerReply(ok: false, error: "unknown cmd"))
            }
        }
    }

    private func reply(_ connection: NWConnection, _ reply: PeerReply) {
        let data = (try? JSONEncoder().encode(reply)) ?? Data()
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Client side

    func startBrowsing() {
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.peerNames = results.compactMap { result in
                if case let .service(name, _, _, _) = result.endpoint, !self.isSelf(name) {
                    return name
                }
                return nil
            }
            self.onPeersChanged?(self.peerNames)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func firstPeerEndpoint() -> NWEndpoint? {
        guard let browser else { return nil }
        for result in browser.browseResults {
            if case let .service(name, _, _, _) = result.endpoint, !isSelf(name) {
                return result.endpoint
            }
        }
        return nil
    }

    /// Ask the other Mac to unpair the peripherals. Completion receives an
    /// error string, or nil on success. Times out rather than hanging.
    func sendRelease(timeout: TimeInterval = 15, completion: @escaping (String?) -> Void) {
        guard let endpoint = firstPeerEndpoint() else {
            completion("other Mac not found on the network")
            return
        }
        let conn = NWConnection(to: endpoint, using: .tcp)
        var finished = false
        let finish: (String?) -> Void = { err in
            guard !finished else { return }
            finished = true
            conn.cancel()
            completion(err)
        }
        queue.asyncAfter(deadline: .now() + timeout) { finish("timed out waiting for the other Mac") }
        conn.stateUpdateHandler = { state in
            if case let .failed(err) = state { finish(err.localizedDescription) }
        }
        conn.start(queue: queue)
        let msg = PeerMessage(cmd: "release", token: token)
        conn.send(content: try? JSONEncoder().encode(msg), completion: .contentProcessed { err in
            if let err { finish(err.localizedDescription); return }
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                guard let data,
                      let reply = try? JSONDecoder().decode(PeerReply.self, from: data) else {
                    finish("no reply from the other Mac")
                    return
                }
                finish(reply.ok ? nil : (reply.error ?? "release refused"))
            }
        })
    }
}

struct PeerMessage: Codable {
    let cmd: String
    let token: String
}

struct PeerReply: Codable {
    let ok: Bool
    let error: String?
}
