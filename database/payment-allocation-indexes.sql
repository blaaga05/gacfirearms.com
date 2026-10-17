create index if not exists payment_expiring_checkouts_idx on gac_private.authorizenet_checkouts(collection_id,expires_at)where order_id is null and token_claimed_at is not null;
create index if not exists payment_allocations_unreleased_idx on gac_private.payment_allocations(updated_at desc)where released_at is null;
create index if not exists payment_allocation_events_checkout_idx on gac_private.payment_allocation_events(checkout_id,created_at);
