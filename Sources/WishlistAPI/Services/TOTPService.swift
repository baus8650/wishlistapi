import Foundation
import Vapor

/// RFC 6238-compatible TOTP implementation using only the standard library.
enum TOTPService {
    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    private static let recoveryAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func generateSecret() -> String { base32Encode(randomBytes(count: 20)) }

    static func generateRecoveryCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<10).map { _ in recoveryAlphabet.randomElement(using: &generator)! })
    }

    static func provisioningURI(secret: String, account: String) -> String {
        let issuer = "Hushful"
        let encodedIssuer = issuer.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? issuer
        let encodedAccount = account.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? account
        let encodedQueryIssuer = issuer.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? issuer
        return "otpauth://totp/\(encodedIssuer):\(encodedAccount)?secret=\(secret)&issuer=\(encodedQueryIssuer)&algorithm=SHA1&digits=6&period=30"
    }

    static func isValid(code: String, secret: String, now: Date = Date()) -> Bool {
        let normalizedCode = code.filter(\.isNumber)
        guard normalizedCode.count == 6, let secretBytes = base32Decode(secret) else { return false }
        let counter = Int64(floor(now.timeIntervalSince1970 / 30))
        return (-1...1).contains { offset in
            hotp(secret: secretBytes, counter: UInt64(counter + Int64(offset))) == normalizedCode
        }
    }

    static func hashedRecoveryCodes(_ codes: [String]) throws -> String {
        let hashes = try codes.map { try Bcrypt.hash($0) }
        return String(data: try JSONEncoder().encode(hashes), encoding: .utf8)!
    }

    /// Recovery codes are one-time codes. A successful match removes the code
    /// from the stored JSON; callers should save the user immediately.
    static func consumeRecoveryCode(_ code: String, from user: User) -> Bool {
        guard let stored = user.adminRecoveryCodes,
              let data = stored.data(using: .utf8),
              var hashes = try? JSONDecoder().decode([String].self, from: data)
        else { return false }
        guard let index = hashes.firstIndex(where: { (try? Bcrypt.verify(code, created: $0)) == true }) else { return false }
        hashes.remove(at: index)
        user.adminRecoveryCodes = try? String(data: JSONEncoder().encode(hashes), encoding: .utf8)
        return true
    }

    private static func randomBytes(count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    private static func hotp(secret: [UInt8], counter: UInt64) -> String {
        let counterBytes = (0..<8).reversed().map { UInt8((counter >> (UInt64($0) * 8)) & 0xff) }
        let digest = hmacSHA1(key: secret, message: Array(counterBytes))
        let offset = Int(digest.last! & 0x0f)
        let value = (UInt32(digest[offset]) & 0x7f) << 24
            | UInt32(digest[offset + 1]) << 16
            | UInt32(digest[offset + 2]) << 8
            | UInt32(digest[offset + 3])
        return String(format: "%06u", value % 1_000_000)
    }

    private static func base32Encode(_ bytes: [UInt8]) -> String {
        var output = "", buffer = 0, bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte); bits += 8
            while bits >= 5 { bits -= 5; output.append(base32Alphabet[(buffer >> bits) & 31]) }
        }
        if bits > 0 { output.append(base32Alphabet[(buffer << (5 - bits)) & 31]) }
        return output
    }

    private static func base32Decode(_ value: String) -> [UInt8]? {
        var buffer = 0, bits = 0, output: [UInt8] = []
        for character in value.uppercased() where character != "=" && !character.isWhitespace {
            guard let index = base32Alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | index; bits += 5
            if bits >= 8 { bits -= 8; output.append(UInt8((buffer >> bits) & 0xff)) }
        }
        return output.isEmpty ? nil : output
    }

    private static func hmacSHA1(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var key = key
        if key.count > 64 { key = sha1(key) }
        key += Array(repeating: 0, count: 64 - key.count)
        let inner = sha1(zip(key, Array(repeating: UInt8(0x36), count: 64)).map { $0 ^ $1 } + message)
        return sha1(zip(key, Array(repeating: UInt8(0x5c), count: 64)).map { $0 ^ $1 } + inner)
    }

    private static func sha1(_ input: [UInt8]) -> [UInt8] {
        var message = input
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        message += (0..<8).reversed().map { UInt8((bitLength >> (UInt64($0) * 8)) & 0xff) }

        var h0: UInt32 = 0x67452301, h1: UInt32 = 0xefcdab89, h2: UInt32 = 0x98badcfe
        var h3: UInt32 = 0x10325476, h4: UInt32 = 0xc3d2e1f0
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            let chunk = Array(message[chunkStart..<(chunkStart + 64)])
            var words = Array(repeating: UInt32(0), count: 80)
            for index in 0..<16 {
                let start = index * 4
                words[index] = UInt32(chunk[start]) << 24 | UInt32(chunk[start + 1]) << 16 | UInt32(chunk[start + 2]) << 8 | UInt32(chunk[start + 3])
            }
            for index in 16..<80 { words[index] = (words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16]).rotatedLeft(by: 1) }
            var a = h0, b = h1, c = h2, d = h3, e = h4
            for index in 0..<80 {
                let function: UInt32, constant: UInt32
                switch index {
                case 0..<20: (function, constant) = ((b & c) | ((~b) & d), 0x5a827999)
                case 20..<40: (function, constant) = (b ^ c ^ d, 0x6ed9eba1)
                case 40..<60: (function, constant) = ((b & c) | (b & d) | (c & d), 0x8f1bbcdc)
                default: (function, constant) = (b ^ c ^ d, 0xca62c1d6)
                }
                let temp = a.rotatedLeft(by: 5) &+ function &+ e &+ constant &+ words[index]
                e = d; d = c; c = b.rotatedLeft(by: 30); b = a; a = temp
            }
            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
        }
        return [h0, h1, h2, h3, h4].flatMap { value in [UInt8(value >> 24), UInt8(value >> 16), UInt8(value >> 8), UInt8(value)] }
    }
}

private extension UInt32 {
    func rotatedLeft(by amount: UInt32) -> UInt32 { (self << amount) | (self >> (32 - amount)) }
}
