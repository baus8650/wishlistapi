@testable import WishlistAPI
import Foundation
import JWTKit
import Testing

@Suite("Sign in with Apple validation")
struct AppleSignInValidationTests {
    @Test("A verified private relay address is normalized for account lookup")
    func normalizesVerifiedPrivateRelayAddress() {
        let profile = appleIdentity(email: "  Person@privaterelay.appleid.com ", emailVerified: true)

        #expect(
            AppleSignInValidation.verifiedEmail(from: profile)
                == "person@privaterelay.appleid.com"
        )
    }

    @Test("An email-less or unverified Apple profile cannot create a new account")
    func rejectsUnavailableOrUnverifiedEmail() {
        #expect(AppleSignInValidation.verifiedEmail(from: appleIdentity(email: nil, emailVerified: true)) == nil)
        #expect(AppleSignInValidation.verifiedEmail(from: appleIdentity(email: "person@example.com", emailVerified: false)) == nil)
    }

    @Test("Only the exact, server-sized nonce may be accepted")
    func verifiesExactNonce() {
        let nonce = String(repeating: "a", count: 43)

        #expect(AppleSignInValidation.matchesTokenNonce(nonce, tokenNonce: nonce))
        #expect(!AppleSignInValidation.matchesTokenNonce(nonce, tokenNonce: "different"))
        #expect(!AppleSignInValidation.matchesTokenNonce("short", tokenNonce: "short"))
    }

    private func appleIdentity(email: String?, emailVerified: Bool) -> AppleIdentityToken {
        AppleIdentityToken(
            issuer: .init(value: "https://appleid.apple.com"),
            audience: .init(value: ["com.bausch.hushful"]),
            expires: .init(value: Date().addingTimeInterval(300)),
            issuedAt: .init(value: Date()),
            subject: .init(value: "001234.abcdef"),
            email: email,
            emailVerified: .init(value: emailVerified)
        )
    }
}
