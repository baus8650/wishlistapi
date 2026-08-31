import Fluent
import SQLKit

struct AddUserDisplayNameSearch: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema)
            .field("display_name_search", .string)
            .update()
        if let sql = database as? any SQLDatabase {
            try await sql.raw("UPDATE users SET display_name_search = LOWER(display_name) WHERE display_name IS NOT NULL").run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema).deleteField("display_name_search").update()
    }
}
