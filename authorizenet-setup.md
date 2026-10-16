# GAC Accept Hosted integration — INCOMPLETE, sandbox release gate

Updated 2026-10-16. General member checkout remains disabled. New live owner checkout is paused by default in both UI and Edge Function. Existing live webhooks and manual reconciliation remain operational. Existing accounts, orders, logo snapshots, and recognition are unchanged.

## Confirmed current behavior

- Full-page external form POST (target _self) to the official Authorize.net hosted page. No embedded iframe, card inputs, or saved payment methods in GAC.
- Supabase Edge Functions hold credentials; frontend receives only the short-lived hosted token and own checkout ID.
- Pending private checkout intent snapshots member, numbers, exact hold IDs, server price, acknowledgment, original deadline, and unique invoice. Server ignores frontend totals. The fulfilled order is inserted only after authenticated gateway verification.
- Success and cancellation return to /account.html. Account-scoped sessionStorage tracks the intent. Returning never marks a purchase paid.
- Raw-body HMAC SHA-512 verification precedes durable deduplicated notification storage. Authenticated getTransactionDetails supplies invoice, transaction status/type, amount and time. Atomic SQL checks the intent/holds and credits once. No raw webhook or gateway response containing card data is persisted or logged.
- CAPTCHA, CVV and required billing controls retained. addPaymentProfile=false and no customer profile ID.
- Expired/released/mismatched holds and duplicate charges enter private owner review. Review resolution does not issue a refund/void or assign numbers.
- Owner retry processes up to ten durable pending notifications. Automatic scheduled recovery for completely missed notifications is not yet implemented.

## Prior verification

The owner reported a successful checkout. Payment-specific evidence remains private and is not included in this repository. This does not establish sandbox coverage or settlement/refund behavior.

## Sandbox isolation configuration

Only one Supabase project is currently connected, the production project yuuagwxqhxiiybwjhome. An isolated test project/site and Authorize.net sandbox account are required before end-to-end sandbox testing. Do not copy real member data into testing.

In the isolated Supabase project, set these server-only secrets:

- AUTHORIZENET_ENVIRONMENT=sandbox
- AUTHORIZENET_SANDBOX_PROJECT_URL=<that project's exact SUPABASE_URL>
- GAC_SITE_ORIGIN=<the isolated HTTPS test site's origin, no trailing slash>
- AUTHORIZENET_SANDBOX_API_LOGIN_ID=<sandbox login>
- AUTHORIZENET_SANDBOX_TRANSACTION_KEY=<sandbox transaction key>
- AUTHORIZENET_SANDBOX_SIGNATURE_KEY=<sandbox signature key>

Do not paste secrets into chat, commit them, or reuse production keys. The runtime never falls back from missing sandbox keys to production keys. Sandbox configuration rejects the known production database, a mismatching test project URL, and the live website origin.

Sandbox endpoints are fixed:
- API https://apitest.authorize.net/xml/v1/request.api
- Hosted form https://test.authorize.net/payment/payment
- Webhooks management https://apitest.authorize.net/rest/v1/webhooks

Deploy the same schema and functions to the isolated project with synthetic test members, logo assets and collections only. Point an isolated frontend at that project and enable its owner-only sandbox checkout control; the current production portal intentionally disables its live checkout button. Configure the sandbox webhook to the isolated project's gac-authorizenet-webhook URL. Keep the sandbox gateway in Live Mode (sandbox transactions still never charge real funds), not its transaction-disabling Test Mode.

Production reconciliation retains existing AUTHORIZENET_API_LOGIN_ID, AUTHORIZENET_TRANSACTION_KEY and AUTHORIZENET_SIGNATURE_KEY. Production is the compatibility default when AUTHORIZENET_ENVIRONMENT is absent; this preserves existing notification verification. New production tokens additionally require GAC_LIVE_CHECKOUT_ENABLED=true. Do not set that release flag until test evidence and release review are complete. The independent private-owner gates remain enforced in both Edge Function and SQL, so that flag alone does not enable ordinary members.

## Verification matrix

| Scenario | Current evidence | Release requirement |
| --- | --- | --- |
| Hosted redirect and live purchase | Actual owner browser/payment + DB verified | Repeat in sandbox |
| Server price, secrets isolation, no profiles | Automated unit tests | Sandbox inspection |
| Missing/forged/tampered signatures | Automated unit tests | Sandbox endpoint replay |
| Duplicate notifications and second charge | SQL rollback tests | Sandbox repeated notification and distinct second charge |
| Changed/expired holds; amount mismatch | SQL rollback tests | Sandbox end-to-end late-payment handling |
| Declined/held gateway response | Mocked gateway unit tests | Actual sandbox decline/fraud rules |
| Cancel/back navigation; token expiry | Return is not used as proof; no end-to-end evidence | Browser sandbox tests |
| Browser closes before return | Server webhook independent of return | Sandbox browser-close test |
| Reporting/database failure and delayed webhook | Mock retry + durable inbox | Actual recovery test |
| Completely missed webhook | Manual durable-inbox retry cannot recover an event never received | Implement scheduled reporting reconciliation |
| Void, full/partial refund, fraud lifecycle | Not complete; manual review only | Implement and test explicit lifecycle accounting without silently reissuing numbers |
| Simultaneous buyers / double-click | SQL locking/idempotent snapshots; unit tests | Concurrent sandbox exercise |
| Member privacy and owner permissions | SQL rollback tests | Nonowner end-to-end sandbox checks |
| Mobile and desktop | Owner Chrome live form confirmed | Sandbox devices and navigation |

62 automated Node tests pass after environment changes. They are mocked/unit tests, not a completed sandbox certification. SQL rollback coverage was previously executed against production without retained fixtures. No new schema or member data changes in this update.

## Remaining release decisions

Confirm merchant account USD currency; the ledger is USD and the hosted request relies on the merchant's currency. Confirm gateway required Form Fields. Implement and test reporting recovery and refund/void/fraud lifecycle. Complete PCI SAQ A based on actual controls and processor-confirmed channel scope; separately cover mobile acceptance. Do not attest to script monitoring not implemented. Hosted redirect eligibility is not an automatic compliance certification.

Blank hosted-page issue was isolated to return settings containing query strings; plain return URLs fixed it. Preserve plain URLs and browser-scoped checkout tracking. Do not remove CAPTCHA or required billing to troubleshoot.

References: https://developer.authorize.net/api/reference/features/accept-hosted.html and https://developer.authorize.net/hello_world/testing_guide.html
