import Fluent
import SQLKit

/// Accounts that previously used the temporary optional-birthday flow must
/// complete the birthday step before age-based access can be determined.
struct NormalizeBirthdaySetupState: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("UPDATE \"users\" SET \"birthday_setup_completed\" = CASE WHEN \"birthday_year\" IS NOT NULL AND \"birthday_month\" IS NOT NULL AND \"birthday_day\" IS NOT NULL THEN TRUE ELSE FALSE END").run()
    }

    func revert(on database: any Database) async throws {}
}
