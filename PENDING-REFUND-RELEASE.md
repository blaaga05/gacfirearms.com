# Releasing collection numbers after a verified refund request

A gateway-confirmed refundPendingSettlement counts as refund credit for number release; it does not mean settlement is complete.

- A full verified pending refund automatically releases ordinary numbers only while the collection remains open, unarchived, not due for recognition, and without recognition snapshots/results.
- Payments previously protected during merchant review retain manual release. Use Refunds & number release to apply the verified refund to selected numbers.
- A partial refund never guesses which number to remove. Owner selects the specific number(s); the server checks the original per-number price and unused verified pending/settled refund credit. Other numbers and the original receipt remain intact.
- A partially available, unfulfilled purchase can be resolved by refunding its missing original number and crediting the retained protected originals, once the original capture and sufficient refund credit are verified.
- Releases are audited and idempotent. Replays cannot release a later purchaser’s number. Closed/recognized history is preserved.
- A refund that later becomes failed/voided/declined after release opens an owner payment review and a message alert. Released numbers are never reclaimed automatically.

## Verified

Sandbox rollback database tests cover full pending release, partial selection/budget, repeated release, protected manual release, missing-number resolution, capture replay, failed-refund alert deduplication, later purchaser protection, closed history and nonowner denial. Frontend tests cover a one-number partial refund, explicit confirmation and owner-state clearing.

Actual sandbox full-refund request released its original number while financial status stayed refund_pending. Actual partial-refund owner selection remains the next hands-on check. Final refund settlement remains pending and is separate from number release.

Live collection checkout remains off. Physical merchandise inventory/refunds are separate and do not use this number-release mechanism.
