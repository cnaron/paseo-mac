import Foundation
import Clibsodium

/// Thin wrappers around libsodium to match the tweetnacl primitives used by
/// Paseo's relay E2EE layer.
///
/// Wire-compatible with `packages/relay/src/crypto.ts`:
///   - Curve25519 key agreement via `crypto_box_beforenm` → 32-byte shared key
///   - XSalsa20-Poly1305 encryption via `crypto_secretbox_easy` with a 24-byte random nonce
///   - Bundle format: `[nonce (24 bytes)][ciphertext with 16-byte Poly1305 tag prefix]`
///
/// `Sodium` initializes libsodium lazily; we keep a single shared instance.
enum RelayCrypto {

    static let publicKeyLength = 32
    static let secretKeyLength = 32
    static let sharedKeyLength = 32
    static let nonceLength = 24
    static let macLength = 16

    private static let initLock = NSLock()
    private nonisolated(unsafe) static var initialized = false

    private static func ensureInitialized() {
        initLock.lock()
        defer { initLock.unlock() }
        if !initialized {
            // `sodium_init()` is idempotent and thread-safe after first call.
            // It returns 0 on success, 1 if already initialized, -1 on failure.
            let rc = sodium_init()
            precondition(rc >= 0, "libsodium failed to initialize (rc=\(rc))")
            initialized = true
        }
    }

    // MARK: Keypair

    struct KeyPair: Sendable, Hashable {
        let publicKey: Data   // 32 bytes
        let secretKey: Data   // 32 bytes
    }

    static func generateKeyPair() throws -> KeyPair {
        ensureInitialized()
        var pk = Data(count: publicKeyLength)
        var sk = Data(count: secretKeyLength)
        let rc = pk.withUnsafeMutableBytes { pkPtr -> Int32 in
            sk.withUnsafeMutableBytes { skPtr in
                crypto_box_keypair(
                    pkPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    skPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                )
            }
        }
        guard rc == 0 else { throw RelayCryptoError.primitiveFailed("crypto_box_keypair") }
        return KeyPair(publicKey: pk, secretKey: sk)
    }

    // MARK: Shared key

    /// Equivalent of `nacl.box.before(peerPublicKey, ourSecretKey)`.
    /// Produces a 32-byte precomputed key usable with `crypto_secretbox_easy`.
    static func deriveSharedKey(ourSecretKey: Data, peerPublicKey: Data) throws -> Data {
        ensureInitialized()
        try ensureLength(ourSecretKey, secretKeyLength, label: "secret key")
        try ensureLength(peerPublicKey, publicKeyLength, label: "peer public key")

        var shared = Data(count: sharedKeyLength)
        let rc = shared.withUnsafeMutableBytes { sharedPtr -> Int32 in
            peerPublicKey.withUnsafeBytes { pkPtr in
                ourSecretKey.withUnsafeBytes { skPtr in
                    crypto_box_beforenm(
                        sharedPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        pkPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        skPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    )
                }
            }
        }
        guard rc == 0 else { throw RelayCryptoError.primitiveFailed("crypto_box_beforenm") }
        return shared
    }

    // MARK: Encrypt / Decrypt

    /// Encrypts `plaintext` under `sharedKey` and returns `[nonce (24)][mac+ciphertext]`.
    static func encrypt(sharedKey: Data, plaintext: Data) throws -> Data {
        ensureInitialized()
        try ensureLength(sharedKey, sharedKeyLength, label: "shared key")

        var nonce = Data(count: nonceLength)
        nonce.withUnsafeMutableBytes { randombytes_buf($0.baseAddress!, nonceLength) }

        var ciphertext = Data(count: plaintext.count + macLength)
        let rc = ciphertext.withUnsafeMutableBytes { ctPtr -> Int32 in
            plaintext.withUnsafeBytes { ptPtr in
                nonce.withUnsafeBytes { noncePtr in
                    sharedKey.withUnsafeBytes { keyPtr in
                        crypto_secretbox_easy(
                            ctPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            ptPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            UInt64(plaintext.count),
                            noncePtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            keyPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        )
                    }
                }
            }
        }
        guard rc == 0 else { throw RelayCryptoError.primitiveFailed("crypto_secretbox_easy") }

        var bundle = Data(capacity: nonceLength + ciphertext.count)
        bundle.append(nonce)
        bundle.append(ciphertext)
        return bundle
    }

    /// Decrypts a `[nonce][mac+ciphertext]` bundle. Throws if the MAC fails.
    static func decrypt(sharedKey: Data, bundle: Data) throws -> Data {
        ensureInitialized()
        try ensureLength(sharedKey, sharedKeyLength, label: "shared key")
        guard bundle.count >= nonceLength + macLength else {
            throw RelayCryptoError.bundleTooShort
        }

        let nonce = bundle.prefix(nonceLength)
        let ciphertext = bundle.suffix(from: nonceLength)

        var plaintext = Data(count: ciphertext.count - macLength)
        let rc = plaintext.withUnsafeMutableBytes { ptPtr -> Int32 in
            ciphertext.withUnsafeBytes { ctPtr in
                nonce.withUnsafeBytes { noncePtr in
                    sharedKey.withUnsafeBytes { keyPtr in
                        crypto_secretbox_open_easy(
                            ptPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            ctPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            UInt64(ciphertext.count),
                            noncePtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            keyPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        )
                    }
                }
            }
        }
        guard rc == 0 else { throw RelayCryptoError.decryptFailed }
        return plaintext
    }

    // MARK: - Helpers

    private static func ensureLength(_ data: Data, _ expected: Int, label: String) throws {
        guard data.count == expected else {
            throw RelayCryptoError.invalidLength(label: label, expected: expected, actual: data.count)
        }
    }
}

enum RelayCryptoError: Error, LocalizedError {
    case primitiveFailed(String)
    case invalidLength(label: String, expected: Int, actual: Int)
    case bundleTooShort
    case decryptFailed

    var errorDescription: String? {
        switch self {
        case .primitiveFailed(let name): "libsodium \(name) failed"
        case .invalidLength(let label, let e, let a): "Invalid \(label) length: expected \(e), got \(a)"
        case .bundleTooShort: "Ciphertext bundle too short"
        case .decryptFailed: "Decryption failed (bad key or tampered ciphertext)"
        }
    }
}
