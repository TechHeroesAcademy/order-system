-- 0012_seed_egypt_regions.sql
-- Seeds Egypt's 27 governorates as regions, so the Owner/Moderator have a
-- real list to work with immediately instead of adding each city by hand.
-- "on conflict (name) do nothing" makes this safe to re-run, and it never
-- overwrites a region the Owner has since renamed or added manually.

insert into public.regions (name) values
  ('القاهرة'),
  ('الجيزة'),
  ('الإسكندرية'),
  ('الدقهلية'),
  ('البحر الأحمر'),
  ('البحيرة'),
  ('الفيوم'),
  ('الغربية'),
  ('الإسماعيلية'),
  ('المنوفية'),
  ('المنيا'),
  ('القليوبية'),
  ('الوادي الجديد'),
  ('السويس'),
  ('أسوان'),
  ('أسيوط'),
  ('بني سويف'),
  ('بورسعيد'),
  ('دمياط'),
  ('الشرقية'),
  ('جنوب سيناء'),
  ('كفر الشيخ'),
  ('مطروح'),
  ('الأقصر'),
  ('قنا'),
  ('شمال سيناء'),
  ('سوهاج')
on conflict (name) do nothing;
