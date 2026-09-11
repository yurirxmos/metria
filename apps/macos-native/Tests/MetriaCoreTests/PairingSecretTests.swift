import CryptoKit
import XCTest
@testable import MetriaCore

final class PairingSecretTests: XCTestCase {
    func testGeneratedSecretIsSixteenBytes() {
        let secret = PairingSecret.generate()
        XCTAssertEqual(secret.count, PairingSecret.entropyByteCount)
    }

    func testGeneratedSecretRoundTripsThroughWordsAndSecret() {
        let secret = PairingSecret.generate()
        let words = PairingSecret.words(from: secret)
        XCTAssertEqual(words.count, 12)
        XCTAssertEqual(PairingSecret.secret(from: words), secret)
    }

    func testWordsRoundTripThroughSecret() {
        let secret = PairingSecret.generate()
        let words = PairingSecret.words(from: secret)
        let decoded = PairingSecret.secret(from: words)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(PairingSecret.words(from: decoded!), words)
    }

    func testWrongWordCountIsNil() {
        let words = PairingSecret.words(from: PairingSecret.generate())
        XCTAssertNil(PairingSecret.secret(from: Array(words.dropLast())))
        XCTAssertNil(PairingSecret.secret(from: words + ["abandon"]))
    }

    func testNonWordlistWordIsNil() {
        let words = PairingSecret.words(from: PairingSecret.generate())
        var mutated = words
        mutated[0] = "notaword"
        XCTAssertNil(PairingSecret.secret(from: mutated))
    }

    func testChecksumRejectsSubstitutionWithAnotherWord() {
        let words = PairingSecret.words(from: PairingSecret.generate())
        guard let lastWordIndex = bip39Wordlist.firstIndex(of: words.last!) else {
            return XCTFail("Last word is not in the BIP-39 wordlist")
        }
        // Swapping the last word for a neighbor in the same 16-word block keeps the seven
        // entropy bits it encodes identical while flipping at least one checksum bit, so
        // the substitution must be rejected deterministically rather than by chance.
        let blockStart = (lastWordIndex / 16) * 16
        let replacementIndex = (lastWordIndex + 1 - blockStart) % 16 + blockStart
        var mutated = words
        mutated[mutated.count - 1] = bip39Wordlist[replacementIndex]
        XCTAssertNil(PairingSecret.secret(from: mutated))
    }

    func testDerivationsAreDeterministicAndDistinctPerSecret() {
        let secretA = PairingSecret.generate()
        let secretB = PairingSecret.generate()

        XCTAssertEqual(PairingSecret.topic(from: secretA), PairingSecret.topic(from: secretA))
        XCTAssertEqual(PairingSecret.localToken(from: secretA), PairingSecret.localToken(from: secretA))
        XCTAssertEqual(keyBytes(PairingSecret.encryptionKey(from: secretA)), keyBytes(PairingSecret.encryptionKey(from: secretA)))

        XCTAssertNotEqual(PairingSecret.topic(from: secretA), PairingSecret.topic(from: secretB))
        XCTAssertNotEqual(PairingSecret.localToken(from: secretA), PairingSecret.localToken(from: secretB))
        XCTAssertNotEqual(keyBytes(PairingSecret.encryptionKey(from: secretA)), keyBytes(PairingSecret.encryptionKey(from: secretB)))
    }

    private func keyBytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}
