import Foundation
import CommonCrypto
import CryptoKit

/// The recorder's HBNVR-PBE v1 envelope. It is not the AWS Encryption Client
/// format. Call from the reader actor, never from the UI executor: the fixed
/// PBKDF2 work factor intentionally makes guessing a password expensive.
nonisolated enum CameraS3Decryption {
    static let magic = Data("HBNVRE01".utf8)
    static let rounds: UInt32 = 600_000
    static let headerSize = 56

    enum Failure: Error, LocalizedError, Equatable {
        case passwordRequired, invalidPassword, invalidEnvelope, authenticationFailed
        var errorDescription: String? {
            switch self {
            case .passwordRequired: "This recording needs its encryption password. Update S3 Access."
            case .invalidPassword: "The encryption password must contain 1–1024 UTF-8 bytes without NUL or newline characters."
            case .invalidEnvelope: "This is not a supported encrypted recording."
            case .authenticationFailed: "Cannot decrypt this recording: incorrect password or damaged data."
            }
        }
    }

    static func decrypt(_ data: Data, password: String?) throws -> Data {
        // Plain recordings and plaintext manifests are valid. Their callers
        // still validate container/schema and any advertised content hash.
        guard data.prefix(magic.count) == magic else { return data }
        guard data.count >= headerSize + 16 else { throw Failure.invalidEnvelope }
        let envelope = Data(data) // Rebase Data slices before integer indexing.
        let iterations = envelope[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard iterations == rounds else { throw Failure.invalidEnvelope }
        guard let password else { throw Failure.passwordRequired }
        let header = envelope.prefix(headerSize)
        let key = try deriveKey(password: password, salt: envelope.subdata(in: 12..<44), rounds: rounds)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: envelope.subdata(in: 44..<56)),
                ciphertext: envelope.subdata(in: headerSize..<(envelope.count - 16)), tag: envelope.suffix(16))
            return try AES.GCM.open(box, using: key, authenticating: header)
        } catch { throw Failure.authenticationFailed }
    }

    /// Internal for published PBKDF2 known-answer tests; decrypt accepts only
    /// the fixed v1 parameters, not a work factor supplied by untrusted data.
    static func deriveKey(password: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        guard (1...1024).contains(password.utf8.count),
              !password.utf8.contains(0), !password.contains("\n"), !password.contains("\r") else {
            throw Failure.invalidPassword
        }
        guard !salt.isEmpty, rounds > 0 else { throw Failure.invalidEnvelope }
        var bytes = [UInt8](repeating: 0, count: 32)
        defer { _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let result = password.withCString { characters in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), characters, password.utf8.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &bytes, bytes.count)
            }
        }
        guard result == kCCSuccess else { throw Failure.authenticationFailed }
        return SymmetricKey(data: bytes)
    }
}
