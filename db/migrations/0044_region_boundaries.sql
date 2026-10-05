create extension if not exists postgis;

alter table public.regions
  add column if not exists boundary geography(MultiPolygon, 4326);

alter table public.regions
  add column if not exists boundary_source text
    check (boundary_source is null or boundary_source in ('drawn', 'osm'));
alter table public.regions
  add column if not exists boundary_updated_at timestamptz;

create index if not exists regions_boundary_idx
  on public.regions using gist (boundary)
  where boundary is not null;

alter table public.orders add column if not exists customer_lat double precision;
alter table public.orders add column if not exists customer_lng double precision;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'orders_customer_lat_range') then
    alter table public.orders add constraint orders_customer_lat_range
      check (customer_lat is null or customer_lat between -90 and 90);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'orders_customer_lng_range') then
    alter table public.orders add constraint orders_customer_lng_range
      check (customer_lng is null or customer_lng between -180 and 180);
  end if;
end$$;

alter table public.orders
  add column if not exists customer_point geography(Point, 4326)
  generated always as (
    case
      when customer_lat is null or customer_lng is null then null
      else st_setsrid(st_makepoint(customer_lng, customer_lat), 4326)::geography
    end
  ) stored;

create index if not exists orders_customer_point_idx
  on public.orders using gist (customer_point)
  where customer_point is not null;

create or replace function public.region_for_point(
  p_lat double precision,
  p_lng double precision
)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select r.id
    from public.regions r
   where r.boundary is not null
     and p_lat is not null
     and p_lng is not null
     and st_covers(r.boundary, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography)
   order by st_area(r.boundary) asc, r.name asc
   limit 1;
$$;

revoke all on function public.region_for_point(double precision, double precision) from public;
grant execute on function public.region_for_point(double precision, double precision) to authenticated;

create or replace function public.set_region_boundary(
  p_region_id uuid,
  p_geojson jsonb,
  p_source text default 'drawn'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_geom geometry;
begin
  if not public.is_owner() then
    raise exception 'تعديل حدود المناطق من صلاحية المدير فقط' using errcode = '42501';
  end if;
  if not exists (select 1 from public.regions where id = p_region_id) then
    raise exception 'المنطقة غير موجودة';
  end if;
  if p_source is not null and p_source not in ('drawn', 'osm') then
    raise exception 'مصدر غير معروف للحدود';
  end if;

  if p_geojson is null then
    update public.regions
       set boundary = null, boundary_source = null, boundary_updated_at = now()
     where id = p_region_id;
    return;
  end if;

  begin
    v_geom := st_geomfromgeojson(p_geojson::text);
  exception when others then
    raise exception 'شكل الحدود غير صالح';
  end;

  if st_geometrytype(v_geom) not in ('ST_Polygon', 'ST_MultiPolygon') then
    raise exception 'الحدود يجب أن تكون مضلعًا';
  end if;

  if not st_isvalid(v_geom) then
    v_geom := st_makevalid(v_geom);
    v_geom := st_collectionextract(v_geom, 3);
    if v_geom is null or st_isempty(v_geom) then
      raise exception 'تعذر تصحيح شكل الحدود — أعد رسمها';
    end if;
  end if;

  update public.regions
     set boundary = st_setsrid(st_multi(v_geom), 4326)::geography,
         boundary_source = p_source,
         boundary_updated_at = now()
   where id = p_region_id;
end;
$$;

revoke all on function public.set_region_boundary(uuid, jsonb, text) from public;
grant execute on function public.set_region_boundary(uuid, jsonb, text) to authenticated;

create or replace function public.list_region_boundaries()
returns table (id uuid, name text, boundary jsonb, source text)
language sql
stable
security definer
set search_path = public
as $$
  select r.id, r.name, st_asgeojson(r.boundary)::jsonb, r.boundary_source
    from public.regions r
   where r.boundary is not null
   order by r.name;
$$;

revoke all on function public.list_region_boundaries() from public;
grant execute on function public.list_region_boundaries() to authenticated;
