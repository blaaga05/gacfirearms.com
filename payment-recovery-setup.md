# Payment recovery — sandbox verification in progress

Updated October 17, 2026. Public checkout stays OFF and the owner-only launch gate remains. This update is staged in the payment-sandbox branch; production deployment is pending end-to-end recovery testing.

## Implemented

- Five-minute pg_cron/pg_net invocation, authenticated with a random token generated and retained in Supabase Vault. The token never reaches browser code or source control. Owner-authenticated manual checks are also available.
- Exclusive two-minute worker lease, bounded runtime, persistent paginated discovery cursor, and a durable transaction retry queue. Unsettled transactions and settled batches are queried directly from Authorize.net. Multi-day outages catch up in seven-day windows. Queue throughput is deliberately bounded; owner health shows backlog and failures.
- Gateway transaction details supply the verified invoice, amount, transaction type and status. Existing atomic allocation and original hold checks remain authoritative. Missing notifications can be discovered independently; durable saved notifications are retried too.
- Verified voids, pending/settled partial or full refunds are recorded separately from original orders. Refund events do not fulfill another order. Original order history, digital logo receipts and recognition are preserved. Refund/void operations remain manual in Authorize.net. With payment-number-release.sql, a verified void or fully settled refund releases only that order’s active numbers while the collection is open, unarchived and before recognition starts. Closed, recognized, due-for-recognition and snapshotted collections retain assignments. Partial/pending refunds do not release numbers. Replayed events cannot release numbers reassigned to another order.
- Owner Payment settings shows recovery health and gateway activity. Members see their own refund/void status on receipts. No card data or raw gateway responses are persisted or logged.

## Evidence so far

- Actual sandbox run verified prior captured payments and a manually voided late payment; order/number counts did not increase.
- SQL rollback tests passed for missing-notification allocation, payment/notification idempotence, competing member holds, released-hold protection, financial reversal accounting, private-role enforcement, worker leases, and fixture cleanup. Competing sequential transactions are not a completed simultaneous-browser race test.
- Automated tests cover reporting outages, empty RPC bodies, pagination checkpoints, unauthorized workers and financial event isolation. These do not replace external gateway end-to-end tests.

- Mobile hosted form opened and payment succeeded. With the sandbox webhook inactive, the scheduled recovery job credited the new number without any new webhook notification; the owner confirmed it appeared on the wheel. Webhook was subsequently restored to Active.

## Still required

- Duplicate real notification replay.
- Mobile logo download check, simultaneous buyers, held/fraud response recovery, settlement, partial/full refund lifecycle, and recovery after simulated provider/database outages.
- Confirm merchant USD and processor approval of the actual business/payment channel; finish PCI based on implemented controls.
- Deploy reviewed code/schema/functions/schedule to production, verify health, and perform controlled release review. Do not turn on public checkout based on the unit tests alone.

Sources: https://developer.authorize.net/api/reference/features/transaction-reporting.html and https://supabase.com/docs/guides/functions/schedule-functions

## Automatic number release (sandbox)
Apply payment-number-release.sql after payment-recovery.sql. Purchased number snapshots remain on the original order under existing order RLS. Release uses the collection lock shared by checkout and recognition and records numbers_released_at. The receipt adapter and owner member details read the saved snapshot after an allocation is released. Verified sandbox void released its number; rollback tests cover full refund release, receipt preservation, resale plus old event replay, closed collection and recognition snapshot protection. Actual settled refund testing remains pending; this does not complete production launch.
