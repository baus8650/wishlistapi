import Fluent
import Vapor

final class UserProfileAttribute: Model, @unchecked Sendable {
    static let schema = "user_profile_attributes"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "label")
    var label: String

    @Field(key: "label_search")
    var labelSearch: String

    @Field(key: "value")
    var value: String

    @Field(key: "visibility")
    var visibility: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, userID: UUID, label: String, value: String, visibility: String) {
        self.id = id
        self.$user.id = userID
        self.label = label
        self.labelSearch = label.lowercased()
        self.value = value
        self.visibility = visibility
    }
}

struct ProfileAttributeDTO: Content {
    let id: UUID?
    let label: String
    let value: String
    let visibility: String
    let selectedUserIDs: [UUID]
}

extension UserProfileAttribute {
    func dto(selectedUserIDs: [UUID] = []) -> ProfileAttributeDTO {
        .init(id: id, label: label, value: value, visibility: visibility, selectedUserIDs: selectedUserIDs)
    }
}

final class UserProfileAttributeAudience: Model, @unchecked Sendable {
    static let schema = "user_profile_attribute_audiences"

    @ID(key: .id) var id: UUID?
    @Parent(key: "attribute_id") var attribute: UserProfileAttribute
    @Parent(key: "user_id") var user: User

    init() {}

    init(attributeID: UUID, userID: UUID) {
        self.$attribute.id = attributeID
        self.$user.id = userID
    }
}
