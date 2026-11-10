import Fluent
import Vapor

enum SwapWishlistService {
    // Called while the swap row is locked. Reuse normal item storage and controllers,
    // but never create a viewer record or normal sharing grant for the gifter.
    static func prepare(_ swap: HushfulSwap, on db: any Database) async throws {
        guard swap.state.status != "cancelled" else { return }
        var changed = false
        for i in swap.state.members.indices where swap.state.members[i].status == "accepted" {
            let member = swap.state.members[i]
            guard let userID = member.userID, try await User.find(userID, on: db) != nil else { continue }
            if let id = member.wishlistID, try await Wishlist.find(id, on: db) != nil { continue }
            let list = Wishlist(ownerUserId: userID, title: "\(swap.state.title) · Swap wishlist")
            list.swapID = try swap.requireID()
            list.purpose = "for_others" // Legacy purpose value for wishes for the owner.
            list.currencyCode = swap.state.currencyCode
            list.allowNotes = false
            try await list.save(on: db)
            swap.state.members[i].wishlistID = try list.requireID()
            // Import the earlier lightweight list once, so existing wishes are preserved.
            for (position, wish) in member.wishes.enumerated() {
                try await add(wish, list: list, ownerID: userID, position: position, on: db)
            }
            swap.state.members[i].wishes = []
            changed = true
        }
        if changed { try await swap.save(on: db) }
    }

    static func view(_ swap: HushfulSwap, memberIndex: Int, on db: any Database) async throws -> SwapView {
        let me = swap.state.members[memberIndex]
        let recipient = swap.state.status == "drawn" ? swap.state.members.first { $0.id == me.recipientID } : nil
        var result = try SwapSecurity.view(swap, memberIndex: memberIndex)
        if let id = me.wishlistID, let list = try await Wishlist.find(id, on: db), list.$owner.id == me.userID {
            result.wishlist = try WishlistController().summary(list, for: list.$owner.id, isCollaborative: false)
            result.wishes = try await wishes(listID: id, on: db)
        }
        if let recipient, let id = recipient.wishlistID, let userID = me.userID,
           let list = try await Wishlist.find(id, on: db) {
            let allowed = try await canRead(list: list, userID: userID, on: db)
            result.recipient = .init(name: recipient.name, wishes: allowed ? try await wishes(listID: id, on: db) : [])
        }
        return result
    }

    static func wishes(listID: UUID, on db: any Database) async throws -> [SwapWish] {
        let listCurrency = try await Wishlist.find(listID, on: db)?.currencyCode
        return try await WishlistItemMembership.query(on: db).filter(\.$wishlist.$id == listID).with(\.$item)
            .sort(\.$position).all().map { link in
                let item = link.item
                return SwapWish(title: item.title, url: item.url, note: item.ownerNote, id: item.id, updatedAt: item.updatedAt,
                    price: item.price, currencyCode: item.currencyCode ?? listCurrency, quantity: item.quantity,
                    salePrice: item.salePrice, saleDiscountPercent: item.saleDiscountPercent,
                    saleEndsAt: item.saleEndsAt, itemType: item.itemType, contributionGoal: item.contributionGoal)
            }
    }

    static func replace(_ wishes: [SwapWish], for member: SwapMember, on db: any Database) async throws {
        guard let id = member.wishlistID, let ownerID = member.userID,
              let list = try await Wishlist.find(id, on: db), list.$owner.id == ownerID else { throw Abort(.notFound) }
        let old = try await WishlistItemMembership.query(on: db).filter(\.$wishlist.$id == id).all()
        for (position, wish) in wishes.enumerated() { try await add(wish, list: list, ownerID: ownerID, position: position, on: db) }
        for link in old {
            try await link.delete(on: db)
            if try await WishlistItemMembership.query(on: db).filter(\.$item.$id == link.$item.id).count() == 0,
               let item = try await WishlistItem.find(link.$item.id, on: db) { try await item.delete(on: db) }
        }
    }

    private static func add(_ wish: SwapWish, list: Wishlist, ownerID: UUID, position: Int, on db: any Database) async throws {
        let item = WishlistItem(wishlistId: try list.requireID(), title: wish.title, url: wish.url,
            price: wish.price, ownerNote: wish.note, quantity: wish.quantity ?? 1,
            itemType: wish.itemType ?? "wish", contributionGoal: wish.contributionGoal)
        item.position = position
        item.$inventoryOwner.id = ownerID
        item.currencyCode = wish.currencyCode
        item.salePrice = wish.salePrice; item.saleDiscountPercent = wish.saleDiscountPercent; item.saleEndsAt = wish.saleEndsAt
        try await item.save(on: db)
        try await WishlistItemMembership(itemID: item.requireID(), wishlistID: list.requireID(), position: position).save(on: db)
        if let sourceID = wish.id, let image = try await WishlistItemImage.query(on: db).filter(\.$item.$id == sourceID).first() {
            try await WishlistItemImage(itemID: item.requireID(), data: image.data, contentType: image.contentType).save(on: db)
        }
    }

    static func canRead(list: Wishlist, userID: UUID, on db: any Database) async throws -> Bool {
        guard let swapID = list.swapID, let swap = try await HushfulSwap.find(swapID, on: db),
              swap.state.status == "drawn", let me = swap.state.members.first(where: { $0.userID == userID && $0.status == "accepted" }),
              let recipient = swap.state.members.first(where: { $0.id == me.recipientID }) else { return false }
        guard recipient.wishlistID == list.id,
              try await !ProfileAccessService.isBlocked(userID, list.$owner.id, on: db),
              let owner = try await User.find(list.$owner.id, on: db),
              let viewer = try await User.find(userID, on: db) else { return false }
        return !(list.matureContentEnabled || owner.isAgeRestrictedProfile) || viewer.derivedAgeBand == "adult"
    }

    static func requireOrdinarySharing(_ wishlist: Wishlist) throws {
        guard wishlist.swapID == nil else { throw Abort(.forbidden, reason: "Swap wishlists are shared only with the assigned gifter inside the swap.") }
    }
}
