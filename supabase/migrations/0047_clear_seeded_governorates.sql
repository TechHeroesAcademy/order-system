do $$
declare
  v_seeded text[] := array[
    'القاهرة', 'الجيزة', 'الإسكندرية', 'الدقهلية', 'البحر الأحمر', 'البحيرة', 'الفيوم', 'الغربية', 'الإسماعيلية', 'المنوفية', 'المنيا', 'القليوبية', 'الوادي الجديد', 'السويس', 'أسوان', 'أسيوط', 'بني سويف', 'بورسعيد', 'دمياط', 'الشرقية', 'جنوب سيناء', 'كفر الشيخ', 'مطروح', 'الأقصر', 'قنا', 'شمال سيناء', 'سوهاج'
  ];
  v_deleted int;
  v_kept text[];
begin
  select array_agg(r.name order by r.name) into v_kept
    from public.regions r
   where r.name = any (v_seeded)
     and (exists (select 1 from public.orders o where o.region_id = r.id)
       or exists (select 1 from public.driver_regions d where d.region_id = r.id));

  delete from public.regions r
   where r.name = any (v_seeded)
     and not exists (select 1 from public.orders o where o.region_id = r.id)
     and not exists (select 1 from public.driver_regions d where d.region_id = r.id);
  get diagnostics v_deleted = row_count;

  raise notice 'removed % seeded governorate(s)', v_deleted;
  if v_kept is not null then
    raise notice 'kept % still in use (orders or driver coverage): %', array_length(v_kept, 1), array_to_string(v_kept, ', ');
    raise notice 'reassign those orders/drivers to a district, then delete the region by hand';
  end if;
end$$;
