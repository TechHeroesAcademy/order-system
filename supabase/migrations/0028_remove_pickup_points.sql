drop function if exists public.set_pickup_point_regions(uuid, text[]);
drop function if exists public.set_pickup_point_active(uuid, boolean);
drop function if exists public.update_pickup_point(uuid, text, text, text);
drop function if exists public.create_pickup_point(text, text, text, text[]);

drop table if exists public.pickup_point_regions cascade;
drop table if exists public.pickup_points cascade;
