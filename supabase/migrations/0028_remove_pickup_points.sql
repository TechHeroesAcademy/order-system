-- 0028_remove_pickup_points.sql
--
-- Rolls back the pickup points feature added in 0026 entirely, per a later
-- decision to cancel it rather than fold it into order creation. Written
-- so it's safe to run whether or not 0026 was ever applied to this
-- database — every drop uses IF EXISTS, and drop table ... cascade takes
-- pickup_point_regions (and its FK back to pickup_points) with it, so the
-- table order below doesn't actually matter, but is kept parent-last for
-- clarity anyway.
--
-- 0026/0027 are left in place, unedited, as history — this migration is
-- the reversal, not a rewrite of the past.

drop function if exists public.set_pickup_point_regions(uuid, text[]);
drop function if exists public.set_pickup_point_active(uuid, boolean);
drop function if exists public.update_pickup_point(uuid, text, text, text);
drop function if exists public.create_pickup_point(text, text, text, text[]);

drop table if exists public.pickup_point_regions cascade;
drop table if exists public.pickup_points cascade;
