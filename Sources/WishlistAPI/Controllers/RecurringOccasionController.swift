import Fluent
import Vapor

struct RecurringOccasionDTO: Content {
    var id: UUID?; var name: String; let eventMonth: Int; let eventDay: Int
    let reminderMonth: Int; let reminderDay: Int; var icon: String; var colorHex: String
    let lastCreatedYear: Int?
    var notificationsEnabled: Bool? = nil
    var personID: UUID? = nil
    var person: SocialUserDTO? = nil
    var clearPerson: Bool? = nil
}

struct RecurringOccasionController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let occasions = routes.grouped("recurring-occasions")
        occasions.get(use: index); occasions.post(use: create)
        occasions.put(":occasionID", use: update); occasions.delete(":occasionID", use: delete)
    }

    func index(req: Request) async throws -> [RecurringOccasionDTO] {
        let owner = try req.auth.require(User.self).requireID()
        return try await RecurringOccasion.query(on: req.db).filter(\.$owner.$id == owner)
            .with(\.$person).sort(\.$eventMonth).sort(\.$eventDay).all().map(dto)
    }

    func create(req: Request) async throws -> RecurringOccasionDTO {
        try ProAccessService.requirePro(req.auth.require(User.self))
        let owner = try req.auth.require(User.self).requireID()
        let clean = try validated(req.content.decode(RecurringOccasionDTO.self))
        if let existing = try await RecurringOccasion.query(on: req.db)
            .filter(\.$owner.$id == owner).filter(\.$nameSearch == clean.name.lowercased())
            .filter(\.$eventMonth == clean.eventMonth).filter(\.$eventDay == clean.eventDay)
            .with(\.$person).first() { return dto(existing) }
        let value = RecurringOccasion(ownerID: owner, name: clean.name, eventMonth: clean.eventMonth,
            eventDay: clean.eventDay, reminderMonth: clean.reminderMonth, reminderDay: clean.reminderDay,
            icon: clean.icon, colorHex: clean.colorHex, lastCreatedYear: clean.lastCreatedYear)
        try await applyPerson(clean, to: value, ownerID: owner, req: req)
        value.notificationsEnabled = clean.notificationsEnabled ?? true
        try await value.save(on: req.db)
        return dto(value)
    }

    func update(req: Request) async throws -> RecurringOccasionDTO {
        try ProAccessService.requirePro(req.auth.require(User.self))
        let value = try await owned(req)
        let body = try validated(req.content.decode(RecurringOccasionDTO.self))
        try await applyPerson(body, to: value, ownerID: value.$owner.id, req: req)
        value.name = body.name; value.nameSearch = body.name.lowercased()
        value.eventMonth = body.eventMonth; value.eventDay = body.eventDay
        value.reminderMonth = body.reminderMonth; value.reminderDay = body.reminderDay
        value.icon = body.icon; value.colorHex = body.colorHex; value.lastCreatedYear = body.lastCreatedYear
        if let enabled = body.notificationsEnabled { value.notificationsEnabled = enabled }
        try await value.save(on: req.db)
        return dto(value)
    }

    func delete(req: Request) async throws -> HTTPStatus {
        let value = try await owned(req); try await value.delete(on: req.db); return .noContent
    }

    private func owned(_ req: Request) async throws -> RecurringOccasion {
        let owner = try req.auth.require(User.self).requireID()
        guard let id = req.parameters.get("occasionID", as: UUID.self),
              let value = try await RecurringOccasion.query(on: req.db).filter(\.$id == id)
                .filter(\.$owner.$id == owner).with(\.$person).first() else { throw Abort(.notFound) }
        return value
    }

    private func applyPerson(_ body: RecurringOccasionDTO, to value: RecurringOccasion, ownerID: UUID, req: Request) async throws {
        if body.clearPerson == true {
            value.$person.id = nil
            value.$person.value = .some(nil)
            return
        }
        guard let personID = body.personID else {
            if value.$person.id == nil { value.$person.value = .some(nil) }
            return
        }
        if personID == value.$person.id { return }
        let friendships = try await Friendship.query(on: req.db).filter(\.$status == "accepted")
            .group(.or) { $0.filter(\.$requester.$id == ownerID).filter(\.$recipient.$id == ownerID) }.all()
        guard personID != ownerID, friendships.contains(where: { $0.$requester.id == personID || $0.$recipient.id == personID }),
              try await !ProfileAccessService.isBlocked(ownerID, personID, on: req.db),
              let person = try await User.find(personID, on: req.db) else {
            throw Abort(.badRequest, reason: "Choose one of your friends for this occasion.")
        }
        value.$person.id = personID
        value.$person.value = person
    }

    private func validated(_ body: RecurringOccasionDTO) throws -> RecurringOccasionDTO {
        var clean = body
        clean.name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.name.isEmpty, clean.name.count <= 80 else { throw Abort(.badRequest, reason: "Occasion names must be 1–80 characters.") }
        guard valid(month: body.eventMonth, day: body.eventDay), valid(month: body.reminderMonth, day: body.reminderDay) else { throw Abort(.badRequest, reason: "Invalid occasion date.") }
        clean.colorHex = body.colorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        guard clean.colorHex.range(of: "^[0-9A-F]{6}$", options: .regularExpression) != nil else { throw Abort(.badRequest, reason: "Invalid occasion color.") }
        if clean.icon.isEmpty { clean.icon = "gift" }
        return clean
    }

    private func valid(month: Int, day: Int) -> Bool { (1...12).contains(month) && (1...31).contains(day) }

    private func dto(_ value: RecurringOccasion) -> RecurringOccasionDTO {
        let person = value.person.flatMap { user -> SocialUserDTO? in
            guard let id = user.id else { return nil }
            return SocialUserDTO(id: id, username: user.username ?? "hushful_\(id.uuidString.prefix(8).lowercased())",
                displayName: user.displayName, hasAvatar: user.avatarData != nil)
        }
        return .init(id: value.id, name: value.name, eventMonth: value.eventMonth, eventDay: value.eventDay,
            reminderMonth: value.reminderMonth, reminderDay: value.reminderDay, icon: value.icon,
            colorHex: value.colorHex, lastCreatedYear: value.lastCreatedYear,
            notificationsEnabled: value.notificationsEnabled, personID: value.$person.id, person: person)
    }
}
