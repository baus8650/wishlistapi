import Vapor

/// Small, deliberately conservative first-line protection for user-entered text.
/// Reports and moderator review remain the source of truth for anything uncertain.
enum ContentSafetyService {
    private static let blockedPhrases = [
        "child sexual abuse", "child porn", "csam", "exploit children",
        "kill yourself", "i will kill", "i'm going to kill", "bomb threat"
    ]

    static func validate(_ text: String, field: String) throws {
        let normalized = text.lowercased()
        guard !blockedPhrases.contains(where: { normalized.contains($0) }) else {
            throw Abort(.badRequest, reason: "This \(field) cannot be posted because it violates Hushful's safety standards.")
        }
    }
}
