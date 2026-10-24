# Merchandise checkout release notes

The merchandise cart now has a hosted Authorize.Net checkout path for guest orders. The server prices each cart from the published product catalog, reserves stock for 20 minutes, and only deducts inventory after Authorize.Net transaction details verify the payment. Verified paid orders appear in Admin → Orders & Shipping and stock changes are recorded in the existing inventory ledger. Card data stays on Authorize.Net.

Admin → Inventory & Integrations → Merchandise & accessories includes manually adjustable flat shipping and tax-rate fields. Saving these values does not activate payment acceptance. Payment-review holds are listed separately in Orders & Shipping and contribute to the order-tab indicator.

## Safety gates

- The database setting starts with enabled = false.
- Production Edge Function requests are rejected unless GAC_LIVE_MERCH_CHECKOUT_ENABLED=true.
- The admin pricing control cannot turn payment acceptance on; the server-side gate must also be deliberately changed after release checks.
- The storefront checkout button remains disabled until the server reports availability.
- Sandbox mode requires the isolated sandbox Supabase project and a non-production site origin.

Keep the production environment gate unset and the database setting disabled until the release checks below pass.

## Database setup

The migration expects the current main-branch merchandise catalog, inventory, store-order tracking, payment-recovery, and payment-expiry migrations to be installed first. Then apply database/merch-checkout.sql followed by database/merch-checkout-hardening.sql. The checkout migration uses explicit function grants and private order tables; do not grant anon access to private order data.

After the migration, verify owner-only access to shipping/tax settings and review orders, verify the public checkout-availability RPC is not executable by anon, and run tests/merch-checkout.sql in a rollback-only test environment.

## Release checks

Before enabling production payments, verify:

1. Approved payment creates one order, one stock-ledger sale, and one order-oversight row.
2. Declined payment, cancel, abandoned checkout, and an expired checkout do not reduce stock; a delayed or duplicate gateway notification cannot double-deduct stock.
3. Two browsers competing for the last unit cannot both pay successfully.
4. Amount mismatch, incomplete shipping details, and Authorize.Net fraud review keep stock protected and surface in the owner payment-review list.
5. Full and partial refunds update the order status and never restock automatically.
6. Manually entered shipping and tax values appear in the hosted payment total.
7. RLS, function grants, server secrets, webhook signature validation, webhook retry, payment recovery, and payment-expiry checks pass in the isolated sandbox.
8. Cloudflare serves the intended commit and the production payment gate is still closed until final approval.
