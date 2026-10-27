# Item inventory (1.5)

The authenticated `/v1/items` endpoints manage the same canonical items shown in
wishlists. This is an item-management view, not a second wishlist. Items are
returned once regardless of how many lists use them.

- `GET /v1/items`: inventory entries with the item, editable wishlist IDs,
  inaccessible membership count, inventory ownership, and global delete permission.
- `POST /v1/items`: create an item, optionally assigning `linkedWishlistIDs`.
- `PUT /v1/items/:itemID`: replace item details and selected memberships.
- `PUT /v1/items/:itemID/links`: change memberships without overwriting item details.
- `PUT /v1/items/:itemID/sale`: set or clear a sale.
- `PUT` / `DELETE /v1/items/:itemID/image`: manage the item's photo.
- `DELETE /v1/items/:itemID`: explicitly delete the canonical item everywhere.

Deploy `AddItemInventory` before the new client. It backfills inventory ownership
from the original list owner and makes the legacy primary-list reference optional.
Removing an item's last membership, or deleting its last list, preserves the item
and photo in its owner's inventory under **No list**. Only an authorized owner can
access a retained item. Linking to lists requires edit access; inaccessible
existing memberships are preserved. Global deletion requires permission for every
current membership and cascades to claims, notes, memberships, and photos.

Sale notifications use the existing per-item recipient deduplication. No-list
items have no notification audience. Joint-list editors can manage linked items;
when all memberships are removed, retention belongs to the inventory owner.

Database-backed lifecycle tests cover retention, reuse, global deletion,
permission enforcement, retained photos, and migration backfill/rollback.
