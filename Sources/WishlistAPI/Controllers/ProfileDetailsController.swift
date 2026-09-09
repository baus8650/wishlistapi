import Fluent
import Vapor

struct ProfileDetailsDTO: Content {
    let matureProfileEnabled: Bool
    let birthdayMonth: Int?
    let birthdayDay: Int?
    let birthdayYear: Int?
    let birthdayVisibility: String
    let birthdaySetupCompleted: Bool
    let attributes: [ProfileAttributeDTO]
}

struct UpdateProfileDetailsRequest: Content {
    let matureProfileEnabled: Bool?
    let birthdayMonth: Int?
    let birthdayDay: Int?
    let birthdayYear: Int?
    let birthdayVisibility: String?
    let clearBirthday: Bool?
    let birthdaySetupCompleted: Bool?
}

struct UpsertProfileAttributeRequest: Content {
    let label: String
    let value: String
    let visibility: String
}

struct BirthdayAlertDTO: Content {
    let enabled: Bool
    let reminderDaysBefore: Int
}

struct BirthdayAlertSubscriptionDTO: Content {
    let userID: UUID
    let displayName: String
    let birthdayMonth: Int
    let birthdayDay: Int
    let reminderDaysBefore: Int
}

struct UpdateBirthdayAlertRequest: Content {
    let enabled: Bool
    let reminderDaysBefore: Int?
}

