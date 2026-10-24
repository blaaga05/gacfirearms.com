# GAC website to-do list

Added October 16, 2026. Requested by Blake; selection controls implemented October 17, 2026.

- [x] Add an owner-only pause/resume control for number selection on an open collection, without closing the collection. Enforce the pause on the server so new holds cannot race with manual assignment. Show members that selection is temporarily paused. Define existing hold/payment handling without silently taking away a member's held or paid number.
- [x] Allow owner manual number assignment before a collection's scheduled release, while member number selection remains unavailable. Preserve uniqueness, member attribution, assignment audit/history, and purchase records; prevent assignment over an existing paid number or another member's valid hold.
- [ ] After shipping accounts are configured, connect carrier tracking events to update customer orders to Delivered automatically. Add an owner-initiated cancellation flow for customer requests that checks Authorize.Net status, voids unsettled payments or refunds settled payments, and marks the order cancelled only after gateway confirmation. Do not restock automatically; verify returned items first.

Selection pause preserves current holds and checkout; it blocks new holds on the server under the same collection lock as assignment. Owner assignment accepts draft and unreleased open groups, with existing duplicate/hold protection and audit records. Production checkout remains disabled. Remaining payment verification includes actual settled refunds, held/fraud responses, and provider/database outage recovery.
