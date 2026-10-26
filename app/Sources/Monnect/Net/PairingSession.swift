import Foundation
import Network
import CryptoKit

/// The Mac that's already set up shows a pairing code and waits; the
/// other Mac finds it (Bonjour, or the address shown under the code) and
/// proves it knows the code. The key and device list travel encrypted
/// under a key only the code unlocks (see PairingCrypto).
@MainActor
final class PairingHost: ObservableObject {
    static let serviceType = "_monnect-pair._tcp"
    static let lifetime: TimeInterval = 300
    /// Wrong guesses allowed per code — enough that a stray connection
    /// can't burn it, far too few to guess a 50-bit code.
    static let maxAttempts = 5

    enum Status: Equatable {
        case starting
        case waiting(code: String, addresses: [String])
        case paired(name: String)
        case failed(String)
    }

    @Published private(set) var status: Status = .starting

    private let payload: PairPayload
    private let advertise: Bool
    private var listener: NWListener?
    private var code = ""
    private var hostKey = Curve25519.KeyAgreement.PrivateKey()
    private var salt = PairingCrypto.makeSalt()
    private var wrongAttempts = 0
    /// Bumped per code, so a connection from an earlier code can't spend
    /// an attempt against a new one.
    private var generation = 0
    private var expiry: DispatchWorkItem?

    init(payload: PairPayload, advertise: Bool = true) {
        self.payload = payload
        self.advertise = advertise
    }

    var port: UInt16? { listener?.port?.rawValue }

    func start() {
        stop()
        code = PairingCrypto.makeCode()
        hostKey = Curve25519.KeyAgreement.PrivateKey()
        salt = PairingCrypto.makeSalt()
        wrongAttempts = 0
        generation += 1
        status = .starting
        do {
            let listener = try NWListener(using: .tcp)
            if advertise {
                listener.service = NWListener.Service(name: computerName, type: Self.serviceType)
            }
            listener.newConnectionHandler = { [weak self] conn in
                MainActor.assumeIsolated { self?.handle(conn) }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        let port = listener.port?.rawValue ?? 0
                        self.status = .waiting(code: self.code,
                                               addresses: localIPv4Addresses().map { "\($0):\(port)" })
                    case .failed(let error):
                        self.finish(.failed("Couldn't start pairing: \(error.localizedDescription)"))
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            status = .failed("Couldn't start pairing: \(error.localizedDescription)")
            return
        }
        let expiry = DispatchWorkItem { [weak self] in
            self?.finish(.failed("The code expired. Show a new one when your other Mac is ready."))
        }
        self.expiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime, execute: expiry)
    }

    func stop() {
        expiry?.cancel()
        listener?.cancel()
        listener = nil
    }

    private func finish(_ status: Status) {
        stop()
        self.status = status
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { conn.cancel() }
        let session = generation
        let hostKey = self.hostKey, salt = self.salt, code = self.code
        Task {
            defer { conn.cancel() }
            guard let hello = await conn.receiveFrame(PairWireMessage.self, timeout: 15),
                  hello.cmd == "hello",
                  let joinerPub = hello.pub.flatMap({ Data(base64Encoded: $0) }), joinerPub.count == 32 else {
                _ = await conn.sendFrame(PairWireReply(ok: false, error: "bad hello"))
                return
            }
            let hostPub = hostKey.publicKey.rawRepresentation
            guard await conn.sendFrame(PairWireReply(ok: true, pub: hostPub.base64EncodedString(),
                                                     salt: salt.base64EncodedString(), name: computerName)),
                  let confirm = await conn.receiveFrame(PairWireMessage.self, timeout: 30) else { return }
            guard session == generation, listener != nil else {
                _ = await conn.sendFrame(PairWireReply(ok: false, error: "this code is no longer valid"))
                return
            }
            guard confirm.cmd == "confirm",
                  let mac = confirm.mac.flatMap({ Data(base64Encoded: $0) }),
                  let key = try? PairingCrypto.deriveKey(privateKey: hostKey, peerPublic: joinerPub,
                                                         salt: salt, code: code),
                  PairingCrypto.verifyConfirm(mac, key: key, joinerPub: joinerPub, hostPub: hostPub, salt: salt) else {
                wrongAttempts += 1
                _ = await conn.sendFrame(PairWireReply(ok: false, error: PairWireReply.wrongCode))
                DiagLog.log("EVENT pairing: wrong code entered (\(wrongAttempts)/\(Self.maxAttempts))")
                if wrongAttempts >= Self.maxAttempts {
                    finish(.failed("Too many wrong codes were entered. Show a new code to try again."))
                }
                return
            }
            guard let plaintext = try? JSONEncoder.monnect.encode(payload),
                  let sealed = try? PairingCrypto.sealPayload(plaintext, key: key, joinerPub: joinerPub,
                                                              hostPub: hostPub, salt: salt) else {
                _ = await conn.sendFrame(PairWireReply(ok: false, error: "internal error"))
                finish(.failed("Pairing failed (internal error)."))
                return
            }
            _ = await conn.sendFrame(PairWireReply(ok: true, payload: sealed.base64EncodedString()))
            let name = hello.name ?? "your other Mac"
            DiagLog.log("EVENT paired with \(name)")
            finish(.paired(name: name))
        }
    }
}

