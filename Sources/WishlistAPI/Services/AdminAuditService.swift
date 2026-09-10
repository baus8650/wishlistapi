import Fluent
import Vapor

enum AdminAuditService {
    static func record(_ req: Request, adminID: UUID, action: String, targetType: String? = nil, targetID: UUID? = nil, metadata: String? = nil) async {
        do {
            try await AdminAuditEvent(adminID: adminID, action: action, targetType: targetType, targetID: targetID, metadata: metadata).save(on: req.db)
        } catch {
            req.logger.warning("Admin audit event could not be saved: \(error)")
        }
    }
}

