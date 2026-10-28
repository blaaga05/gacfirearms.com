-- Short, customer-facing order numbers. Keep order_number as the gateway invoice reference so existing Authorize.net reconciliation and fulfillment lookups do not change.
alter table public.gac_store_orders add column customer_order_number bigint generated always as identity unique;
comment on column public.gac_store_orders.customer_order_number is 'Short, sequential customer-facing order number. order_number remains the internal gateway invoice reference.';
