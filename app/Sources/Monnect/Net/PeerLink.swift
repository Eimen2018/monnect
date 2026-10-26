import Foundation
import Network
import CryptoKit

/// What each Mac tells the other in every message, both ways. Heartbeats
/// carry it too, so each side always has a recent picture of the other.
struct PeerState: Codable, Equatable {
    var name: String
    /// Fully awake: not asleep and not in a Power Nap dark wake.
    var awake: Bool
    /// Configured devices paired and connected here.
    var holding: [String]
    /// Devices this Mac is actively trying to claim.
    var claiming: [String]
    var devices: [DeviceConfig]
    var devicesUpdatedAt: Date
}

struct PeerRequest: Codable {
    enum Command: String, Codable { case hello, release }
    var v = PeerLink.protocolVersion
    let cmd: Command
    let from: String
    /// The sender's listener port, so the receiver can call back directly
    /// on networks where Bonjour only works one way.
    var listenPort: UInt16?
    let state: PeerState
    /// For release: when the user asked. If both Macs pull at once, the
    /// later click wins.
    var requestedAt: Date?
}

struct PeerResponse: Codable {
    static let newerPull = "newer-pull"
    let ok: Bool
    var error: String?
    let from: String
    let state: PeerState
}

/// Keys derived from the shared secret. The PSK authenticates and encrypts
/// the TLS channel; the fingerprint, published in Bonjour TXT, lets each Mac
/// spot its partner among other Monnect setups on the same network without
/// revealing anything about the key.
struct PeerSecret {
    let psk: Data
    let fingerprint: String

