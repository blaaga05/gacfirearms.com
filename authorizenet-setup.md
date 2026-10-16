# Authorize.net checkout owner pilot — 2026-10-16

Owner confirmed live API authentication and signed webhook ping. The synthetic ping (transaction245) was marked ignored after receipt verification. No real charge or permanent purchase was made by the assistant.

Functions:
- gac-payment-check: owner-only credential authentication test, last signed notification timestamp.
- gac-hosted-checkout: owner-only. Verifies caller against Auth and private owner RPC; verifies active webhook via live gateway REST API before requesting a payable token. Creates server-priced fixed-cart checkout snapshot. Hosted authCaptureTransaction in USD, no card/profile storage, card code and billing address required, captcha, external POST redirect. Saved token reused; original hold expiry unchanged. Minimum90seconds remaining.
- gac-authorizenet-webhook: raw-body HMAC verification, durable deduplicated minimal inbox, authenticated getTransactionDetails, exact invoice/amount/status/type validation, atomic DB credit. Transient/reporting failures return503 and remain pending for gateway retries.

Data:
- Private checkouts store exact member/number/hold-token/price/acknowledgment snapshots and short-lived hosted form token. Public authenticated RPCs expose only own status. Owner pilot is enforced in SQL and Edge Function. No card fields are accepted by GAC frontend/backend.
- Crediting: collection row lock + intent lock; exact original live holds, active membership, still-open live collection before recognition, approved capture status and server-fetched amount. Idempotent transaction/order credit. Price edits honor saved checkout amount.
- Exceptions: expired/changed/released holds, closed collection, mismatched amount/status, duplicate second charge become owner payment reviews. No double assignment. Owner must verify/void/refund in Authorize.net as appropriate, then record resolution. Resolution button does not execute financial actions or assign numbers.
- Owner Payment setup lists reviews and Retry saved payment notifications. Return URL does not prove payment. Own checkout status polls5sec and refreshes purchases after verified credit.

External next step:
1 Set existing GAC Website webhook Active, Authcapture Created event.
2 Refresh owner account. Use open live collection (not owner pretend-test group), choose number, acknowledge, Checkout LIVE owner pilot.
3 Inspect hosted form; stop before Pay for first preview. User performs any actual low-value payment afterward.

Verification:
- 54 Node tests pass including server-priced token, active webhook gate, no payment-profile storage, signed notification rejection/tampering, gateway-derived amounts, failed reporting retry.
- SQL rollback tests passed: nonowner pilot denial, amount mismatch, duplicate events/charges, snapshot pricing, consumed holds, expired/released holds, private account status and grants. No permanent fixture data.
- Linkedom full portal mount/logout and owner handoff confirmation/cancel/private cleanup passed. No browser/live payment test yet.

Remaining before broad member rollout:
- Actual owner hosted-form preview, controlled live payment and receipt/wheel validation.
- Confirm Authorize.net USD account and actual Payment Form required fields.
- Full late-payment/void/refund/fraud lifecycle tests; current pilot routes exceptions to manual review rather than auto-refunding or changing existing recognition.
- Scheduled reconciliation beyond gateway webhook retries (manual retry is present). Do not claim missed-notification automation exists.
- PCI questionnaire against actual deployed checkout and all other acceptance channels. Do not attest to unverified controls. Supabase leaked-password protection remains disabled; existing advisor warnings for explicitly guarded definer RPCs/private RLS tables reviewed, not a full security audit.

Secrets are owner-managed in Supabase. Never read/export/commit their values. Public member checkout stays disabled until separate rollout.

## Hosted blank-form debugging update

Owner Chrome showed only Order Summary, then payment:24 SyntaxError and undefined g_errorPanelMessage. Extracted hosted error: technical issue processing request. No actual payment/card entry yet.

Owner-only no-charge diagnostic added to Payment setup; Edge Function gac-payment-check action diagnose creates form tokens, posts each server-side to hosted URL, reports only safe error classifications. Never returns tokens, HTML, credentials, or card data. Latest diagnostic has baseline + full + each extra setting separately.

2026-10-16 01:55Z owner screenshot: baseline with invoice succeeds; full request fails; Return links variant alone fails; every other individual setting (CAPTCHA, required billing, color, button, payment options, shipping, customer, order) succeeds.

Fix deployed: return and cancel URLs are now plain https://gacfirearms.com/account.html without query string. Existing frontend sessionStorage retains account-scoped checkout ID; return URL never proves payment. Pending owner token cache cleared so next attempt mints corrected settings. Need owner browser preview to confirm actual form renders, then controlled real payment later.

Other changes: order description omitted per user. Explicit currencyCode omitted from hosted request; invoice and fixed server amount retained, USD ledger assumes account currency—must confirm actual merchant currency before rollout. One earlier diagnostic put currency after order (schema sequence difference), so do NOT claim currency alone was proven root cause.

Auto-review rejected attempt to replace full settings with minimal because it removed CAPTCHA/required billing. Safer accepted change retained CAPTCHA=true and billing required=true; current live settings include all protections and only plain return links. No pending approval needed. Do not bypass prior rejection.

Current tests:56 Node tests pass, full portal mount/logout and hosted handoff smoke pass; no live charge test. Owner-only public checkout gate remains. PCI questionnaire still pending.
