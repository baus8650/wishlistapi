import Fluent

struct CreateProfileAttributeAudiences: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_profile_attribute_audiences").id()
            .field("attribute_id", .uuid, .required, .references("user_profile_attributes", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .unique(on: "attribute_id", "user_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_profile_attribute_audiences").delete()
    }
}
