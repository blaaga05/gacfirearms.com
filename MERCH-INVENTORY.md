# Merchandise inventory

Owner controls: Account → Admin → Merch & accessories → select a product → Inventory.

Set a physical count once per size/option. Receive stock adds arrivals; Record sale subtracts in-person sales; Adjust corrects damage or discrepancies with a reason. Set physical count replaces the count after a recount. Changes are recorded privately. Refresh before retrying a conflicting edit. Retired sizes retain their counts/history but disappear publicly.

The storefront shows the selected size’s count, out-of-stock state, and a stock count in each option. Unknown stock is labeled Availability to be confirmed, never an invented count. Cart additions cannot exceed the last known count. Counts refresh about every 30 seconds and on window focus; carts do not reserve inventory.

## Online purchase integration still required

Physical merchandise checkout remains coming soon. Digital-logo collection payments do not reduce physical merchandise inventory. No automatic merchandise-sale deduction is claimed by this release.

When physical checkout is implemented, the server must reserve stock atomically per product/option with expiry, calculate prices/shipping/tax itself, decrement only on verified accepted payment, and deduplicate fulfillment by payment/order identity. Failed or abandoned checkouts release reservations. A refund must not automatically restock a shipped/damaged item; the owner confirms an actual return. Never use browser cart prices or return URLs as proof of payment.

## Checks

Sandbox rollback tests verify owner-only writes, public visibility, variant independence, opening counts, receipts, sales, duplicate requests, stale revisions, negative-stock rejection and retained size history. Node tests verify per-size cart limits and unknown/sold-out labels. All test fixtures roll back; no example counts are seeded.
