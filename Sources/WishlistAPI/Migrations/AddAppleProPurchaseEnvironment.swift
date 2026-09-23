import Fluent

/// Retains whether Apple signed an entitlement in production or sandbox. This
/// makes App Review/TestFlight grants auditable without accepting Xcode or
/// locally generated StoreKit transactions on the public API.
struct AddAppleProPurchaseEnvironment: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AppleProPurchase.schema)
            .field("store_environment", .string, .required, .sql(.default("Production")))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(AppleProPurchase.schema)
            .deleteField("store_environment")
            .update()
    }
}
