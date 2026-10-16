begin;
alter table public.gac_merch_products add column category text not null default 'merch' check(category in ('merch','accessories'));
alter table public.gac_merch_products add column price_pending boolean not null default false;
insert into public.gac_merch_products(name,description,price_cents,sizes,image_path,published,category,price_pending)
values('Defender Handguard','Defender handguard. GAC will add product details, dimensions and compatibility information before sales open.',1,array['Standard'],'/assets/gac-defender-handguard.jpg',true,'accessories',true);
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('gac-product-images','gac-product-images',true,5242880,array['image/jpeg','image/png','image/webp']);
create policy gac_product_image_insert on storage.objects for insert to authenticated with check(bucket_id='gac-product-images' and (select public.gac_is_owner()));
create policy gac_product_image_owner_read on storage.objects for select to authenticated using(bucket_id='gac-product-images' and (select public.gac_is_owner()));
commit;
