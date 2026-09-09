import Fluent
import SQLKit
import Vapor

struct AddAdultConfirmationToWishlistViewer: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE \(raw: WishlistViewer.schema) ADD COLUMN IF NOT EXISTS adult_confirmed_at TIMESTAMPTZ")
            .run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE \(raw: WishlistViewer.schema) DROP COLUMN IF EXISTS adult_confirmed_at")
            .run()
    }
}
