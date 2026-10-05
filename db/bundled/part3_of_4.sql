-- ============================================================================
-- NEON SETUP — PART 3 OF 4
--
-- PASTE THIS WHOLE FILE INTO NEON'S SQL EDITOR AND RUN IT.
-- Run the parts in order. Wait for each to finish before starting the next.
-- Each part is safe to re-run: every statement is idempotent.
--
-- Requires the previous part to have FINISHED. It uses the order_source
-- enum value that part added, which Postgres will not allow in the same
-- transaction.
--
-- GENERATED — do not edit. Edit the source files listed below and re-run
-- scripts/build-neon-bundle.mjs, so Supabase and Neon cannot drift apart.
--
-- Contains, in order:
--    1. db/migrations/0046_driver_field_orders.sql
--    2. db/migrations/0047_clear_seeded_governorates.sql
--    3. db/migrations/0048_backfill_factory_coords_from_maps_url.sql
--    4. db/migrations/0049_repeat_customer_check.sql
--    5. db/migrations/0050_order_customer_context.sql
--    6. db/migrations/0051_fail_closed_role_guards.sql
-- ============================================================================

-- The chain installs pgcrypto/pg_trgm into the extensions schema (as Supabase
-- does) and several functions resolve against it. Declared per part rather
-- than relied on from the database default, so pasting a part into a fresh
-- editor session always works.
set search_path = public, extensions;



-- ========== db/migrations/0046_driver_field_orders.sql ================

create or replace function public.driver_create_field_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_name text,
  p_pieces_count integer,
  p_factory_id uuid,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null,
  p_customer_maps_url text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
declare
  v_driver uuid := auth.uid();
  v_role public.user_role;
  v_active boolean;
  v_result public.new_order_result;
begin
  select role, is_active into v_role, v_active
    from public.profiles where id = v_driver;

  if v_role is null or not v_active then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if v_role <> 'driver' then
    raise exception 'هذه الطريقة لإنشاء الأوردر مخصصة للمندوبين' using errcode = '42501';
  end if;
  if p_factory_id is null then
    raise exception 'اختر المصنع' using errcode = '22023';
  end if;

  v_result := public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_name,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'driver_field'::order_source, v_driver, p_factory_id, v_driver, p_customer_maps_url
  );

  update public.orders
     set status = 'assigned',
         distribution_approved_at = now(),
         distribution_approved_by = v_driver
   where id = v_result.order_id;

  perform public.log_order_event(
    v_result.order_id, 'field_order_created', 'new', 'assigned',
    'أوردر ميداني أنشأه المندوب وتم إسناده له مباشرة بدون اعتماد'
  );

  perform public.notify_staff(
    v_result.order_id, 'field_order_created',
    'أوردر ميداني جديد من المندوب',
    'أنشأه ' || coalesce((select full_name from public.profiles where id = v_driver), 'مندوب')
      || ' وتم إسناده له مباشرة'
  );

  return v_result;
end;
$$;

revoke all on function public.driver_create_field_order(text, text, text, text, integer, uuid, text, text, text, text, text) from public;
grant execute on function public.driver_create_field_order(text, text, text, text, integer, uuid, text, text, text, text, text) to authenticated;

create or replace function public.orders_by_source_report(p_month date default current_date)
returns table (source text, order_count bigint, delivered_count bigint, total_pieces bigint)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_end date := (date_trunc('month', p_month) + interval '1 month')::date;
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    select o.source::text,
           count(*),
           count(*) filter (where o.status = 'delivered'),
           coalesce(sum(o.pieces_count), 0)
      from public.orders o
     where o.created_at >= v_start and o.created_at < v_end
     group by o.source
     order by count(*) desc;
end;
$$;

