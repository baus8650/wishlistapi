import Fluent
import Vapor

final class RecurringOccasion: Model, @unchecked Sendable {
    static let schema = "recurring_occasions"
    @ID(key: .id) var id: UUID?
    @Parent(key: "owner_id") var owner: User
    @Field(key: "name") var name: String
    @Field(key: "name_search") var nameSearch: String
    @Field(key: "event_month") var eventMonth: Int
    @Field(key: "event_day") var eventDay: Int
    @Field(key: "reminder_month") var reminderMonth: Int
    @Field(key: "reminder_day") var reminderDay: Int
    @Field(key: "icon") var icon: String
    @Field(key: "color_hex") var colorHex: String
    @OptionalField(key: "last_created_year") var lastCreatedYear: Int?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    init() {}
    init(id: UUID? = nil, ownerID: UUID, name: String, eventMonth: Int, eventDay: Int, reminderMonth: Int, reminderDay: Int, icon: String, colorHex: String, lastCreatedYear: Int?) {
        self.id = id; self.$owner.id = ownerID; self.name = name; self.nameSearch = name.lowercased()
        self.eventMonth = eventMonth; self.eventDay = eventDay; self.reminderMonth = reminderMonth; self.reminderDay = reminderDay
        self.icon = icon; self.colorHex = colorHex; self.lastCreatedYear = lastCreatedYear
    }
}