enum PairingJoin {
    enum Failure: LocalizedError, Equatable {
        case badCode, notFound, noAnswer, wrongCode, failed(String)

        var errorDescription: String? {
            switch self {
            case .badCode: return "That doesn't look like a pairing code. It's the ten letters and numbers shown on your other Mac."
            case .notFound: return "Couldn't find your other Mac. Check it's showing a code and is on the same network — or enter the address shown under the code."
            case .noAnswer: return "Your other Mac didn't answer. Try again."
            case .wrongCode: return "Wrong code. Check it against your other Mac and try again."
            case .failed(let why): return "Pairing failed: \(why)"
            }
        }
    }

    struct Result {
        let payload: PairPayload
        let hostName: String
    }

    /// - Parameter address: "host:port" when Bonjour can't find the host.
    @MainActor
    static func run(code rawCode: String, address: String?) async throws -> Result {
        guard let code = PairingCrypto.normalize(rawCode) else { throw Failure.badCode }

        let endpoints: [NWEndpoint]
        if let address, !address.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let parsed = parseHostPort(address) else {
                throw Failure.failed("that address doesn't look like 192.168.1.20:51234")
            }
            endpoints = [parsed]
        } else {
            endpoints = await findHosts(timeout: 10)
            guard !endpoints.isEmpty else { throw Failure.notFound }
        }
        // More than one Mac may be showing a code; the right one accepts ours.
        var lastError = Failure.noAnswer
        for endpoint in endpoints {
            do {
                return try await attempt(endpoint, code: code)
            } catch let failure as Failure {
                lastError = failure
            }
        }
        throw lastError
    }

    @MainActor
    private static func attempt(_ endpoint: NWEndpoint, code: String) async throws -> Result {
        let conn = NWConnection(to: endpoint, using: .tcp)
        defer { conn.cancel() }
        guard await conn.startAndWait(timeout: 6) else { throw Failure.noAnswer }

        let joinerKey = Curve25519.KeyAgreement.PrivateKey()
        let joinerPub = joinerKey.publicKey.rawRepresentation
        guard await conn.sendFrame(PairWireMessage(cmd: "hello", pub: joinerPub.base64EncodedString(),
                                                   name: computerName)),
              let helloReply = await conn.receiveFrame(PairWireReply.self, timeout: 10) else {
            throw Failure.noAnswer
        }
        guard helloReply.ok,
              let hostPub = helloReply.pub.flatMap({ Data(base64Encoded: $0) }), hostPub.count == 32,
              let salt = helloReply.salt.flatMap({ Data(base64Encoded: $0) }) else {
            throw Failure.failed(helloReply.error ?? "unexpected reply")
        }
        guard let key = try? PairingCrypto.deriveKey(privateKey: joinerKey, peerPublic: hostPub,
                                                     salt: salt, code: code) else {
            throw Failure.failed("key agreement failed")
        }
        let mac = PairingCrypto.confirmMAC(key: key, joinerPub: joinerPub, hostPub: hostPub, salt: salt)
        guard await conn.sendFrame(PairWireMessage(cmd: "confirm", mac: mac.base64EncodedString())),
              let reply = await conn.receiveFrame(PairWireReply.self, timeout: 10) else {
            throw Failure.noAnswer
        }
        guard reply.ok else {
            throw reply.error == PairWireReply.wrongCode ? Failure.wrongCode : Failure.failed(reply.error ?? "refused")
        }
        guard let sealed = reply.payload.flatMap({ Data(base64Encoded: $0) }),
              let plaintext = try? PairingCrypto.openPayload(sealed, key: key, joinerPub: joinerPub,
                                                             hostPub: hostPub, salt: salt),
              let payload = try? JSONDecoder.monnect.decode(PairPayload.self, from: plaintext),
              Data(base64Encoded: payload.key)?.count == 32 else {
            throw Failure.failed("couldn't read the reply")
        }
        return Result(payload: payload, hostName: helloReply.name ?? "your other Mac")
    }

    /// Every Mac advertising a pairing code, gathered for a moment after
    /// the first one shows up.
    @MainActor
    private static func findHosts(timeout: TimeInterval) async -> [NWEndpoint] {
        let browser = NWBrowser(for: .bonjour(type: PairingHost.serviceType, domain: nil), using: .tcp)
        defer { browser.cancel() }
        final class Found: @unchecked Sendable { var endpoints: [NWEndpoint] = [] }  // main queue only
        let found = Found()
        return await withCheckedContinuation { cont in
            let once = OneShot<[NWEndpoint]>(cont)
            browser.browseResultsChangedHandler = { results, _ in
                let wasEmpty = found.endpoints.isEmpty
                found.endpoints = results.map(\.endpoint)
                if wasEmpty && !found.endpoints.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { once.resume(found.endpoints) }
                }
            }
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.resume(found.endpoints) }
        }
    }
}
