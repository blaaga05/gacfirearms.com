# Owner checkout switch

Admin > Payment settings has an owner-only Enable checkout / Disable checkout control, default OFF in each environment. Authenticated members can read only the enabled status; only private allowlisted owners can change it. The private settings table is not exposed to clients.

The hosted-checkout SQL entrypoint rejects new requests while OFF, including cached-token retries. The UI polls the state while signed in and fails closed on read errors. Verification webhooks, reconciliation and already submitted payments continue independently. A form already opened on Authorize.net cannot be revoked by this switch; late payments still enter review as before.

ON does not bypass GAC_LIVE_CHECKOUT_ENABLED, owner-only rollout, verified webhook checks or any other release gate. Pretend checkout remains a separate no-charge test feature. Merchandise checkout is not connected by this change.

Sandbox SQL rollback tests cover default OFF, owner-only updates, disabled request/retry rejection and successful crediting of an in-flight payment after OFF. Frontend tests cover toggling, state isolation and failure defaults. No test fixtures are retained.
