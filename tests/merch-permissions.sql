-- Run as a rollback-only check; no fixtures or catalog edits are retained.
begin;
set local role anon;
do $$ begin
 if not exists(select 1 from public.gac_merch_products where published) then raise exception 'Public catalog unavailable';end if;
 begin insert into public.gac_merch_products(name,price_cents) values('unauthorized',100);raise exception 'Anonymous write allowed';exception when insufficient_privilege then null;end;
end $$;
reset role;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
do $$ begin
 update public.gac_merch_products set price_cents=1;
 if found then raise exception 'Member write allowed';end if;
 begin insert into public.gac_merch_products(name,price_cents) values('unauthorized',100);raise exception 'Member insert allowed';exception when insufficient_privilege then null;end;
end $$;
rollback;