create or replace function public.orders_by_creator_report(p_month date default current_date)
returns table (
  creator_name text,
  creator_role text,
  order_count bigint,
  delivered_count bigint,
  field_order_count bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_end date := (date_trunc('month', p_month) + interval '1 month')::date;
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    select coalesce(o.created_by_name, 'غير معروف'),
           coalesce(o.created_by_role::text, '—'),
           count(*),
           count(*) filter (where o.status = 'delivered'),
           count(*) filter (where o.source = 'driver_field')
      from public.orders o
     where o.created_at >= v_start and o.created_at < v_end
     group by o.created_by_name, o.created_by_role
     order by count(*) desc;
end;
$$;

revoke all on function public.orders_by_source_report(date) from public;
revoke all on function public.orders_by_creator_report(date) from public;
grant execute on function public.orders_by_source_report(date) to authenticated;
grant execute on function public.orders_by_creator_report(date) to authenticated;

create or replace function public.order_source_label(p_source public.order_source)
returns text
language sql
immutable
as $$
  select case p_source
    when 'website' then 'الموقع'
    when 'messenger' then 'Messenger'
    when 'driver_field' then 'المندوب في الشارع'
    else p_source::text
  end;
$$;

do $$
declare v_src text;
begin
  select prosrc into v_src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'create_order_internal';

  if v_src is null then
    raise exception 'create_order_internal not found — apply the earlier migrations first';
  end if;

  if position('case when p_source = ''website'' then ''الموقع'' else ''Messenger'' end' in v_src) = 0 then
    raise notice 'creation-note line not found; it may already be patched — leaving create_order_internal untouched';
    return;
  end if;

  v_src := replace(
    v_src,
    'case when p_source = ''website'' then ''الموقع'' else ''Messenger'' end',
    'public.order_source_label(p_source)'
  );

  execute format(
    'create or replace function public.create_order_internal('
    || 'p_customer_name text, p_customer_phone text, p_customer_address text, '
    || 'p_region_name text, p_pieces_count integer, p_piece_details text, '
    || 'p_color text, p_work_required text, p_customer_notes text, '
    || 'p_source order_source, p_created_by uuid, p_factory_id uuid default null, '
    || 'p_driver_id uuid default null, p_customer_maps_url text default null) '
    || 'returns public.new_order_result language plpgsql security definer '
    || 'set search_path = public, extensions as %L', v_src);
end$$;

revoke all on function public.order_source_label(public.order_source) from public;
grant execute on function public.order_source_label(public.order_source) to authenticated;


-- ========== db/migrations/0047_clear_seeded_governorates.sql ==========

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


-- ========== db/migrations/0048_backfill_factory_coords_from_maps_url.sql 

do $$
declare
  v_row record;
  v_lat double precision;
  v_lng double precision;
  v_filled int := 0;
  v_skipped int := 0;
begin
  for v_row in
    select id, name, maps_url
      from public.factories
     where maps_url is not null
       and trim(maps_url) <> ''
       and (lat is null or lng is null)
  loop
    v_lat := null;
    v_lng := null;

    if v_row.maps_url ~ '!3d-?[0-9.]+!4d-?[0-9.]+' then
      v_lat := (regexp_match(v_row.maps_url, '!3d(-?[0-9]+(?:\.[0-9]+)?)'))[1]::double precision;
      v_lng := (regexp_match(v_row.maps_url, '!4d(-?[0-9]+(?:\.[0-9]+)?)'))[1]::double precision;

    elsif v_row.maps_url ~ '@-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?' then
      v_lat := (regexp_match(v_row.maps_url, '@(-?[0-9]+(?:\.[0-9]+)?),'))[1]::double precision;
      v_lng := (regexp_match(v_row.maps_url, '@-?[0-9]+(?:\.[0-9]+)?,(-?[0-9]+(?:\.[0-9]+)?)'))[1]::double precision;

    elsif v_row.maps_url ~ '[?&]q=-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?' then
      v_lat := (regexp_match(v_row.maps_url, '[?&]q=(-?[0-9]+(?:\.[0-9]+)?),'))[1]::double precision;
      v_lng := (regexp_match(v_row.maps_url, '[?&]q=-?[0-9]+(?:\.[0-9]+)?,(-?[0-9]+(?:\.[0-9]+)?)'))[1]::double precision;
    end if;

    if v_lat is null or v_lng is null
       or abs(v_lat) > 90 or abs(v_lng) > 180
       or (v_lat = 0 and v_lng = 0) then
      v_skipped := v_skipped + 1;
      raise notice 'no usable coordinates in the link for: %', v_row.name;
      continue;
    end if;

    update public.factories
       set lat = v_lat, lng = v_lng
     where id = v_row.id;
    v_filled := v_filled + 1;
    raise notice 'placed % at %, %', v_row.name, v_lat, v_lng;
  end loop;

  raise notice '— % factory/factories placed on the map, % still without coordinates', v_filled, v_skipped;
  if v_skipped > 0 then
    raise notice '— for those, open the factory in إدارة الفريق and re-save, or click its location on the map';
  end if;
end$$;


-- ========== db/migrations/0049_repeat_customer_check.sql ==============

create index if not exists orders_customer_phone_last8_idx
  on public.orders (right(regexp_replace(customer_phone, '\D', '', 'g'), 8));

drop index if exists public.orders_customer_phone_idx;

create or replace function public.customer_order_history(p_phone text)
returns table (
  previous_orders bigint,
  open_orders bigint,
  delivered_orders bigint,
  cancelled_orders bigint,
  refused_orders bigint,
  last_order_number text,
  last_order_at timestamptz,
  last_order_status public.order_status,
  names_seen text[]
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role public.user_role;
  v_active boolean;
  v_key text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 8);
begin
  select role, is_active into v_role, v_active
    from public.profiles where id = auth.uid();

  if v_role is null or not v_active then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if v_role not in ('owner', 'moderator', 'driver') then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  if length(v_key) < 8 then
    return query select 0::bigint, 0::bigint, 0::bigint, 0::bigint, 0::bigint,
                        null::text, null::timestamptz, null::public.order_status, null::text[];
    return;
  end if;

  return query
    with matched as (
      select o.id, o.order_number, o.created_at, o.status, o.customer_name
        from public.orders o
       where right(regexp_replace(o.customer_phone, '\D', '', 'g'), 8) = v_key
    ),
    latest as (
      select m.order_number, m.created_at, m.status
        from matched m
       order by m.created_at desc
       limit 1
    )
    select
      (select count(*) from matched),
      (select count(*) from matched m where m.status not in ('delivered', 'refused', 'cancelled')),
      (select count(*) from matched m where m.status = 'delivered'),
      (select count(*) from matched m where m.status = 'cancelled'),
      (select count(*) from matched m where m.status = 'refused'),
      (select l.order_number from latest l),
      (select l.created_at from latest l),
      (select l.status from latest l),
      (select array_agg(n.customer_name order by n.last_at desc)
         from (select m.customer_name, max(m.created_at) as last_at
                 from matched m
                where m.customer_name is not null and trim(m.customer_name) <> ''
                group by m.customer_name
                order by max(m.created_at) desc
                limit 5) n);
end;
$$;

revoke all on function public.customer_order_history(text) from public;
grant execute on function public.customer_order_history(text) to authenticated;

comment on function public.customer_order_history(text) is
  'Aggregate order history for a customer phone number, across every creator. Staff/driver only; shown as a confirmation before a new order is created.';


-- ========== db/migrations/0050_order_customer_context.sql =============

create or replace function public.order_customer_context(p_order_id uuid)
returns table (
  customer_order_index bigint,
  total_orders bigint,
  other_open_orders bigint,
  previous_order_id uuid,
  previous_order_number text,
  previous_order_at timestamptz,
  previous_order_status public.order_status
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_key text;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if v_order is null then
    return;
  end if;

  v_key := right(regexp_replace(v_order.customer_phone, '\D', '', 'g'), 8);
  if length(v_key) < 8 then
    return;
  end if;

  return query
    with matched as (
      select o.id, o.order_number, o.created_at, o.status
        from public.orders o
       where right(regexp_replace(o.customer_phone, '\D', '', 'g'), 8) = v_key
    ),
    prev as (
      select m.id, m.order_number, m.created_at, m.status
        from matched m
       where (m.created_at, m.order_number) < (v_order.created_at, v_order.order_number)
       order by m.created_at desc, m.order_number desc
       limit 1
    )
    select
      (select count(*) from matched m
        where (m.created_at, m.order_number) <= (v_order.created_at, v_order.order_number)),
      (select count(*) from matched),
      (select count(*) from matched m
        where m.id <> v_order.id
          and m.status not in ('delivered', 'refused', 'cancelled')),
      (select p.id from prev p),
      (select p.order_number from prev p),
      (select p.created_at from prev p),
      (select p.status from prev p);
end;
$$;

revoke all on function public.order_customer_context(uuid) from public;
grant execute on function public.order_customer_context(uuid) to authenticated;

comment on function public.order_customer_context(uuid) is
  'This order''s position in its customer''s sequence, plus that customer''s other open orders. Owner/moderator only; shown on the order page.';


-- ========== db/migrations/0051_fail_closed_role_guards.sql ============

create or replace function public.current_user_role()
returns public.user_role
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles
   where id = auth.uid()
     and is_active;
$$;

create or replace function public.is_owner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.current_user_role() = 'owner', false);
$$;

create or replace function public.is_owner_or_moderator()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.current_user_role() in ('owner', 'moderator'), false);
$$;