    init(key: Data) {
        let k = SymmetricKey(data: key)
        psk = Data(HMAC<SHA256>.authenticationCode(for: Data("monnect/tls-psk/v2".utf8), using: k))
        let fp = HMAC<SHA256>.authenticationCode(for: Data("monnect/fingerprint/v2".utf8), using: k)
        fingerprint = Data(fp).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

/// The channel between the two Macs: Bonjour discovery, plus a TLS-PSK
/// connection per request (one framed request, one framed response). All
/// state lives on the main actor and every Network.framework callback is
/// delivered on the main queue, so there's nothing to race.
@MainActor
final class PeerLink {
    nonisolated static let protocolVersion = 2
    static let serviceType = "_monnect._tcp"
    /// How recently we must have heard from the other Mac to call it online.
    static let onlineWindow: TimeInterval = 40
    static let heartbeatInterval: TimeInterval = 15

    struct Peer {
        var id: String
        var state: PeerState
        var seen: Date
    }

    let machineID: String
    private let secret: PeerSecret
    private let advertise: Bool

    /// Our current state, sent with every message.
    var stateProvider: () -> PeerState
    /// Handles a release request; returns what to answer.
    var onRelease: ((PeerRequest) async -> PeerResponse)?
    /// The other Mac's state or online status changed.
    var onPeerUpdate: (() -> Void)?
    /// While true (this Mac is asleep), no heartbeats go out.
    var paused = false

    private(set) var peer: Peer?
    var peerOnline: Bool {
        guard let peer else { return false }
        return Date().timeIntervalSince(peer.seen) < Self.onlineWindow
    }
    private var reportedOnline = false

    private var listener: NWListener?
    private(set) var listenPort: UInt16?
    private var browser: NWBrowser?
    /// Bonjour sightings by machine ID. Kept for a while after they vanish:
    /// mDNS results come and go on some networks, the peer usually hasn't.
    private var discovered: [String: (endpoint: NWEndpoint, seen: Date)] = [:]
    private var learned: (endpoint: NWEndpoint, seen: Date)?
    private var manual: NWEndpoint?
    private var lastGood: NWEndpoint?
    private var timers: [Timer] = []
    private var stopped = false
    /// Restarts (mDNSResponder restarts around every sleep and wake) come
    /// back on the same port when it's free, so the address the other Mac
    /// remembered keeps working.
    private var preferredPort: NWEndpoint.Port?
    private var heartbeatInFlight = false

    init(key: Data, machineID: String, advertise: Bool = true, stateProvider: @escaping () -> PeerState) {
        self.secret = PeerSecret(key: key)
        self.machineID = machineID
        self.advertise = advertise
        self.stateProvider = stateProvider
    }

    func start() {
        startListening()
        if advertise { startBrowsing() }
        timers = [
            Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.heartbeat() }
            },
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportIfOnlineChanged() }
            },
        ]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.heartbeat() }
    }

    func stop() {
        stopped = true
        timers.forEach { $0.invalidate() }
        timers = []
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        onRelease = nil
        onPeerUpdate = nil
    }

    /// Restart discovery from scratch — after wake, a browser may sit
    /// silently empty following network changes.
    func restartDiscovery() {
        guard advertise, !stopped else { return }
        startBrowsing()
        heartbeat()
    }

    /// An address to try even without Bonjour (tests, manual setup).
    func setManualEndpoint(_ endpoint: NWEndpoint?) {
        manual = endpoint
    }

    // MARK: - Requests

    /// - Parameter within: overall time budget across all candidate addresses.
    func hello(timeout: TimeInterval = 4, within: TimeInterval = 15) async -> PeerResponse? {
        await send(.hello, requestedAt: nil, replyTimeout: timeout, within: within)
    }

    /// Keeps saying hello until the other Mac answers or time runs out —
    /// right after wake, Wi-Fi and Bonjour take a few seconds to return.
    func helloRetrying(for duration: TimeInterval) async -> PeerResponse? {
        let deadline = Date().addingTimeInterval(duration)
        while !Task.isCancelled {
            if let response = await hello(timeout: 3) { return response }
            if Date() >= deadline { return nil }
            await Task.sleep(seconds: 2)
        }
        return nil
    }

    func requestRelease(requestedAt: Date, timeout: TimeInterval = 10, within: TimeInterval = 20) async -> PeerResponse? {
        await send(.release, requestedAt: requestedAt, replyTimeout: timeout, within: within)
    }

    /// Keeps asking for a release until the other Mac answers or time runs
    /// out — right after launch or wake it may not have been found yet.
    func requestReleaseRetrying(requestedAt: Date, for duration: TimeInterval) async -> PeerResponse? {
        let deadline = Date().addingTimeInterval(duration)
        while !Task.isCancelled {
            if let response = await requestRelease(requestedAt: requestedAt) { return response }
            if Date() >= deadline { return nil }
            await Task.sleep(seconds: 1.5)
        }
        return nil
    }

    private func send(_ cmd: PeerRequest.Command, requestedAt: Date?, replyTimeout: TimeInterval,
                      within: TimeInterval) async -> PeerResponse? {
        let request = PeerRequest(cmd: cmd, from: machineID, listenPort: listenPort,
                                  state: stateProvider(), requestedAt: requestedAt)
        let deadline = Date().addingTimeInterval(within)
        for endpoint in candidates() {
            if stopped || Date() >= deadline { break }
            let conn = NWConnection(to: endpoint, using: parameters())
            defer { conn.cancel() }
            guard await conn.startAndWait(timeout: 3) else {
                if lastGood == endpoint { lastGood = nil }
                continue
            }
            guard await conn.sendFrame(request),
                  let response = await conn.receiveFrame(PeerResponse.self, timeout: replyTimeout),
                  response.from != machineID else {
                // The peer got a release and may have acted on it; asking
                // again elsewhere is harmless (releasing twice is a no-op).
                if lastGood == endpoint { lastGood = nil }
                continue
            }
            lastGood = endpoint
            noteContact(id: response.from, state: response.state)
            return response
        }
        return nil
    }

    /// Where the other Mac might be, best first: the address that worked
    /// last, Bonjour sightings, the address it last called us from, and a
    /// manual address.
    private func candidates() -> [NWEndpoint] {
        let now = Date()
        var list: [NWEndpoint] = []
        if let lastGood { list.append(lastGood) }
        list += discovered.values.sorted { $0.seen > $1.seen }.map(\.endpoint)
        if let learned, now.timeIntervalSince(learned.seen) < 600 { list.append(learned.endpoint) }
        if let manual { list.append(manual) }
        var seen = Set<String>()
        return list.filter { seen.insert($0.debugDescription).inserted }
    }

    private func heartbeat() {
        guard !paused, !stopped, !heartbeatInFlight else { return }
        heartbeatInFlight = true
        Task {
            _ = await hello(within: Self.heartbeatInterval - 1)
            heartbeatInFlight = false
        }
    }

    // MARK: - Peer tracking

    private func noteContact(id: String, state: PeerState) {
        let changed = peer?.state != state || peer?.id != id || !peerOnline
        peer = Peer(id: id, state: state, seen: Date())
        if changed { onPeerUpdate?() }
        reportIfOnlineChanged()
    }

    private func reportIfOnlineChanged() {
        let online = peerOnline
        guard online != reportedOnline else { return }
        reportedOnline = online
        DiagLog.log("EVENT other Mac \(online ? "online" : "offline")\(peer.map { " (\($0.state.name))" } ?? "")")
        onPeerUpdate?()
    }

    // MARK: - Server side

    private func startListening() {
        guard !stopped else { return }
        do {
            let listener: NWListener
            if let port = preferredPort, let reused = try? NWListener(using: parameters(), on: port) {
                listener = reused
            } else {
                listener = try NWListener(using: parameters())
            }
            if advertise {
                var txt = NWTXTRecord()
                txt["v"] = String(Self.protocolVersion)
                txt["id"] = machineID
                txt["fp"] = secret.fingerprint
                listener.service = NWListener.Service(name: machineID, type: Self.serviceType,
                                                      domain: nil, txtRecord: txt)
            }
            listener.newConnectionHandler = { [weak self] conn in
                MainActor.assumeIsolated { self?.accept(conn) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { return }
                    switch state {
                    case .ready:
                        self.listenPort = listener.port?.rawValue
                        self.preferredPort = listener.port
                        DiagLog.log("EVENT listening on port \(self.listenPort ?? 0)")
                    case .failed(let error):
                        DiagLog.log("EVENT listener failed (\(error)) — restarting in 3s")
                        listener.cancel()
                        // The port itself may be the problem; fall back to any.
                        if case .posix(.EADDRINUSE) = error { self.preferredPort = nil }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            if !self.stopped { self.startListening() }
                        }
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            DiagLog.log("EVENT listener error: \(error) — retrying in 5s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                if self?.stopped == false { self?.startListening() }
            }
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        // Nobody gets to hold a connection open by saying nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { conn.cancel() }
        Task {
            defer { conn.cancel() }
            guard let request = await conn.receiveFrame(PeerRequest.self, timeout: 10),
                  request.v == Self.protocolVersion, request.from != machineID else { return }
            noteContact(id: request.from, state: request.state)
            learnEndpoint(of: conn, port: request.listenPort)
            let response: PeerResponse
            switch request.cmd {
            case .hello:
                response = PeerResponse(ok: true, from: machineID, state: stateProvider())
            case .release:
                DiagLog.log("EVENT other Mac asked us to release")
                response = await onRelease?(request)
                    ?? PeerResponse(ok: false, error: "not ready", from: machineID, state: stateProvider())
            }
            _ = await conn.sendFrame(response)
        }
    }

    private func learnEndpoint(of conn: NWConnection, port: UInt16?) {
        guard let port, let nwPort = NWEndpoint.Port(rawValue: port),
              case let .hostPort(host, _) = conn.endpoint else { return }
        let endpoint = NWEndpoint.hostPort(host: host, port: nwPort)
        if learned?.endpoint != endpoint {
            DiagLog.log("EVENT learned other Mac's address \(endpoint)")
        }
        learned = (endpoint, Date())
    }

    // MARK: - Discovery

    private func startBrowsing() {
        browser?.cancel()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.updateDiscovered(results) }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                guard let self, let browser, self.browser === browser, !self.stopped else { return }
                if case .failed(let error) = state {
                    DiagLog.log("EVENT browser failed (\(error)) — restarting in 3s")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if !self.stopped { self.startBrowsing() }
                    }
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func updateDiscovered(_ results: Set<NWBrowser.Result>) {
        let now = Date()
        var current: [String: NWEndpoint] = [:]
        for result in results {
            guard case let .bonjour(txt) = result.metadata,
                  txt["fp"] == secret.fingerprint,
                  let id = txt["id"], id != machineID else { continue }
            current[id] = result.endpoint
        }
        let before = Set(discovered.keys)
        for (id, endpoint) in current { discovered[id] = (endpoint, now) }
        discovered = discovered.filter { current[$0.key] != nil || now.timeIntervalSince($0.value.seen) < 120 }
        if Set(discovered.keys) != before {
            DiagLog.log("EVENT bonjour: other Mac \(discovered.isEmpty ? "gone" : "found")")
        }
        if !current.isEmpty && !peerOnline { heartbeat() }
    }

    // MARK: - TLS-PSK

    private func parameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let psk = secret.psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("monnect".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, identity as __DispatchData)
        // TLS_PSK_WITH_AES_128_GCM_SHA256: Network.framework's PSK support is TLS 1.2.
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: 0x00A8)!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 3
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = false
        return params
    }
}