struct ProfileDetailsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("me", "profile-details", use: details)
        routes.patch("me", "profile-details", use: updateDetails)
        routes.post("me", "profile-attributes", use: createAttribute)
        routes.put("me", "profile-attributes", ":attributeID", use: updateAttribute)
        routes.delete("me", "profile-attributes", ":attributeID", use: deleteAttribute)
        routes.get("users", ":userID", "birthday-alert", use: birthdayAlert)
        routes.put("users", ":userID", "birthday-alert", use: updateBirthdayAlert)
        routes.get("me", "birthday-alerts", use: birthdayAlerts)
    }

    func details(req: Request) async throws -> ProfileDetailsDTO {
        let userID = try req.auth.require(User.self).requireID()
        return try await details(for: userID, on: req.db)
    }

    func updateDetails(req: Request) async throws -> ProfileDetailsDTO {
        let user = try req.auth.require(User.self)
        let body = try req.content.decode(UpdateProfileDetailsRequest.self)

        if let visibility = body.birthdayVisibility {
            guard Self.validVisibility(visibility) else { throw Abort(.badRequest, reason: "Invalid birthday visibility.") }
            user.birthdayVisibility = visibility
        }

        if body.clearBirthday == true {
            user.birthdayMonth = nil
            user.birthdayDay = nil
            user.birthdayYear = nil
            user.birthdaySetupCompleted = false
            try await BirthdayAlert.query(on: req.db).filter(\.$subject.$id == user.requireID()).delete()
        } else if body.birthdayMonth != nil || body.birthdayDay != nil || body.birthdayYear != nil {
            guard let year = body.birthdayYear, let month = body.birthdayMonth, let day = body.birthdayDay,
                  Self.validDate(year: year, month: month, day: day) else {
                throw Abort(.badRequest, reason: "Choose a valid birthday including the year.")
            }
            guard Self.age(year: year, month: month, day: day) >= 13 else {
                throw Abort(.forbidden, reason: "Hushful accounts are available to people age 13 and older.")
            }
            user.birthdayYear = year
            user.birthdayMonth = month
            user.birthdayDay = day
        }

        if body.birthdayMonth != nil || body.birthdayDay != nil || body.birthdayYear != nil {
            user.birthdaySetupCompleted = true
        }

        user.ageBand = user.derivedAgeBand
        if let matureProfileEnabled = body.matureProfileEnabled {
            if matureProfileEnabled && user.derivedAgeBand != "adult" {
                throw Abort(.badRequest, reason: "Only adult accounts can limit a profile to adult viewers.")
            }
            user.matureProfileEnabled = matureProfileEnabled
        }
        if user.derivedAgeBand != "adult" {
            user.matureProfileEnabled = false
            user.showAgeRestrictedLists = false
        }

        if user.birthdayVisibility == "private" {
            try await BirthdayAlert.query(on: req.db).filter(\.$subject.$id == user.requireID()).delete()
        }
        try await user.save(on: req.db)
        if body.matureProfileEnabled != nil || body.birthdayYear != nil || body.birthdayMonth != nil || body.birthdayDay != nil {
            for wishlist in try await Wishlist.query(on: req.db).filter(\.$owner.$id == user.requireID()).all() {
                try await AudienceService.sync(wishlistID: wishlist.requireID(), on: req.db)
                try await ProfileAccessService.revokeIneligibleWishlistAccess(wishlistID: wishlist.requireID(), on: req.db)
            }
        }
        return try await details(for: user.requireID(), on: req.db)
    }

    func createAttribute(req: Request) async throws -> ProfileAttributeDTO {
        let userID = try req.auth.require(User.self).requireID()
        let body = try req.content.decode(UpsertProfileAttributeRequest.self)
        let clean = try Self.validatedAttribute(body)
        guard try await UserProfileAttribute.query(on: req.db).filter(\.$user.$id == userID).count() < 50 else {
            throw Abort(.badRequest, reason: "You can add up to 50 profile attributes.")
        }
        guard try await UserProfileAttribute.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$labelSearch == clean.label.lowercased())
            .first() == nil else {
            throw Abort(.conflict, reason: "You already have an attribute with that name.")
        }
        let attribute = UserProfileAttribute(userID: userID, label: clean.label, value: clean.value, visibility: clean.visibility)
        try await attribute.save(on: req.db)
        return attribute.dto()
    }

    func updateAttribute(req: Request) async throws -> ProfileAttributeDTO {
        let userID = try req.auth.require(User.self).requireID()
        guard let attributeID = req.parameters.get("attributeID", as: UUID.self),
              let attribute = try await UserProfileAttribute.query(on: req.db)
                .filter(\.$id == attributeID)
                .filter(\.$user.$id == userID)
                .first() else { throw Abort(.notFound) }
        let body = try req.content.decode(UpsertProfileAttributeRequest.self)
        let clean = try Self.validatedAttribute(body)
        guard try await UserProfileAttribute.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$labelSearch == clean.label.lowercased())
            .filter(\.$id != attributeID)
            .first() == nil else {
            throw Abort(.conflict, reason: "You already have an attribute with that name.")
        }
        attribute.label = clean.label
        attribute.labelSearch = clean.label.lowercased()
        attribute.value = clean.value
        attribute.visibility = clean.visibility
        try await attribute.save(on: req.db)
        return attribute.dto()
    }

    func deleteAttribute(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        guard let attributeID = req.parameters.get("attributeID", as: UUID.self),
              let attribute = try await UserProfileAttribute.query(on: req.db)
                .filter(\.$id == attributeID)
                .filter(\.$user.$id == userID)
                .first() else { throw Abort(.notFound) }
        try await attribute.delete(on: req.db)
        return .noContent
    }

    func birthdayAlert(req: Request) async throws -> BirthdayAlertDTO {
        let viewerID = try req.auth.require(User.self).requireID()
        let subject = try await subjectUser(req: req)
        guard try await ProfileAccessService.canViewBirthday(viewerID: viewerID, target: subject, on: req.db) else {
            throw Abort(.forbidden, reason: "This birthday is not available to you.")
        }
        guard viewerID != (try subject.requireID()) else { return .init(enabled: false, reminderDaysBefore: 7) }
        let alert = try await BirthdayAlert.query(on: req.db)
            .filter(\.$subscriber.$id == viewerID)
            .filter(\.$subject.$id == subject.requireID())
            .first()
        return .init(enabled: alert != nil, reminderDaysBefore: alert?.reminderDaysBefore ?? 7)
    }

    func updateBirthdayAlert(req: Request) async throws -> BirthdayAlertDTO {
        let viewerID = try req.auth.require(User.self).requireID()
        let subject = try await subjectUser(req: req)
        let subjectID = try subject.requireID()
        guard viewerID != subjectID else { throw Abort(.badRequest, reason: "You cannot subscribe to your own birthday.") }
        guard try await ProfileAccessService.canViewBirthday(viewerID: viewerID, target: subject, on: req.db) else {
            throw Abort(.forbidden, reason: "This birthday is not available to you.")
        }
        let body = try req.content.decode(UpdateBirthdayAlertRequest.self)
        let days = bodyDays(body)
        if !body.enabled {
            try await BirthdayAlert.query(on: req.db)
                .filter(\.$subscriber.$id == viewerID)
                .filter(\.$subject.$id == subjectID)
                .delete()
            return .init(enabled: false, reminderDaysBefore: days)
        }
        let alert = try await BirthdayAlert.query(on: req.db)
            .filter(\.$subscriber.$id == viewerID)
            .filter(\.$subject.$id == subjectID)
            .first() ?? BirthdayAlert(subscriberID: viewerID, subjectID: subjectID, reminderDaysBefore: days)
        alert.reminderDaysBefore = days
        try await alert.save(on: req.db)
        return .init(enabled: true, reminderDaysBefore: days)
    }

    func birthdayAlerts(req: Request) async throws -> [BirthdayAlertSubscriptionDTO] {
        let subscriberID = try req.auth.require(User.self).requireID()
        let alerts = try await BirthdayAlert.query(on: req.db)
            .filter(\.$subscriber.$id == subscriberID)
            .with(\.$subject)
            .all()
        var result: [BirthdayAlertSubscriptionDTO] = []
        for alert in alerts {
            let subject = alert.subject
            guard try await ProfileAccessService.canViewBirthday(viewerID: subscriberID, target: subject, on: req.db),
                  let month = subject.birthdayMonth,
                  let day = subject.birthdayDay else {
                try await alert.delete(on: req.db)
                continue
            }
            let name = subject.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(.init(
                userID: try subject.requireID(),
                displayName: name?.isEmpty == false ? name! : "Your friend",
                birthdayMonth: month,
                birthdayDay: day,
                reminderDaysBefore: alert.reminderDaysBefore
            ))
        }
        return result
    }

    private func subjectUser(req: Request) async throws -> User {
        guard let userID = req.parameters.get("userID", as: UUID.self),
              let subject = try await User.find(userID, on: req.db) else { throw Abort(.notFound) }
        return subject
    }

    private func details(for userID: UUID, on db: any Database) async throws -> ProfileDetailsDTO {
        guard let user = try await User.find(userID, on: db) else { throw Abort(.notFound) }
        let attributes = try await UserProfileAttribute.query(on: db)
            .filter(\.$user.$id == userID)
            .sort(\.$labelSearch, .ascending)
            .all()
        return .init(
            matureProfileEnabled: user.isAgeRestrictedProfile,
            birthdayMonth: user.birthdayMonth,
            birthdayDay: user.birthdayDay,
            birthdayYear: user.birthdayYear,
            birthdayVisibility: user.birthdayVisibility,
            birthdaySetupCompleted: user.birthdayYear != nil && user.birthdayMonth != nil && user.birthdayDay != nil,
            attributes: attributes.map { $0.dto() }
        )
    }

    private func bodyDays(_ body: UpdateBirthdayAlertRequest) -> Int {
        min(max(body.reminderDaysBefore ?? 7, 0), 365)
    }

    private static func validatedAttribute(_ body: UpsertProfileAttributeRequest) throws -> (label: String, value: String, visibility: String) {
        let label = body.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = body.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 80 else { throw Abort(.badRequest, reason: "Attribute names must be 1–80 characters.") }
        guard !value.isEmpty, value.count <= 200 else { throw Abort(.badRequest, reason: "Attribute values must be 1–200 characters.") }
        guard validVisibility(body.visibility) else { throw Abort(.badRequest, reason: "Invalid attribute visibility.") }
        return (label, value, body.visibility)
    }

    private static func validVisibility(_ visibility: String) -> Bool { ["public", "friends", "private"].contains(visibility) }
    private static func validDate(year: Int, month: Int, day: Int) -> Bool {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let currentYear = calendar.component(.year, from: now)
        guard (currentYear - 120...currentYear).contains(year) else { return false }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return false }
        return date <= calendar.startOfDay(for: now)
    }

    private static func age(year: Int, month: Int, day: Int) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        guard let birthday = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return -1 }
        return calendar.dateComponents([.year], from: birthday, to: Date()).year ?? -1
    }
}
