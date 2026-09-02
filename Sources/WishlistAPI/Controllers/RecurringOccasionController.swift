import Fluent
import Vapor

struct RecurringOccasionDTO: Content {
    let id: UUID?; let name: String; let eventMonth: Int; let eventDay: Int
    let reminderMonth: Int; let reminderDay: Int; let icon: String; let colorHex: String
    let lastCreatedYear: Int?
}

struct RecurringOccasionController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let occasions = routes.grouped("recurring-occasions")
        occasions.get(use: index); occasions.post(use: create)
        occasions.put(":occasionID", use: update); occasions.delete(":occasionID", use: delete)
    }
    func index(req: Request) async throws -> [RecurringOccasionDTO] { let owner = try req.auth.require(User.self).requireID(); return try await RecurringOccasion.query(on: req.db).filter(\.$owner.$id == owner).sort(\.$eventMonth).sort(\.$eventDay).all().map(dto) }
    func create(req: Request) async throws -> RecurringOccasionDTO {
        let owner = try req.auth.require(User.self).requireID(), body = try req.content.decode(RecurringOccasionDTO.self); let clean = try validated(body)
        if let existing = try await RecurringOccasion.query(on: req.db).filter(\.$owner.$id == owner).filter(\.$nameSearch == clean.name.lowercased()).filter(\.$eventMonth == clean.eventMonth).filter(\.$eventDay == clean.eventDay).first() { return dto(existing) }
        let value = RecurringOccasion(ownerID: owner, name: clean.name, eventMonth: clean.eventMonth, eventDay: clean.eventDay, reminderMonth: clean.reminderMonth, reminderDay: clean.reminderDay, icon: clean.icon, colorHex: clean.colorHex, lastCreatedYear: clean.lastCreatedYear); try await value.save(on: req.db); return dto(value)
    }
    func update(req: Request) async throws -> RecurringOccasionDTO { let value = try await owned(req), body = try validated(req.content.decode(RecurringOccasionDTO.self)); value.name = body.name; value.nameSearch = body.name.lowercased(); value.eventMonth = body.eventMonth; value.eventDay = body.eventDay; value.reminderMonth = body.reminderMonth; value.reminderDay = body.reminderDay; value.icon = body.icon; value.colorHex = body.colorHex; value.lastCreatedYear = body.lastCreatedYear; try await value.save(on: req.db); return dto(value) }
    func delete(req: Request) async throws -> HTTPStatus { let value = try await owned(req); try await value.delete(on: req.db); return .noContent }
    private func owned(_ req: Request) async throws -> RecurringOccasion { let owner = try req.auth.require(User.self).requireID(); guard let id = req.parameters.get("occasionID", as: UUID.self), let value = try await RecurringOccasion.query(on: req.db).filter(\.$id == id).filter(\.$owner.$id == owner).first() else { throw Abort(.notFound) }; return value }
    private func validated(_ body: RecurringOccasionDTO) throws -> RecurringOccasionDTO { let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines); guard !name.isEmpty, name.count <= 80 else { throw Abort(.badRequest, reason: "Occasion names must be 1–80 characters.") }; guard valid(month: body.eventMonth, day: body.eventDay), valid(month: body.reminderMonth, day: body.reminderDay) else { throw Abort(.badRequest, reason: "Invalid occasion date.") }; let color = body.colorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased(); guard color.range(of: "^[0-9A-F]{6}$", options: .regularExpression) != nil else { throw Abort(.badRequest, reason: "Invalid occasion color.") }; return .init(id: body.id, name: name, eventMonth: body.eventMonth, eventDay: body.eventDay, reminderMonth: body.reminderMonth, reminderDay: body.reminderDay, icon: body.icon.isEmpty ? "gift" : body.icon, colorHex: color, lastCreatedYear: body.lastCreatedYear) }
    private func valid(month: Int, day: Int) -> Bool { (1...12).contains(month) && (1...31).contains(day) }
    private func dto(_ value: RecurringOccasion) -> RecurringOccasionDTO { .init(id: value.id, name: value.name, eventMonth: value.eventMonth, eventDay: value.eventDay, reminderMonth: value.reminderMonth, reminderDay: value.reminderDay, icon: value.icon, colorHex: value.colorHex, lastCreatedYear: value.lastCreatedYear) }
}
