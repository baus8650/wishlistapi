import Foundation
import Fluent

final class BirthdayAlert: Model, @unchecked Sendable {
    static let schema = "birthday_alerts"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "subscriber_id")
    var subscriber: User

    @Parent(key: "subject_id")
    var subject: User

    @Field(key: "reminder_days_before")
    var reminderDaysBefore: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, subscriberID: UUID, subjectID: UUID, reminderDaysBefore: Int = 7) {
        self.id = id
        self.$subscriber.id = subscriberID
        self.$subject.id = subjectID
        self.reminderDaysBefore = reminderDaysBefore
    }
}
