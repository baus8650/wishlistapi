import Fluent

struct AddPushDevicePlatform: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(PushDevice.schema).field("platform", .string, .required, .sql(.default("ios"))).update()
    }
    func revert(on database: any Database) async throws {
        try await database.schema(PushDevice.schema).deleteField("platform").update()
    }
}
