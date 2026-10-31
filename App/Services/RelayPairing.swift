import Foundation
import CryptoKit
import CommonCrypto

/// 手机和电脑中继互相「对暗号」：配对码不在网上传，双方各出一个随机数，用配对码算出证明交给对方核对。
/// 中继先发 hello（带随机数）→ 手机回 auth（自己的随机数 + 手机的证明）→ 中继回 welcome（中继的证明）→ 手机核对通过才发内容。
/// 偷听的人拿不到配对码；冒充中继的设备算不出证明，聊天和备份不会发给它（审查 Z-004、Z-038）。
/// 算法和 relay/src/pairing.js 一一对应，改了要两边一起改（规范 RELAY-2）
enum RelayPairing {
    /// 拉伸配对码用的盐和轮数：偷听到一次对暗号的人想离线一个个试配对码，每试一次都要算这么多轮
    static let salt = "xuyu-relay-pair-v2"
    static let rounds: UInt32 = 100_000

    /// 把配对码拉伸成钥匙。要算几十毫秒，在后台调用
    static func key(for code: String) -> SymmetricKey? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let saltBytes = Array(salt.utf8)
        let length = 32
        var derived = [UInt8](repeating: 0, count: length)
        let status = normalized.withCString { password in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, strlen(password),
                                 saltBytes, saltBytes.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                 &derived, length)
        }
        guard Int(status) == kCCSuccess else { return nil }
        return SymmetricKey(data: derived)
    }

    /// 一方的证明：role 是 "app" 或 "relay"；两边的随机数都算进去，旧的证明不能拿来重放
    static func proof(key: SymmetricKey, role: String, nonce: String, cnonce: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(role)|\(nonce)|\(cnonce)".utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// 16 字节的随机数，写成十六进制
    static func newNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    /// 合格的随机数：16～64 字节的十六进制（和中继的要求一样）
    static func validNonce(_ s: String) -> Bool {
        (32...128).contains(s.count) && s.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// 比较两个证明：不管哪一位不同都比完全部，不让人从快慢猜出前几位对不对
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
