# FastBound firearm catalog setup

The firearm flow is deliberately separate from the apparel and accessory cart. It creates a review request; it does not charge a card, reserve an item, decide eligibility, or create a FastBound disposition.

## Enable the feature

1. Apply \`database/firearms-catalog.sql\` to the GAC Website Supabase project.
2. Deploy \`supabase/functions/gac-firearms-admin/index.ts\` as \`gac-firearms-admin\` with JWT verification enabled.
3. Deploy \`supabase/functions/gac-firearm-order-request/index.ts\` as \`gac-firearm-order-request\` with JWT verification disabled. The function accepts only order inquiries, validates every request, limits each email address to five inquiries per hour, and writes customer details to an owner/service-role-only table.
4. Confirm the GAC Website Edge Function environment includes \`FASTBOUND_ACCOUNT_NUMBER\`, \`FASTBOUND_API_KEY\`, and \`GAC_SITE_ORIGIN=https://gacfirearms.com\`. Supabase supplies \`SUPABASE_SERVICE_ROLE_KEY\`; it must never be added to website JavaScript.
5. Sign in as an owner, open **Admin → Firearm inventory**, and run **Sync FastBound inventory**. Syncing imports private serial numbers for matching only. It does not publish a listing.
6. For an item you intend to offer, enter a price and public description, then explicitly check **Publish on the Firearms page**. Do not publish an item until its availability and listing details have been reviewed.

## Request handling

Customers choose a firearm and submit their contact information, residence state, and preferred transfer arrangement. If using another FFL, they provide that licensee’s business and contact details. Requests appear under **Firearm order requests** in the owner panel. A request is not a reservation, sale, or payment. GAC must contact the customer to verify current availability, price, the transfer path, and applicable requirements before taking payment or proceeding in FastBound.

## Firearm shipping and tax values

The **Firearm checkout pricing** section in **Admin → Firearm inventory** stores a flat shipping amount and editable tax rates by state and county/local jurisdiction. It is an owner-only setup panel. It does not calculate a customer total, accept payment, reserve inventory, or change the member merchandise checkout. The values are not used until a separately reviewed firearm checkout is built and enabled.

The initial database row is safe and inactive: shipping is $0 and the destination-rate list is empty. Confirm the shipping service/insurance cost and applicable tax treatment with GAC’s tax preparer or the state tax agency before entering rates. Use the per-destination label to record where the rate applies; update rates as jurisdictions change. The option to tax shipping is stored separately for each destination so the rule can be set after confirmation.

The public catalog view exposes listing fields only; it does not include a serial number, inventory notes, acquisition details, or customer records. Merch and accessory carts remain separate and have no checkout connection to this flow.
