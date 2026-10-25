import Foundation
import Network
import CryptoKit

/// `Monnect pair` / `Monnect join` — code-based setup for the second Mac.
/// The Mac that already has a config runs `pair` and shows a six-digit
/// code; the other runs `join`, finds it over Bonjour, and types the code.
/// The token and device list travel encrypted under a key both sides can
/// only derive with the code (see PairingCrypto).
enum PairCommand {
    static let serviceType = "_monnect-pair._tcp"
    private static let queue = DispatchQueue(label: "monnect.pair")

    // MARK: - Host side (`Monnect pair`)

    static func runHost() -> Int32 {
        guard let config = Config.load() else {
            err("no config at \(Config.fileURL.path) — run `Monnect init` first")
            return 2
        }
        let code = PairingCrypto.makeCode()
        let hostKey = Curve25519.KeyAgreement.PrivateKey()
        let hostPub = hostKey.publicKey.rawRepresentation
        let salt = PairingCrypto.makeSalt()

        let done = DispatchSemaphore(value: 0)
        var result: Int32 = 1
        // One confirm evaluation per run, however many connections arrive.
        // All connection callbacks share the serial `queue`, so a plain var
        // is enough. Without this, several joiners that said hello could
        // each get a code guess evaluated before the listener shuts down.
        var attemptUsed = false

        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp)
        } catch {
            err("could not open a listener: \(error)")
            return 1
        }
        let hostName = Host.current().localizedName ?? "Mac"
        listener.service = NWListener.Service(name: hostName, type: serviceType)
        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            receiveMessage(conn) { hello in
                guard let hello, hello.cmd == "hello",
                      let pubB64 = hello.pub,
                      let joinerPub = Data(base64Encoded: pubB64), joinerPub.count == 32 else {
                    send(conn, PairWireReply(ok: false, error: "bad hello")) { conn.cancel() }
                    return
                }
                let reply = PairWireReply(ok: true, pub: hostPub.base64EncodedString(),
                                          salt: salt.base64EncodedString())
                send(conn, reply) {
                    receiveMessage(conn) { confirm in
                        guard !attemptUsed else {
                            send(conn, PairWireReply(ok: false, error: "pairing already attempted")) { conn.cancel() }
                            return
                        }
                        attemptUsed = true
                        guard let confirm, confirm.cmd == "confirm",
                              let macB64 = confirm.mac,
                              let mac = Data(base64Encoded: macB64),
                              let key = try? PairingCrypto.deriveKey(
                                privateKey: hostKey, peerPublic: joinerPub, salt: salt, code: code),
                              PairingCrypto.verifyConfirm(mac, key: key, joinerPub: joinerPub,
                                                          hostPub: hostPub, salt: salt) else {
                            // One attempt per run: a guessed code never gets
                            // a second try against the same exchange.
                            send(conn, PairWireReply(ok: false, error: "wrong code")) {
                                conn.cancel()
                                print("Wrong code — run `Monnect pair` again for a new one.")
                                result = 1
                                done.signal()
                            }
                            return
                        }
                        let payload = PairPayload(token: config.token, devices: config.devices)
                        guard let plaintext = try? JSONEncoder().encode(payload),
                              let sealed = try? PairingCrypto.sealPayload(
                                plaintext, key: key, joinerPub: joinerPub,
                                hostPub: hostPub, salt: salt) else {
                            send(conn, PairWireReply(ok: false, error: "internal error")) { conn.cancel() }
                            return
                        }
                        send(conn, PairWireReply(ok: true, payload: sealed.base64EncodedString())) {
                            conn.cancel()
                            print("Paired with \(hello.name ?? "the other Mac").")
                            result = 0
                            done.signal()
                        }
                    }
                }
            }
        }
        listener.stateUpdateHandler = { state in
            if case let .failed(e) = state {
                err("listener failed: \(e)")
                done.signal()
            }
        }
        listener.start(queue: queue)

        print("""

        Pairing code:  \(code)

        On your OTHER Mac, run:  Monnect join
        and enter the code. Waiting 2 minutes…
        """)
        fflush(stdout)  // show the code even when piped
        if done.wait(timeout: .now() + 120) == .timedOut {
            print("Nobody joined — run `Monnect pair` again when the other Mac is ready.")
            result = 1
        }
        listener.cancel()
        return result
    }

    // MARK: - Joiner side (`Monnect join`)

    static func runJoin(args: [String]) -> Int32 {
        let url = Config.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            print("Config already exists at \(url.path). Overwrite? [y/N] ", terminator: "")
            guard readLine()?.lowercased() == "y" else {
                print("aborted")
                return 1
            }
        }

        var code: String
        if let idx = args.firstIndex(of: "--code"), idx + 1 < args.count {
            code = args[idx + 1]
        } else {
            print("Code shown by `Monnect pair` on the other Mac: ", terminator: "")
            code = readLine() ?? ""
        }
        code = code.trimmingCharacters(in: .whitespaces)
        // ASCII 0-9 only: Character.isNumber also accepts other scripts'
        // digits, which would derive a different key and burn the attempt.
        guard code.count == 6, code.allSatisfy({ "0"..."9" ~= $0 }) else {
            err("the code is the six digits shown on the other Mac")
            return 64
        }

        print("Looking for the other Mac…")
        guard let endpoint = findPairService(timeout: 15) else {
            err("""
            No Mac offering to pair was found on this network. On the other \
            Mac, run `Monnect pair` first, and check both Macs are on the \
            same network.
            """)
            return 1
        }

        let joinerKey = Curve25519.KeyAgreement.PrivateKey()
        let joinerPub = joinerKey.publicKey.rawRepresentation
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.start(queue: queue)
        defer { conn.cancel() }

        let myName = Host.current().localizedName ?? "Mac"
        guard let helloReply = roundTrip(conn, PairWireMessage(
                cmd: "hello", pub: joinerPub.base64EncodedString(), name: myName)),
              helloReply.ok,
              let hostPub = helloReply.pub.flatMap({ Data(base64Encoded: $0) }), hostPub.count == 32,
              let salt = helloReply.salt.flatMap({ Data(base64Encoded: $0) }) else {
            err("the other Mac didn't answer the pairing request")
            return 1
        }
        guard let key = try? PairingCrypto.deriveKey(
                privateKey: joinerKey, peerPublic: hostPub, salt: salt, code: code) else {
            err("key agreement failed")
            return 1
        }
        let mac = PairingCrypto.confirmMAC(key: key, joinerPub: joinerPub,
                                           hostPub: hostPub, salt: salt)
        guard let confirmReply = roundTrip(conn, PairWireMessage(
                cmd: "confirm", mac: mac.base64EncodedString())) else {
            err("the other Mac didn't answer the code check")
            return 1
        }
        guard confirmReply.ok,
              let sealed = confirmReply.payload.flatMap({ Data(base64Encoded: $0) }),
              let plaintext = try? PairingCrypto.openPayload(
                sealed, key: key, joinerPub: joinerPub, hostPub: hostPub, salt: salt),
              let payload = try? JSONDecoder().decode(PairPayload.self, from: plaintext) else {
            err(confirmReply.error == "wrong code"
                ? "Wrong code. Run `Monnect pair` on the other Mac for a new one and try again."
                : "pairing failed: \(confirmReply.error ?? "bad reply")")
            return 1
        }

        let config = Config(token: payload.token, devices: payload.devices)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: url, options: .atomic)
            // The token lives in here; keep it out of other users' reach.
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: url.path)
        } catch {
            err("failed to write config: \(error)")
            return 1
        }

        print("""

        Paired. Wrote \(url.path)
        Devices: \(payload.devices.map(\.name).joined(separator: ", "))

        Launch Monnect.app on this Mac, allow the Bluetooth, local network,
        and firewall prompts, and add it to Login Items.
        """)
        return 0
    }

    // MARK: - Plumbing

    /// Browse Bonjour for a `Monnect pair` host; first hit wins.
    private static func findPairService(timeout: TimeInterval) -> NWEndpoint? {
        let sema = DispatchSemaphore(value: 0)
        var found: NWEndpoint?
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            if found == nil, let first = results.first {
                found = first.endpoint
                sema.signal()
            }
        }
        browser.start(queue: queue)
        _ = sema.wait(timeout: .now() + timeout)
        browser.cancel()
        return found
    }

    /// One JSON message off a connection. The exchange is strict
    /// request/reply, so there is never more than one message in flight and
    /// each read is one whole message.
    private static func receiveMessage(_ conn: NWConnection,
                                       _ handler: @escaping (PairWireMessage?) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            guard let data, let msg = try? JSONDecoder().decode(PairWireMessage.self, from: data) else {
                handler(nil)
                return
            }
            handler(msg)
        }
    }

    private static func send(_ conn: NWConnection, _ reply: PairWireReply,
                             then: @escaping () -> Void) {
        let data = (try? JSONEncoder().encode(reply)) ?? Data()
        conn.send(content: data, completion: .contentProcessed { _ in then() })
    }

    /// Joiner side: send one message, wait for one reply.
    private static func roundTrip(_ conn: NWConnection, _ msg: PairWireMessage,
                                  timeout: TimeInterval = 20) -> PairWireReply? {
        let sema = DispatchSemaphore(value: 0)
        var reply: PairWireReply?
        conn.send(content: try? JSONEncoder().encode(msg), completion: .contentProcessed { sendErr in
            if sendErr != nil { sema.signal(); return }
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, _, _ in
                if let data { reply = try? JSONDecoder().decode(PairWireReply.self, from: data) }
                sema.signal()
            }
        })
        _ = sema.wait(timeout: .now() + timeout)
        return reply
    }

    private static func err(_ msg: String) {
        FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    }
}
