import XCTest
@testable import Xuyu

/// 和电脑中继有关的安全检查：对暗号、收到的文件名、发出去的位置（审查第一批）
final class RelayPairingTests: XCTestCase {
    // MARK: - 对暗号

    /// 和 relay/src/selftest.js 用同一组数：两边算出来不一样，手机就永远连不上中继
    func testProofMatchesRelay() throws {
        let key = try XCTUnwrap(RelayPairing.key(for: "abcd2345 "))
        let nonce = String(repeating: "00", count: 16)
        let cnonce = String(repeating: "11", count: 16)
        XCTAssertEqual(RelayPairing.proof(key: key, role: "app", nonce: nonce, cnonce: cnonce),
                       "99aa92a17df70e1b31f2051f2d0aae379bd891c939b2a0a1f577f55d1ba464e0")
        XCTAssertEqual(RelayPairing.proof(key: key, role: "relay", nonce: nonce, cnonce: cnonce),
                       "c35829f110732cd591d915b90bef7108703b837932bb9e7c4c9e40ed302c6942")
    }

    func testNonceIsFreshAndValid() {
        let a = RelayPairing.newNonce()
        XCTAssertTrue(RelayPairing.validNonce(a))
        XCTAssertNotEqual(a, RelayPairing.newNonce())
        XCTAssertFalse(RelayPairing.validNonce("abc"))
        XCTAssertFalse(RelayPairing.validNonce(String(repeating: "G", count: 32)))
    }

    func testSameComparesWholeString() {
        XCTAssertTrue(RelayPairing.same("abc123", "abc123"))
        XCTAssertFalse(RelayPairing.same("abc123", "abc124"))
        XCTAssertFalse(RelayPairing.same("abc", "abc123"))
    }

    // MARK: - 收到的文件名

    func testFileNameDropsPaths() {
        XCTAssertEqual(FileName.safe("../../Library/Application Support/default.store"), "default.store")
        XCTAssertEqual(FileName.safe("..\\..\\x.txt"), "x.txt")
        XCTAssertEqual(FileName.safe(".hidden"), "hidden")
        XCTAssertEqual(FileName.safe("报告:v2.pdf"), "报告v2.pdf")
        XCTAssertEqual(FileName.safe("a\u{0}b.txt"), "ab.txt")
        XCTAssertEqual(FileName.safe("..").isEmpty, false)
        XCTAssertFalse(FileName.safe("../").contains("."))
    }

    func testNormalFileNameUnchanged() {
        XCTAssertEqual(FileName.safe("周报 10月.docx"), "周报 10月.docx")
    }

    // MARK: - 天气只发大概位置

    func testWeatherSendsCoarseLocation() {
        XCTAssertEqual(Weather.coarse(31.230416), "31.2")
        XCTAssertEqual(Weather.coarse(-121.473701), "-121.5")
    }
}
