# GAC website to-do list

Added October 16, 2026. Requested by Blake; implementation pending.

- [ ] Add an owner-only pause/resume control for number selection on an open collection, without closing the collection. Enforce the pause on the server so new holds cannot race with manual assignment. Show members that selection is temporarily paused. Define existing hold/payment handling without silently taking away a member's held or paid number.
- [ ] Allow owner manual number assignment before a collection's scheduled release, while member number selection remains unavailable. Preserve uniqueness, member attribution, assignment audit/history, and purchase records; prevent assignment over an existing paid number or another member's valid hold.

Current task remains Authorize.net sandbox payment verification, including the pending expired-hold/late-payment test. These to-do items should not interrupt that test or enable production checkout.
