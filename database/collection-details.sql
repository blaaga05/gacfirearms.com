begin;

alter table public.gac_collections
  add column if not exists details text not null default '';

commit;
