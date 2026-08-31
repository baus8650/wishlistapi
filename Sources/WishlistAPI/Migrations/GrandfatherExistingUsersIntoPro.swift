import Fluent

/// Grants lifetime Pro to every account that exists when this migration runs.
/// New accounts receive the column default (`false`) and can unlock through StoreKit.
struct GrandfatherExistingUsersIntoPro: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema)
            .field("has_lifetime_pro", .bool, .required, .sql(.default(false)))
            .update()

        let existingUsers = try await User.query(on: database).all()
        for user in existingUsers {
            user.hasLifetimePro = true
            try await user.save(on: database)
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema)
            .deleteField("has_lifetime_pro")
            .update()
    }
}
