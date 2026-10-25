# Merchandise checkout release notes

The merchandise cart now has a hosted Authorize.Net checkout path for guest orders. The server prices each cart from the published product catalog, reserves stock for 20 minutes, and only deducts inventory after Authorize.Net transaction details verify the payment. Verified paid orders appear in Admin → Orders & Shipping and stock changes are recorded in the existing inventory ledger. Card data stays on Authorize.Net.

Admin → Products & inventory lets the owner set each item's price, options, shipping per unit, and available stock. Georgia sales tax is calculated at checkout from the delivery county using the Georgia DOR general rate chart currently effective October 1–December 31, 2026. The customer supplies the full US delivery address before payment and reviews the server-calculated total before continuing to Authorize.Net. Georgia's special local districts are shown for Fulton, DeKalb, and Clayton Counties. Out-of-state orders are not charged sales tax while GAC has no collection obligation outside Georgia. Payment-review holds are listed separately in Orders & Shipping and contribute to the order-tab indicator.

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

For product-level shipping fields, apply `database/product-inventory-pricing.sql` after the checkout migrations and before deploying the matching product editor. Then apply `database/georgia-checkout-tax.sql` before deploying the matching checkout function. The owner edits each item's price, per-item shipping amount, public options, and stock in Admin → Products & inventory. No per-product tax rates are needed. Firearm listings and FastBound stay under Firearms & Compliance.

## Release checks

Before enabling production payments, verify:

1. Approved payment creates one order, one stock-ledger sale, and one order-oversight row.
2. Declined payment, cancel, abandoned checkout, and an expired checkout do not reduce stock; a delayed or duplicate gateway notification cannot double-deduct stock.
3. Two browsers competing for the last unit cannot both pay successfully.
4. Amount mismatch, incomplete shipping details, and Authorize.Net fraud review keep stock protected and surface in the owner payment-review list.
5. Full and partial refunds update the order status and never restock automatically.
6. Georgia checkout uses the correct county or supported city-district rate; the taxable base includes merchandise and shipping. Out-of-state orders collect no Georgia tax. Mixed-product carts use per-item shipping and one destination-based tax rate.
7. RLS, function grants, server secrets, webhook signature validation, webhook retry, payment recovery, and payment-expiry checks pass in the isolated sandbox.
8. Cloudflare serves the intended commit and the production payment gate is still closed until final approval.
