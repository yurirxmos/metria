import CryptoKit
import Foundation
import Security

/// Derives a single high-entropy pairing secret into everything Metria needs to connect
/// the Mac app to the mobile PWA over ntfy: a routing topic and an encryption key.
///
/// The secret itself is represented two ways for pairing: a QR code (see `Metria`'s
/// `PairingManager`) and a 12-word BIP-39-style phrase, mirroring how hardware wallets
/// present a recovery phrase. Both encode the same 128 bits of entropy, so a device can
/// pair by scanning the QR code or by typing the phrase.
public enum PairingSecret {
    /// 128 bits of entropy, matching a standard 12-word BIP-39 mnemonic.
    public static let entropyByteCount = 16
    private static let wordCount = 12
    private static let checksumBitCount = entropyByteCount * 8 / 32

    public static func generate() -> Data {
        var bytes = [UInt8](repeating: 0, count: entropyByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, entropyByteCount, &bytes)
        precondition(status == errSecSuccess, "Failed to generate random pairing secret")
        return Data(bytes)
    }

    /// Encodes the secret as a 12-word phrase, appending a checksum derived from
    /// SHA-256 so a typo when re-entering the phrase can be detected on decode.
    public static func words(from secret: Data) -> [String] {
        precondition(secret.count == entropyByteCount)
        let allBits = bits(from: secret) + checksumBits(for: secret)
        var result: [String] = []
        result.reserveCapacity(wordCount)
        var index = allBits.startIndex
        while index < allBits.endIndex {
            let chunk = allBits[index..<index + 11]
            let value = chunk.reduce(0) { ($0 << 1) | ($1 ? 1 : 0) }
            result.append(bip39Wordlist[value])
            index += 11
        }
        return result
    }

    /// Reverses `words(from:)`, validating the checksum. Returns `nil` if a word isn't
    /// in the wordlist or the checksum doesn't match (most likely a typo).
    public static func secret(from words: [String]) -> Data? {
        guard words.count == wordCount else { return nil }
        var allBits: [Bool] = []
        allBits.reserveCapacity(wordCount * 11)
        for word in words {
            guard let wordIndex = bip39Wordlist.firstIndex(of: word.lowercased()) else { return nil }
            for shift in stride(from: 10, through: 0, by: -1) {
                allBits.append(((wordIndex >> shift) & 1) == 1)
            }
        }
        let entropyBitCount = entropyByteCount * 8
        let entropyBits = Array(allBits.prefix(entropyBitCount))
        let providedChecksum = Array(allBits.suffix(checksumBitCount))
        let entropy = Data(bytes(from: entropyBits))
        guard providedChecksum == checksumBits(for: entropy) else { return nil }
        return entropy
    }

    /// Derives the ntfy topic name from the secret via HKDF-SHA256. The topic is not a
    /// secret on its own; confidentiality comes entirely from `encryptionKey(from:)`.
    public static func topic(from secret: Data) -> String {
        let bytes = derive(from: secret, info: "metria-topic-v1", byteCount: 16)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Derives the AES-256 key used to encrypt/decrypt published usage snapshots.
    public static func encryptionKey(from secret: Data) -> SymmetricKey {
        SymmetricKey(data: derive(from: secret, info: "metria-key-v1", byteCount: 32))
    }

    /// Derives the token clients present to the local `/snapshot` endpoint, so a header
    /// captured on the LAN cannot also unlock the ntfy relay the master secret protects.
    public static func localToken(from secret: Data) -> String {
        base64URLEncode(derive(from: secret, info: "metria-local-token-v1", byteCount: 32))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func derive(from secret: Data, info: String, byteCount: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data(),
            info: Data(info.utf8),
            outputByteCount: byteCount
        )
        return key.withUnsafeBytes { Data($0) }
    }

    private static func checksumBits(for entropy: Data) -> [Bool] {
        let hash = SHA256.hash(data: entropy)
        return Array(bits(from: Data(hash)).prefix(checksumBitCount))
    }

    private static func bits(from data: Data) -> [Bool] {
        var result: [Bool] = []
        result.reserveCapacity(data.count * 8)
        for byte in data {
            for shift in stride(from: 7, through: 0, by: -1) {
                result.append(((byte >> shift) & 1) == 1)
            }
        }
        return result
    }

    private static func bytes(from bits: [Bool]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bits.count / 8)
        var index = bits.startIndex
        while index < bits.endIndex {
            var byte: UInt8 = 0
            for offset in 0..<8 {
                byte = (byte << 1) | (bits[index + offset] ? 1 : 0)
            }
            result.append(byte)
            index += 8
        }
        return result
    }
}
