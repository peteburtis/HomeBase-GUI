import XCTest
import CryptoKit
@testable import HomeBase_GUI

final class CameraS3DecryptionTests: XCTestCase {
    // Independent OpenSSL (Node crypto) known answer also used by HBNVR's
    // writer tests. Salt 0...31, nonce 32...43, full 56-byte header as AAD.
    private let fixture = Data(base64Encoded: "SEJOVlJFMDEACSfAAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKisoturA7Czgie/kJ6LijBNu0L0hoXq28bZ3U0WDyuMJptqSwL4BlKlsNw9494LK8g==")!

    func testPBKDF2SHA256KnownAnswer() throws {
        let key = try CameraS3Decryption.deriveKey(password: "password", salt: Data("salt".utf8), rounds: 1)
        XCTAssertEqual(key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() },
            "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    }
    func testIndependentEnvelopeAndPlaintext() throws {
        XCTAssertEqual(try CameraS3Decryption.decrypt(fixture, password: "independent test password"),
            Data("independent synthetic recording".utf8))
        let plain = Data("{\"version\":1}".utf8)
        XCTAssertEqual(try CameraS3Decryption.decrypt(plain, password: nil), plain)
        XCTAssertEqual(try CameraS3Decryption.decrypt(Data(), password: nil), Data())
    }
    func testMissingPasswordWrongPasswordAndTampering() throws {
        XCTAssertThrowsError(try CameraS3Decryption.decrypt(fixture, password: nil)) {
            XCTAssertEqual($0 as? CameraS3Decryption.Failure, .passwordRequired)
        }
        XCTAssertThrowsError(try CameraS3Decryption.decrypt(fixture, password: "wrong")) {
            XCTAssertEqual($0 as? CameraS3Decryption.Failure, .authenticationFailed)
        }
        for offset in [12, 44, 56, fixture.count - 1] {
            var tampered = fixture; tampered[offset] ^= 1
            XCTAssertThrowsError(try CameraS3Decryption.decrypt(tampered, password: "independent test password"))
        }
        var extra = fixture; extra.append(0)
        XCTAssertThrowsError(try CameraS3Decryption.decrypt(extra, password: "independent test password"))
    }
    func testUnsupportedWorkFactorAndTruncationFailBeforeKeyDerivation() throws {
        var expensive = fixture
        expensive.replaceSubrange(8..<12, with: [255, 255, 255, 255])
        XCTAssertThrowsError(try CameraS3Decryption.decrypt(expensive, password: nil)) {
            XCTAssertEqual($0 as? CameraS3Decryption.Failure, .invalidEnvelope)
        }
        for length in [8, 55, 56, 71] {
            XCTAssertThrowsError(try CameraS3Decryption.decrypt(Data(fixture.prefix(length)), password: nil)) {
                XCTAssertEqual($0 as? CameraS3Decryption.Failure, .invalidEnvelope)
            }
        }
    }
    func testPasswordPreservesExactUTF8AndHasSafeBounds() throws {
        for password in ["", "a\0b", "a\nb", "a\rb", String(repeating: "é", count: 513)] {
            XCTAssertThrowsError(try CameraS3Decryption.deriveKey(password: password, salt: Data([1]), rounds: 1))
        }
        XCTAssertNoThrow(try CameraS3Decryption.deriveKey(password: String(repeating: "é", count: 512), salt: Data([1]), rounds: 1))
        let derive: (String) throws -> Data = { value in
            let key = try CameraS3Decryption.deriveKey(password: value, salt: Data([1]), rounds: 1)
            return key.withUnsafeBytes { Data($0) }
        }
        XCTAssertNotEqual(try derive(" spaces "), try derive("spaces"))
        XCTAssertNotEqual(try derive("caf\u{e9}"), try derive("cafe\u{301}"))
    }
    func testDataSliceIsRebased() throws {
        var prefixed = Data([0, 1, 2]); prefixed.append(fixture)
        XCTAssertEqual(try CameraS3Decryption.decrypt(prefixed.dropFirst(3), password: "independent test password"),
            Data("independent synthetic recording".utf8))
    }
}
