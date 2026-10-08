import Fluent
import SQLKit
import Vapor

enum SaleNotificationService {
    static func audience(purpose: String, ownerID: UUID, recipientIDs: Set<UUID>, actorID: UUID?) -> Set<UUID> {
        if purpose == "for_myself" { return [ownerID] }
        return recipientIDs.subtracting(Set([ownerID] + (actorID.map { [$0] } ?? [])))
    }

    static func notify(item: WishlistItem, actorID: UUID?, title: String, message: String,
                       on db: any Database, client: any Client, logger: Logger) async throws {
        let memberships = try await WishlistItemMembership.query(on: db)
            .filter(\.$item.$id == item.requireID()).with(\.$wishlist).all()
        for membership in memberships where !membership.wishlist.isArchived {
            let list = membership.wishlist
            let listID = membership.$wishlist.id
            var recipientIDs = Set<UUID>()
            if list.purpose != "for_myself" {
                let social = try await SocialWishlistAccess.query(on: db).filter(\.$wishlist.$id == listID).with(\.$viewer).all()
                let saved = try await PublicWishlistAccess.query(on: db).filter(\.$wishlist.$id == listID).with(\.$viewer).all()
                recipientIDs.formUnion(social.filter { $0.viewer.notificationsEnabled }.map(\.$user.id))
                recipientIDs.formUnion(saved.filter { $0.viewer.notificationsEnabled }.compactMap { $0.viewer.$user.id })
            }
            for userID in audience(purpose: list.purpose, ownerID: list.$owner.id, recipientIDs: recipientIDs, actorID: actorID) {
                // Self-directed alerts must not be suppressed as the actor's own activity.
                try await ActivityService.create(userID: userID, actorID: userID == actorID ? nil : actorID,
                    wishlistID: listID, kind: "wishlist_updated", title: title,
                    message: "\(message) in “\(list.title)”. Tap to view the item.", on: db, client: client, logger: logger)
            }
        }
    }
}

enum SaleReminderService {
    static func schedule(on app: Application) {
        _ = app.eventLoopGroup.next().scheduleRepeatedTask(initialDelay: .seconds(60), delay: .minutes(15)) { _ in
            Task {
                do { try await sendDue(on: app.db, client: app.client, logger: app.logger) }
                catch { app.logger.error("Unable to send sale reminders: \(error)") }
            }
        }
    }

    static func isDue(_ item: WishlistItem, now: Date) -> Bool {
        guard let end = item.saleEndsAt, end > now, end <= now.addingTimeInterval(24 * 60 * 60),
              item.saleReminderSentForEnd != end,
              item.salePrice != nil || item.saleDiscountPercent != nil else { return false }
        return item.price != nil && item.itemType != "cash_fund"
    }

    static func sendDue(on db: any Database, client: any Client, logger: Logger, now: Date = Date()) async throws {
        let candidates = try await WishlistItem.query(on: db)
            .filter(\.$saleEndsAt > now).filter(\.$saleEndsAt <= now.addingTimeInterval(24 * 60 * 60)).all()
        for candidate in candidates {
            let id = try candidate.requireID()
            // Claim the item within the transaction so overlapping workers and restarts
            // cannot produce another Activity reminder for the same sale end date.
            try await db.transaction { transaction in
                guard let sql = transaction as? any SQLDatabase else { throw Abort(.internalServerError) }
                let locked = try await sql.raw("SELECT id FROM wishlist_items WHERE id = \(bind: id) FOR UPDATE SKIP LOCKED").all()
                guard !locked.isEmpty, let item = try await WishlistItem.find(id, on: transaction), isDue(item, now: now) else { return }
                try await SaleNotificationService.notify(item: item, actorID: nil,
                    title: "Sale ending soon", message: "The sale on \(item.title) ends within 24 hours",
                    on: transaction, client: client, logger: logger)
                item.saleReminderSentForEnd = item.saleEndsAt
                try await item.save(on: transaction)
            }
        }
    }
}
