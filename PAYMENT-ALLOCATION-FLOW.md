# Number holds and verified payments

Checkout remains switched off. This release does not remove the owner testing or live launch gates.

- Unpaid holds expire at their original deadline. An opened checkout is briefly marked Checking while the gateway is checked; reporting failures keep it protected for retry.
- A verified late capture receives original numbers automatically if still available. Missing numbers can be replaced without another charge, while available originals remain reserved.
- Timely payments held for merchant approval retain numbers beyond the deadline, off the wheel. Approval fulfills once. Reversal waits for the owner to click Release protected numbers.
- Partial or pending refunds require owner review. A verified full refund permits manual release of protected allocations. Closed or recognized history is preserved.
- Server-side signature checks, transaction reporting, amount and identity matching, row locks, and unique payment references remain required. Returning from checkout never fulfills a purchase.

## Validation and remaining checks

Node tests and rollback database scenarios cover late availability, replacements, competing holds, privacy, replay, timely review, manual release, refunds, and closed collections. The actual sandbox expiry scan also passed.

Still required before launch: hands-on sandbox checks of the revised late-payment and replacement flow, timely fraud approval/reversal plus owner release, and the actual settled refund test. Keep checkout off until these pass. No card numbers or CVVs are stored and saved payment methods remain disabled.
