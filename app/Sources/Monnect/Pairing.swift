import Foundation
import CryptoKit

/// The crypto for code-based pairing: X25519 key agreement, with the
/// six-digit code mixed into the key derivation, so both sides prove they
/// know the code and the joiner receives the config encrypted.
///
/// Scope, honestly: this is not a PAKE. An active man-in-the-middle on the
/// local network during the two-minute window could brute-force the six
/// digits offline from a transcript. The window is short, the code is
/// single-use (one confirm attempt, then the host quits), traffic never
/// leaves the LAN, and the prize is monnect's token — which lets someone
/// unpair a mouse. Anyone who wants more can still copy the token by hand
/// with `Monnect init --token`.
enum PairingCrypto {
    static let info = "monnect-pair-v1"

    static func makeCode() -> String {
        String(format: "%06d", UInt32.random(in: 0..<1_000_000))
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

/// Wire messages for pairing, JSON over one TCP connection on the
/// `_monnect-pair._tcp` service the host advertises while `Monnect pair`
/// runs. Strict request/reply, so each read is one message:
///   joiner: hello{pub,name}  → host: {ok,pub,salt}
///   joiner: confirm{mac}     → host: {ok,payload} / {ok:false,error}
struct PairWireMessage: Codable {
    var v: Int = 1
    let cmd: String          // "hello" | "confirm"
    var pub: String? = nil   // b64 X25519 public key (hello)
    var name: String? = nil  // joiner's computer name (hello)
    var mac: String? = nil   // b64 confirm MAC (confirm)
}

struct PairWireReply: Codable {
    let ok: Bool
    var error: String? = nil
    var pub: String? = nil      // b64 host X25519 public key
    var salt: String? = nil     // b64 16-byte salt
    var payload: String? = nil  // b64 AES-GCM(combined) of PairPayload JSON
}

/// What pairing hands the joiner: everything the second Mac needs.
struct PairPayload: Codable {
    let token: String
    let devices: [DeviceConfig]
}
