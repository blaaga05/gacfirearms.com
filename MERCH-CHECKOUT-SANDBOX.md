# Guest merchandise checkout — sandbox only

Implemented only in the isolated payment-sandbox site and Supabase project. The Edge Function rejects production payment environments. Live merchandise checkout remains coming soon. Shipping and tax are $0 test values; shipping policy, tax calculation, fraud/rate controls and final production activation are not completed by this release.

Guest checkout snapshots server prices and quantities, reserves stock for 20 minutes, and redirects by form POST to Authorize.net Accept Hosted. The hosted page collects billing, shipping and email and disables saved payment profiles. The GAC site does not handle card numbers/CVV. Guest order access requires a random browser-held secret, hashed in the private database. Returning to the site never proves payment.

Signed notifications, canonical transaction details, existing scheduled reporting and expiry checking also recognize merchandise invoices. Verified capture consumes stock once. Review payments protect stock without shipment. Unopened cancelled and verified unpaid expired orders release stock. Late paid orders recheck stock; unavailable stock or missing shipping goes to owner review. Void/refund observations update financial status but do not automatically restock shipped goods.

Owner orders and a separate sandbox merchandise checkout toggle appear under Admin → Merch & accessories. Stock adjustment controls remain the place to receive actual returns after inspection.

Sandbox opening counts: S 10, M 25, other shirt sizes 0, handguard 5. Shirt $30; handguard $25 test price. Production stock and prices were not seeded or changed.

## Automated checks

- Server quote ignores client prices; unavailable/pending-price options rejected.
- Reservation excludes competing buyers, owner count cannot undercut reservations.
- Service-only mutations, owner-only management, hashed guest order access.
- Merchant review protects stock, capture decrements once, duplicate events preserve stock.
- Refunds update state without automatically restocking.
- Existing collection regression tests retained.

## Pending hands-on checks

- [x] Guest successful hosted checkout, email/address capture, return receipt and stock deduction (Small 10 → 9, October 17 sandbox test).
- [ ] Decline/retry, cancel/abandon and verified expiry.
- [ ] Two browsers competing for stock and repeated return/status requests.
- [ ] Fraud review/approval/void.
- [ ] Settled full/partial refund observations.

Keep all live checkout gates off until outstanding tests and production shipping/tax/abuse controls are complete.
