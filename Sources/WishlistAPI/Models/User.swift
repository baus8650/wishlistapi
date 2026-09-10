import Fluent
import Vapor

final class User: Model {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "email")
    var email: String

    @Field(key: "password_hash")
    var passwordHash: String

    /// Password-created accounts must confirm control of their inbox before
    /// they can receive an access token. OAuth providers with a verified email
    /// set this at account creation.
    @OptionalField(key: "email_verified_at")
    var emailVerifiedAt: Date?

    @OptionalField(key: "display_name")
    var displayName: String?

    @OptionalField(key: "display_name_search")
    var displayNameSearch: String?

    @OptionalField(key: "username")
    var username: String?

    @Field(key: "is_discoverable")
    var isDiscoverable: Bool

    @Field(key: "friend_request_policy")
    var friendRequestPolicy: String

    @OptionalField(key: "privacy_setup_completed")
    var privacySetupCompleted: Bool?

    /// Versioned onboarding completion lets every client agree on whether the
    /// current account has seen the latest first-run experience.
    @OptionalField(key: "onboarding_version")
    var onboardingVersion: Int?

    /// Derived age band retained for compatibility with existing clients and
    /// records. Safety decisions use `derivedAgeBand`, calculated from the
    /// private birthday below.
    @Field(key: "age_band")
    var ageBand: String

    /// Explicit opt-in for profiles that may contain adult-oriented content.
    /// Only adult accounts may enable this setting.
    @Field(key: "mature_profile_enabled")
    var matureProfileEnabled: Bool

    /// Adult accounts can choose whether adult-only lists appear in shared-list
    /// collections. This is a display preference, not an access permission.
    @Field(key: "show_age_restricted_lists")
    var showAgeRestrictedLists: Bool

    /// Birthdays are private by default. The year is used only on the server to
    /// derive the account's age band and is never returned for another user.
    @OptionalField(key: "birthday_month")
    var birthdayMonth: Int?

    @OptionalField(key: "birthday_day")
    var birthdayDay: Int?

    @OptionalField(key: "birthday_year")
    var birthdayYear: Int?

    @Field(key: "birthday_visibility")
    var birthdayVisibility: String

    @Field(key: "birthday_setup_completed")
    var birthdaySetupCompleted: Bool

    @OptionalField(key: "avatar_data")
    var avatarData: Data?

    @OptionalField(key: "avatar_content_type")
    var avatarContentType: String?

    @Field(key: "has_lifetime_pro")
    var hasLifetimePro: Bool

    /// Incremented when all existing sessions must be invalidated.
    @Field(key: "authentication_version")
    var authenticationVersion: Int

    @OptionalField(key: "terms_accepted_at") var termsAcceptedAt: Date?
    @OptionalField(key: "terms_version") var termsVersion: String?
    @OptionalField(key: "suspended_at") var suspendedAt: Date?

    @Field(key: "role") var role: String
    @OptionalField(key: "admin_totp_secret") var adminTOTPSecret: String?
    @Field(key: "admin_totp_enabled") var adminTOTPEnabled: Bool
    @OptionalField(key: "admin_recovery_codes") var adminRecoveryCodes: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, email: String, passwordHash: String, displayName: String? = nil) {
        self.id = id
        self.email = email
        self.passwordHash = passwordHash
        self.displayName = displayName
        self.displayNameSearch = displayName?.lowercased()
        self.isDiscoverable = false
        self.friendRequestPolicy = "everyone"
        self.privacySetupCompleted = false
        self.ageBand = "unknown"
        self.matureProfileEnabled = false
        self.showAgeRestrictedLists = false
        self.birthdayVisibility = "private"
        self.birthdaySetupCompleted = false
        self.hasLifetimePro = false
        self.authenticationVersion = 0
        self.role = "user"
        self.adminTOTPEnabled = false
    }

    var derivedAgeBand: String {
        guard let year = birthdayYear, let month = birthdayMonth, let day = birthdayDay else { return "unknown" }
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.dateComponents([.year, .month, .day], from: Date())
        guard let currentYear = today.year, let currentMonth = today.month, let currentDay = today.day else { return "unknown" }
        var age = currentYear - year
        if (currentMonth, currentDay) < (month, day) { age -= 1 }
        return age >= 18 ? "adult" : "under_18"
    }

    var isAgeRestrictedProfile: Bool { matureProfileEnabled && derivedAgeBand == "adult" }
    var canShowAgeRestrictedLists: Bool { derivedAgeBand == "adult" && showAgeRestrictedLists }
    var isSuspended: Bool { suspendedAt != nil }
}

extension User {
    /// Safe-to-return representation of a user (never includes passwordHash).
    struct Public: Content {
        let id: UUID?
        let email: String
        let displayName: String?
        let username: String?
        let isDiscoverable: Bool
        let friendRequestPolicy: String
        let privacySetupCompleted: Bool
        let onboardingVersion: Int?
        let ageBand: String
        let matureProfileEnabled: Bool
        let showAgeRestrictedLists: Bool
        let birthdayMonth: Int?
        let birthdayDay: Int?
        let birthdayVisibility: String
        let birthdaySetupCompleted: Bool
        let hasAvatar: Bool
        let isPro: Bool
        let createdAt: Date?
        let updatedAt: Date?
    }

    func toPublic() -> Public {
        .init(
            id: self.id,
            email: self.email,
            displayName: self.displayName,
            username: self.username,
            isDiscoverable: self.isDiscoverable,
            friendRequestPolicy: self.friendRequestPolicy,
            privacySetupCompleted: self.privacySetupCompleted ?? true,
            onboardingVersion: self.onboardingVersion,
            ageBand: self.derivedAgeBand,
            matureProfileEnabled: self.isAgeRestrictedProfile,
            showAgeRestrictedLists: self.canShowAgeRestrictedLists,
            birthdayMonth: self.birthdayMonth,
            birthdayDay: self.birthdayDay,
            birthdayVisibility: self.birthdayVisibility,
            birthdaySetupCompleted: self.birthdayYear != nil && self.birthdayMonth != nil && self.birthdayDay != nil,
            hasAvatar: self.avatarData != nil,
            isPro: self.hasLifetimePro,
            createdAt: self.createdAt,
            updatedAt: self.updatedAt
        )
    }
}

extension User: Authenticatable {}

// Fluent `Model` types are reference types with mutable properties, so they can't be safely
// verified as `Sendable` by the compiler. Vapor/Fluent commonly treats these as safe to pass
// around in request-handling contexts.
extension User: @unchecked Sendable {}
