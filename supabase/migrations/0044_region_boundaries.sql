-- 0044_region_boundaries.sql
--
-- Gives regions a real shape on the map, and orders a real position, so
-- "which area is this order in" stops being a guess from a typed name and
-- becomes a geometric fact.
--
-- Until now a region was a row with a name and nothing else, and an order's
-- region was whatever someone picked from a dropdown (or whatever free text
-- matched, per 0025). That works until two people spell شبرا differently, or
-- until a customer's address is ambiguous enough that nobody is sure which
-- driver covers it.
--
-- Nothing here is mandatory. A region with no boundary behaves exactly as it
-- does today, and an order with no coordinates behaves exactly as it does
-- today. Both new columns are nullable on purpose so this migration changes
-- no existing behaviour on the day it is applied.

-- PostGIS is what makes "is this point inside that shape" a single indexed
-- operation rather than something the app has to compute by pulling every
-- polygon into memory. Supabase ships it; it just needs enabling.
create extension if not exists postgis;

-- ── a region's shape ────────────────────────────────────────────────────
--
-- geography rather than geometry: geography measures in metres on the
-- actual curved earth, so ST_Area gives real square metres and any future
-- distance question ("nearest driver") is correct without picking a
-- projection for Egypt. The cost is that fewer functions accept it, but the
-- two used here — ST_Covers and ST_Area — both do.
--
-- MultiPolygon rather than Polygon: a delivery area is not always one
-- contiguous blob. أكتوبر in particular is several separated built-up
-- pieces, and an area split by a canal or a desert strip is normal. Storing
-- a single Polygon would force an artificial join between them.
--
-- SRID 4326 is plain WGS84 latitude/longitude — what every GPS, every map
-- library and every Google Maps link already speaks, so nothing has to be
-- converted on the way in or out.
alter table public.regions
  add column if not exists boundary geography(MultiPolygon, 4326);

-- Where the boundary came from, so a hand-drawn area is distinguishable
-- from an imported one when someone asks "who decided شبرا stops here".
alter table public.regions
  add column if not exists boundary_source text
    check (boundary_source is null or boundary_source in ('drawn', 'osm'));
alter table public.regions
  add column if not exists boundary_updated_at timestamptz;

-- A GiST index is what makes the containment test cheap. Without it every
-- lookup compares the point against every polygon in full; with it, Postgres
-- first eliminates almost all of them by bounding box. Partial, because a
-- region with no boundary can never match and there is no reason to carry
-- it in the index.
create index if not exists regions_boundary_idx
  on public.regions using gist (boundary)
  where boundary is not null;

-- ── an order's position ─────────────────────────────────────────────────
--
-- Orders have carried customer_address (free text) and customer_maps_url (a
-- pasted link) since 0020, but never coordinates of their own. A pasted
-- Maps link does contain a position, but only inside a URL whose format is
-- Google's to change, so it is not something to parse and depend on.
--
-- Stored as two plain columns rather than a geography point because that is
-- what every other lat/lng in this schema already looks like (factories,
-- and profiles before them), and because the app reads and writes them
-- individually. The generated column below is what the spatial index and
-- the containment test actually use, so there is exactly one source of
-- truth and the two can never disagree.
alter table public.orders add column if not exists customer_lat double precision;
alter table public.orders add column if not exists customer_lng double precision;

-- Bounds checks, so a transposed lat/lng or a units mistake fails loudly at
-- write time instead of silently placing an order in the Atlantic.
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
end $$;

-- Derived, never written directly: null unless both halves are present, so
-- a half-filled coordinate can't produce a point on the prime meridian.
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

-- ── which region is this point in? ──────────────────────────────────────
--
-- ST_Covers rather than ST_Contains: Contains returns false for a point
-- exactly on the boundary line, so an order pinned on the street that
-- divides two districts would belong to neither. Covers includes the edge.
-- With adjacent areas that share an edge a point on the line matches both,
-- and the ordering below then picks one deterministically.
--
-- Ordered by area ascending so the *smallest* containing region wins. That
-- is the rule that makes nesting work: if شبرا is drawn inside القاهرة, an
-- order in شبرا should belong to شبرا, because that is the more specific —
-- and more useful — answer for deciding who delivers it.
--
-- Returns null when the point is outside everything. That is a real answer,
-- not a failure: the order is created without a region and surfaces in the
-- unallocated queue for a manager to place by hand. Nothing is guessed.
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

-- ── setting a boundary ──────────────────────────────────────────────────
--
-- Owner-only, matching every other decision about who covers what
-- (set_driver_regions_by_name, set_manager_factories). Takes GeoJSON
-- because that is what both the drawing tool and OpenStreetMap emit, so
-- nothing has to be translated in the app.
--
-- Accepts a Polygon or a MultiPolygon and normalises to MultiPolygon, so
-- the column type never has to care which the caller happened to produce.
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

  -- Clearing a boundary is a legitimate operation, not an error.
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

  -- A hand-drawn shape can self-intersect if the points cross over — a
  -- figure eight. ST_Covers on an invalid polygon gives undefined answers
  -- rather than an error, which would show up later as orders landing in
  -- the wrong area for no visible reason. MakeValid repairs it here, at the
  -- one moment someone is looking at the shape they just drew.
  if not st_isvalid(v_geom) then
    v_geom := st_makevalid(v_geom);
    -- Repair can yield lines or collections if the input was degenerate.
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

-- ── reading boundaries back for the map ─────────────────────────────────
--
-- The app needs GeoJSON, and it needs it without the raw geography column,
-- which PostgREST would otherwise serialise as an opaque hex string. A
-- function rather than a view so the polygon is only ever fetched when a
-- map is actually being drawn — the order list and the team table read
-- regions constantly and have no use for the shapes.
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
