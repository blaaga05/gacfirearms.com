# Authorize.net setup checkpoint

Live gateway authentication confirmed by owner screenshot, 2026-10-16 UTC. No charge performed.

Deployed functions:
- gac-payment-check: validates caller with Auth user API and private owner RPC; authenticateTestRequest only; reports latest signed notification timestamp.
- gac-authorizenet-webhook: validates raw-body HMAC SHA512 before parsing, stores minimal notification/transaction identifiers in a deduplicated private inbox. Does NOT credit orders yet. Unsigned notifications return401; storage failures return503.

Secrets are manually stored by owner in Supabase; never read/export/commit their values.

Next external step: create INACTIVE Authorize.net webhook endpoint, event net.authorize.payment.authcapture.created, send test ping. Check owner Payment setup button afterward or private inbox SQL timestamp. Signature key format alone is not verification. New key can have 24h overlap with old signature key; if ping fails, check expiry before rotating again.

Endpoint https://yuuagwxqhxiiybwjhome.supabase.co/functions/v1/gac-authorizenet-webhook

Remaining before live checkout:
- Atomic server-priced checkout intent and fixed cart snapshots.
- Hosted token creation authCaptureTransaction, no customer/card storage profiles, signed-in member authorization.
- Protect holds through payment completion, late approval/refund/review handling; never silently drop successful payments or reassign sold numbers.
- Durable inbox processor: getTransactionDetails validates transaction status, non-test flag, exact intent invoice/member/amount/currency; idempotent credit. Never trust browser redirect or webhook amount alone.
- Reconciliation for missed/delayed events, void/refund/fraud handling and owner visibility.
- Hosted redirect and return/cancel UI, member receipt refresh; owner-only controlled tests before enabling all members.
- Complete PCI questionnaire against deployed implementation and all other payment channels; do not attest to unverified requirements.

Member checkout remains disabled. No real or synthetic live payments or member credits have been created by the assistant. JS tests47 pass; SQL inbox deduplication/access test ran inside rollback.