revoke all on function public.current_user_role() from public;
revoke all on function public.is_owner() from public;
revoke all on function public.is_owner_or_moderator() from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.current_user_role() to authenticated';
    execute 'grant execute on function public.is_owner() to authenticated';
    execute 'grant execute on function public.is_owner_or_moderator() to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'app_user') then
    execute 'grant execute on function public.current_user_role() to app_user';
    execute 'grant execute on function public.is_owner() to app_user';
    execute 'grant execute on function public.is_owner_or_moderator() to app_user';
  end if;
end$$;

do $$
declare
  v_role_before public.user_role;
begin
  select public.current_user_role() into v_role_before;

  if v_role_before is not null then
    raise exception
      'Expected current_user_role() to be NULL with no session, got %. '
      'This migration cannot verify itself — stopping.', v_role_before;
  end if;

  if public.is_owner() is not false then
    raise exception 'is_owner() must be false with no session, got %', public.is_owner();
  end if;
  if public.is_owner_or_moderator() is not false then
    raise exception 'is_owner_or_moderator() must be false with no session, got %',
      public.is_owner_or_moderator();
  end if;

  if not public.is_owner_or_moderator() then
    raise notice 'verified: the `if not is_owner_or_moderator()` guard now fires with no session';
  else
    raise exception
      'The guard still does not fire with no session. All 49 authorization '
      'checks in this schema remain open. Refusing to apply.';
  end if;
end$$;
