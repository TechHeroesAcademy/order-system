-- Pickup points — drop-off locations for collected cooking utensils.
--
-- EL REWAD only runs two factories (Cairo, Alexandria), but drivers cover
-- many more neighborhoods than that — so rather than every driver making a
-- long trip to one of the two factories after every single collection,
-- Owner/Moderator can set up local pickup points where drivers drop off
-- what they've collected. Getting a pickup point's accumulated utensils to
-- the actual factory is a separate, bulk logistics step this app doesn't
-- track order-by-order (per the round-16 decision) — pickup points are
-- purely a "where do I go" reference for drivers, modeled the same
-- region-scoped way driver coverage areas already are.
--
-- Not another `profiles` role: a pickup point has no login of its own, so a
-- plain table (mirroring the factory's own address/lat/lng/maps_url shape,
-- see mapsUrlFor()) is the right fit, not an auth user.

create table if not exists public.pickup_points (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text,
  lat double precision,
  lng double precision,
  maps_url text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.pickup_points is
  'Drop-off locations for collected cooking utensils, region-scoped like driver coverage areas (see pickup_point_regions). The pickup-point-to-factory leg itself is not tracked here — see the migration header comment.';

drop trigger if exists set_pickup_points_updated_at on public.pickup_points;
create trigger set_pickup_points_updated_at
  before update on public.pickup_points
  for each row execute function public.set_updated_at();

create table if not exists public.pickup_point_regions (
  pickup_point_id uuid not null references public.pickup_points(id) on delete cascade,
  region_id uuid not null references public.regions(id) on delete cascade,
  primary key (pickup_point_id, region_id)
);

comment on table public.pickup_point_regions is
  'Which منطقة name(s) each pickup point covers — same shape as driver_regions.';

alter table public.pickup_points enable row level security;
alter table public.pickup_point_regions enable row level security;

-- Read: any signed-in staff member. This is just reference data (a name,
-- an address, a map link) — nothing sensitive — and drivers specifically
-- need to read it to know where to go, same reasoning as why every role
-- can already read `regions`.
drop policy if exists pickup_points_select_staff on public.pickup_points;
create policy pickup_points_select_staff on public.pickup_points
  for select using (auth.role() = 'authenticated');

drop policy if exists pickup_point_regions_select_staff on public.pickup_point_regions;
create policy pickup_point_regions_select_staff on public.pickup_point_regions
  for select using (auth.role() = 'authenticated');

-- Write access is Owner/Moderator-only, entirely through the
-- security-definer RPCs below (same pattern as regions/driver_regions) —
-- no direct INSERT/UPDATE/DELETE policy is needed on either table.

grant select on public.pickup_points to authenticated;
grant select on public.pickup_point_regions to authenticated;

-- ---------- create / update / activate ----------

create or replace function public.create_pickup_point(
  p_name text,
  p_address text,
  p_maps_url text,
  p_region_names text[]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_name text;
  v_region_id uuid;
begin
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'اسم نقطة التجميع مطلوب' using errcode = '22023';
  end if;

  insert into public.pickup_points (name, address, maps_url)
  values (
    trim(p_name),
    nullif(trim(coalesce(p_address, '')), ''),
    nullif(trim(coalesce(p_maps_url, '')), '')
  )
  returning id into v_id;

  -- Same find-or-create-by-name resolver the region feature already uses
  -- (migration 0025) — typing a brand-new منطقة name here creates it too.
  foreach v_name in array coalesce(p_region_names, '{}'::text[])
  loop
    if length(trim(coalesce(v_name, ''))) > 0 then
      v_region_id := public.find_or_create_region(v_name);
      insert into public.pickup_point_regions (pickup_point_id, region_id)
        values (v_id, v_region_id)
        on conflict do nothing;
    end if;
  end loop;

  return v_id;
end;
$$;
revoke all on function public.create_pickup_point(text, text, text, text[]) from public;
grant execute on function public.create_pickup_point(text, text, text, text[]) to authenticated;

create or replace function public.update_pickup_point(
  p_id uuid,
  p_name text,
  p_address text,
  p_maps_url text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'اسم نقطة التجميع مطلوب' using errcode = '22023';
  end if;

  update public.pickup_points
    set name = trim(p_name),
        address = nullif(trim(coalesce(p_address, '')), ''),
        maps_url = nullif(trim(coalesce(p_maps_url, '')), '')
    where id = p_id;

  if not found then
    raise exception 'نقطة التجميع غير موجودة';
  end if;
end;
$$;
revoke all on function public.update_pickup_point(uuid, text, text, text) from public;
grant execute on function public.update_pickup_point(uuid, text, text, text) to authenticated;

create or replace function public.set_pickup_point_active(p_id uuid, p_is_active boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  update public.pickup_points set is_active = p_is_active where id = p_id;
  if not found then
    raise exception 'نقطة التجميع غير موجودة';
  end if;
end;
$$;
revoke all on function public.set_pickup_point_active(uuid, boolean) from public;
grant execute on function public.set_pickup_point_active(uuid, boolean) to authenticated;

create or replace function public.set_pickup_point_regions(p_pickup_point_id uuid, p_region_names text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
  v_id uuid;
  v_ids uuid[] := '{}';
begin
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if not exists (select 1 from public.pickup_points where id = p_pickup_point_id) then
    raise exception 'نقطة التجميع غير موجودة';
  end if;

  foreach v_name in array coalesce(p_region_names, '{}'::text[]) loop
    if length(trim(coalesce(v_name, ''))) > 0 then
      v_id := public.find_or_create_region(v_name);
      if not (v_id = any(v_ids)) then
        v_ids := array_append(v_ids, v_id);
      end if;
    end if;
  end loop;

  delete from public.pickup_point_regions where pickup_point_id = p_pickup_point_id;
  if array_length(v_ids, 1) > 0 then
    insert into public.pickup_point_regions (pickup_point_id, region_id)
      select p_pickup_point_id, x from unnest(v_ids) as x;
  end if;
end;
$$;
revoke all on function public.set_pickup_point_regions(uuid, text[]) from public;
grant execute on function public.set_pickup_point_regions(uuid, text[]) to authenticated;
