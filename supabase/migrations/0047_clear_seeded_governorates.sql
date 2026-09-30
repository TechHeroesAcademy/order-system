-- 0047_clear_seeded_governorates.sql
--
-- Removes the 27 Egyptian governorates seeded by 0012, so the regions list
-- starts empty and fills itself from what staff actually type.
--
-- Why: the seed put city-level entries in the list (القاهرة, الجيزة…), but
-- the business distributes by district — شبرا, أكتوبر. A driver assigned to
-- القاهرة would match every order in Cairo, which is the opposite of what
-- the region is for. 0025 already made regions self-creating from typed
-- text; the seed is the last thing standing in the way of that working as
-- intended, because it fills the picker with the wrong granularity.
--
-- Nothing else changes. find_or_create_region() (0025) still normalises a
-- typed name and upserts on regions.name's unique constraint, and
-- set_driver_regions_by_name() still resolves through the very same
-- function — so an order's منطقة and a driver's coverage continue to land
-- on one identical row, and matching stays exact region_id equality.

do $$
declare
  v_seeded text[] := array[
    'القاهرة', 'الجيزة', 'الإسكندرية', 'الدقهلية', 'البحر الأحمر', 'البحيرة', 'الفيوم', 'الغربية', 'الإسماعيلية', 'المنوفية', 'المنيا', 'القليوبية', 'الوادي الجديد', 'السويس', 'أسوان', 'أسيوط', 'بني سويف', 'بورسعيد', 'دمياط', 'الشرقية', 'جنوب سيناء', 'كفر الشيخ', 'مطروح', 'الأقصر', 'قنا', 'شمال سيناء', 'سوهاج'
  ];
  v_deleted int;
  v_kept text[];
begin
  -- Only the untouched ones. A seeded region is kept if it is referenced by
  -- an order or by any driver's coverage, because deleting it would either
  -- fail outright (orders.region_id has no ON DELETE clause, so the foreign
  -- key refuses) or silently strip a driver's coverage through the CASCADE
  -- on driver_regions. Either outcome is worse than leaving one row behind.
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
end $$;
