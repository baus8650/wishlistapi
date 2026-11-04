import Foundation

/// Validate one emoji grapheme, including skin tones, flags, keycaps, and ZWJ sequences.
enum ReactionEmoji {
    static let defaults = ["👍", "❤️", "😂", "🎉", "😮", "🙏"]

    static func isValid(_ value: String) -> Bool {
        guard value.count == 1, value.utf8.count <= 128,
              let first = value.unicodeScalars.first,
              first.properties.isEmoji, !first.properties.isEmojiModifier else { return false }
        let scalars = Array(value.unicodeScalars)
        if first.isASCII {
            let codes = scalars.map(\.value)
            return codes == [first.value, 0x20E3] || codes == [first.value, 0xFE0F, 0x20E3]
        }
        if (0x1F1E6...0x1F1FF).contains(first.value) {
            return scalars.count == 2 && scalars.allSatisfy { (0x1F1E6...0x1F1FF).contains($0.value) }
        }
        return scalars.allSatisfy {
            $0.properties.isEmoji || $0.value == 0xFE0F || $0.value == 0x200D ||
            (0xE0020...0xE007F).contains($0.value)
        }
    }

    static func remembering(_ emoji: String, in recent: [String]) -> [String] {
        guard isValid(emoji) else { return recent }
        return Array(([emoji] + recent.filter { $0 != emoji && isValid($0) }).prefix(20))
    }

    static func suggestions(recent: [String]) -> [String] {
        var result: [String] = []
        for emoji in recent + defaults where isValid(emoji) && !result.contains(emoji) {
            result.append(emoji)
        }
        return Array(result.prefix(8))
    }
}
