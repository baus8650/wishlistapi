@testable import WishlistAPI
import Fluent
import Foundation
import Testing
import Vapor

@Suite("Private recipient sales", .serialized)
struct RecipientSaleTests {
    @Test("Gift recipients stay outside planning; owners of joint and curated lists can participate")
    func planningAccess() {
        #expect(!WishlistPermissionService.giftsAreForOthers(purpose: "for_others", isCollaborative: false))
        #expect(WishlistPermissionService.giftsAreForOthers(purpose: "for_others", isCollaborative: true))
        #expect(WishlistPermissionService.giftsAreForOthers(purpose: "for_myself", isCollaborative: false))
        #expect(WishlistPermissionService.giftsAreForOthers(purpose: "for_myself", isCollaborative: true))
    }

    @Test("Joint owners can read planning through both APIs; Gifts for me owners remain excluded")
    func jointOwnerPlanningAccess() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await app.autoMigrate()
            let owner = User(email: "planning-owner-\(UUID())@example.com", passwordHash: "unused")
            let coOwner = User(email: "planning-coowner-\(UUID())@example.com", passwordHash: "unused")
            try await owner.save(on: app.db)
            try await coOwner.save(on: app.db)
            let wishlist = Wishlist(ownerUserId: try owner.requireID(), title: "Joint planning")
            try await wishlist.save(on: app.db)
            let wishlistID = try wishlist.requireID()
            let ownerViewer = WishlistViewer(wishlistId: wishlistID, userId: try owner.requireID())
            try await ownerViewer.save(on: app.db)
            let req = Request(application: app, on: app.eventLoopGroup.next())
            req.auth.login(owner)
            req.parameters.set("wishlistID", to: wishlistID.uuidString)
            do {
                _ = try await RecipientShareController().listItemsWithState(req: req, wishlist: wishlist, viewer: ownerViewer)
                Issue.record("Gift recipient read private planning")
            } catch let error as Abort { #expect(error.status == .forbidden) }
            do {
                _ = try await WishlistDiscussionController().list(req: req)
                Issue.record("Gift recipient entered owner discussion API")
            } catch let error as Abort { #expect(error.status == .forbidden) }

            try await WishlistCollaborator(wishlistID: wishlistID, userID: coOwner.requireID()).save(on: app.db)
            for user in [owner, coOwner] {
                req.auth.login(user)
                let viewer = user.id == owner.id ? ownerViewer : WishlistViewer(wishlistId: wishlistID, userId: try user.requireID())
                let rows = try await RecipientShareController().listItemsWithState(req: req, wishlist: wishlist, viewer: viewer)
                #expect(rows.isEmpty)
                let comments = try await WishlistDiscussionController().list(req: req)
                #expect(comments.isEmpty)
            }
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("Recipient validation never changes an owner's sale")
    func ownerSaleIsUnchanged() throws {
        let wishlistID = UUID()
        let item = WishlistItem(wishlistId: wishlistID, title: "Gift", price: 100)
        item.salePrice = 90
        let end = Date().addingTimeInterval(3600)
        try RecipientShareController().validateRecipientSale(
            .init(salePrice: 60, saleDiscountPercent: nil, saleEndsAt: end), item: item, wishlistID: wishlistID)
        #expect(item.price == 100)
        #expect(item.salePrice == 90)
        #expect(item.saleEndsAt == nil)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        #expect(encoded["recipientSale"] == nil)
    }

    @Test("Recipient sales reject invalid prices, ambiguous discounts, past dates, and cash funds")
    func validation() {
        let wishlistID = UUID()
        let item = WishlistItem(wishlistId: wishlistID, title: "Gift", price: 100)
        let controller = RecipientShareController()
        let invalid: [RecipientShareController.RecipientSale] = [
            .init(salePrice: 101, saleDiscountPercent: nil, saleEndsAt: nil),
            .init(salePrice: 50, saleDiscountPercent: 20, saleEndsAt: nil),
            .init(salePrice: nil, saleDiscountPercent: 101, saleEndsAt: nil),
            .init(salePrice: 50, saleDiscountPercent: nil, saleEndsAt: .distantPast)
        ]
        for sale in invalid {
            #expect(throws: Abort.self) { try controller.validateRecipientSale(sale, item: item, wishlistID: wishlistID) }
        }
        item.itemType = "cash_fund"
        #expect(throws: Abort.self) {
            try controller.validateRecipientSale(.init(salePrice: 50, saleDiscountPercent: nil, saleEndsAt: nil), item: item, wishlistID: wishlistID)
        }
    }
}
