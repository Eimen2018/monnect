import Foundation
import CryptoKit

/// The crypto for code-based pairing: X25519 key agreement, with the
/// pairing code mixed into the key derivation, so both sides prove they
/// know the code and the joiner receives the config encrypted.
///
/// This is not a PAKE (CryptoKit has none), so whoever answers the first
/// code-dependent message — including a fake host advertising on the LAN —
/// can try codes offline against it. The code is therefore long: 10
/// Crockford base-32 characters, 50 bits, which no offline search covers
/// within the code's five-minute life. Online guessing at the real host is
/// capped at a few attempts.
enum PairingCrypto {
    static let info = "monnect-pair-v2"
    /// Crockford base-32: no I, L, O, U, so codes read and type cleanly.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let codeLength = 10

    static func makeCode() -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<codeLength).map { _ in alphabet[Int(rng.next(upperBound: UInt32(alphabet.count)))] })
    }

    /// "k7qm2-xfd9p", "K7QM2 XFD9P", Arabic-Indic digits, O for 0 … → the
    /// canonical code, or nil if it can't be one.
    static func normalize(_ input: String) -> String? {
        var out = ""
        for ch in input.uppercased() {
            if ch.isWhitespace || ch == "-" { continue }
            if let digit = ch.wholeNumberValue, (0...9).contains(digit) {
                out.append(Character(String(digit)))
                continue
            }
            switch ch {
            case "O": out.append("0")
            case "I", "L": out.append("1")
            default:
                guard alphabet.contains(ch) else { return nil }
                out.append(ch)
            }
        }
        return out.count == codeLength ? out : nil
    }

    /// Formats a code as it's typed: uppercase, digits from any script as
    /// ASCII, anything else dropped, and the dash put in for you once the
    /// sixth character arrives (not at five, so backspacing over it works).
    static func formatTyping(_ input: String) -> String {
        var chars: [Character] = []
        for ch in input.uppercased() where chars.count < codeLength {
            if let digit = ch.wholeNumberValue, (0...9).contains(digit) {
                chars.append(Character(String(digit)))
            } else if ch.isASCII, ch.isLetter {
                chars.append(ch)
            }
        }
        if chars.count > 5 { chars.insert("-", at: 5) }
        return String(chars)
    }

    /// "K7QM2XFD9P" → "K7QM2-XFD9P"
    static func display(_ code: String) -> String {
        guard code.count == codeLength else { return code }
        return "\(code.prefix(5))-\(code.suffix(5))"
    }

    static func makeSalt() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// Both sides derive the same key from the ECDH secret, the salt, and
    /// the code. A wrong code yields a different key, so the confirm MAC
    /// and the payload's GCM tag both fail.
    static func deriveKey(privateKey: Curve25519.KeyAgreement.PrivateKey,
                          peerPublic: Data, salt: Data, code: String) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublic)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt,
            sharedInfo: Data("\(info)|\(code)".utf8), outputByteCount: 32)
    }

    /// Transcript both MACs and the payload bind to: who's who and what
    /// public keys this exchange used.
    static func transcript(joinerPub: Data, hostPub: Data, salt: Data) -> Data {
        var t = Data("\(info)|transcript".utf8)
        t.append(joinerPub)
        t.append(hostPub)
        t.append(salt)
        return t
    }

    /// The joiner's proof that it knows the code.
    static func confirmMAC(key: SymmetricKey, joinerPub: Data, hostPub: Data, salt: Data) -> Data {
        var msg = Data("join|".utf8)
        msg.append(transcript(joinerPub: joinerPub, hostPub: hostPub, salt: salt))
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: key))
    }

    static func verifyConfirm(_ mac: Data, key: SymmetricKey,
                              joinerPub: Data, hostPub: Data, salt: Data) -> Bool {
        var msg = Data("join|".utf8)
        msg.append(transcript(joinerPub: joinerPub, hostPub: hostPub, salt: salt))
        // Constant-time check.
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: msg, using: key)
    }

    /// Host → joiner: the config, sealed under the code-derived key. The GCM
    /// tag doubles as the host's proof that it knows the code.
    static func sealPayload(_ plaintext: Data, key: SymmetricKey,
                            joinerPub: Data, hostPub: Data, salt: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key,
                                      authenticating: transcript(joinerPub: joinerPub, hostPub: hostPub, salt: salt))
        guard let combined = sealed.combined else {
            throw NSError(domain: "monnect.pair", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "sealing failed"])
        }
        return combined
    }

    static func openPayload(_ combined: Data, key: SymmetricKey,
                            joinerPub: Data, hostPub: Data, salt: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key,
                                authenticating: transcript(joinerPub: joinerPub, hostPub: hostPub, salt: salt))
    }
}

/// Wire messages for pairing: length-prefixed JSON frames over one TCP
/// connection to the `_monnect-pair._tcp` service the host advertises
/// while its pairing code is showing. Strict request/reply:
///   joiner: hello{pub,name}  → host: {ok,pub,salt,name}
///   joiner: confirm{mac}     → host: {ok,payload} / {ok:false,error}
struct PairWireMessage: Codable {
    var v: Int = 2
    let cmd: String          // "hello" | "confirm"
    var pub: String? = nil   // b64 X25519 public key (hello)
    var name: String? = nil  // joiner's computer name (hello)
    var mac: String? = nil   // b64 confirm MAC (confirm)
}

struct PairWireReply: Codable {
    static let wrongCode = "wrong code"
    let ok: Bool
    var error: String? = nil
    var pub: String? = nil      // b64 host X25519 public key
    var salt: String? = nil     // b64 16-byte salt
    var name: String? = nil     // host's computer name
    var payload: String? = nil  // b64 AES-GCM(combined) of PairPayload JSON
}

/// What pairing hands the joiner: everything the second Mac needs.
struct PairPayload: Codable {
    let key: String
    let devices: [DeviceConfig]
    let devicesUpdatedAt: Date
}
