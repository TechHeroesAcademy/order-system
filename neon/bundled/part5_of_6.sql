-- ============================================================================
-- NEON SETUP — PART 5 OF 6
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
--    1. supabase/migrations/0046_driver_field_orders.sql
--    2. supabase/migrations/0047_clear_seeded_governorates.sql
--    3. supabase/migrations/0048_backfill_factory_coords_from_maps_url.sql
--    4. supabase/migrations/0049_repeat_customer_check.sql
--    5. supabase/migrations/0050_order_customer_context.sql
--    6. supabase/migrations/0051_fail_closed_role_guards.sql
-- ============================================================================

-- The chain installs pgcrypto/pg_trgm into the extensions schema (as Supabase
-- does) and several functions resolve against it. Declared per part rather
-- than relied on from the database default, so pasting a part into a fresh
-- editor session always works.
set search_path = public, extensions;



-- ========== supabase/migrations/0046_driver_field_orders.sql ==========

-- 0046_driver_field_orders.sql
--
-- A driver creates an order on the doorstep and it is theirs immediately —
-- no manager approval, no waiting.
--
-- REQUIRES 0045 (the driver_field enum value) to have been applied and
-- committed first.
--
-- This is the only path in the system that bypasses manager approval, which
-- was a deliberate exception and is worth stating plainly. The reasoning:
-- the whole value is speed while the customer is standing there. An order
-- that waits for approval is an order the driver cannot collect, so
-- approval would remove the only reason to have the feature.
--
-- What bounds it instead:
--   1. Self-assignment only. The driver is taken from auth.uid() and cannot
--      be supplied, so no driver can create work for anyone else.
--   2. A distinct source, so these are countable and separable forever.
--   3. Managers are notified at creation, since they never got to approve.
--   4. It is in order_history with the driver's name, like everything else.
-- Detection rather than prevention, chosen knowingly.

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
  -- Drivers only. A manager wanting to create an order has the full form,
  -- which routes through approval the way it always has; letting them in
  -- here would give them a quiet way around their own process.
  if v_role <> 'driver' then
    raise exception 'هذه الطريقة لإنشاء الأوردر مخصصة للمندوبين' using errcode = '42501';
  end if;
  if p_factory_id is null then
    raise exception 'اختر المصنع' using errcode = '22023';
  end if;

  -- Everything about the order itself — numbering, the two codes, the
  -- factory check, the region matching — comes from the one function that
  -- already does it. Re-implementing any of that here is how the two paths
  -- would drift.
  --
  -- p_driver_id is auth.uid(), never a parameter of this function.
  v_result := public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_name,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'driver_field'::order_source, v_driver, p_factory_id, v_driver, p_customer_maps_url
  );

  -- Live immediately. create_order_internal leaves an order at 'new'
  -- awaiting approval; this is the one case where the approval has already
  -- happened in the real world — the driver is standing in front of the
  -- customer having agreed the job.
  --
  -- distribution_approved_by is the driver themselves, which is accurate
  -- rather than flattering: the record should say who actually decided.
  update public.orders
     set status = 'assigned',
         distribution_approved_at = now(),
         distribution_approved_by = v_driver
   where id = v_result.order_id;

  perform public.log_order_event(
    v_result.order_id, 'field_order_created', 'new', 'assigned',
    'أوردر ميداني أنشأه المندوب وتم إسناده له مباشرة بدون اعتماد'
  );

  -- Managers find out now, not when they next open the list. This is the
  -- compensating control for skipping approval, so it is not optional and
  -- not batched.
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

-- ── reporting: where orders come from, and who opens them ───────────────
--
-- Two questions the owner could not previously ask at all, and now needs
-- to: how much business are drivers bringing in, and is any one person's
-- output unusual.
--
-- Both scoped to a month so the numbers mean something next to the existing
-- monthly report, and both owner/moderator-gated like every other report.

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

  -- Grouped on the snapshot columns, not a join to profiles, so someone who
  -- has since left still appears with the orders they created rather than
  -- collapsing into an unexplained blank row.
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

-- ── the creation note ───────────────────────────────────────────────────
--
-- create_order_internal writes "تم إنشاء الأوردر عبر …" with a two-way
-- choice: website, or else Messenger. With a third source that `else` now
-- labels every field order as having come from Messenger, which is simply
-- false and sits at the top of the order's own timeline.
--
-- Replaced with a function so the mapping lives in one place and the next
-- source added does not silently inherit the wrong label. Named rather than
-- inlined because create_order_internal is defined in 0033 and this avoids
-- restating that whole function here just to change one string.
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

-- Patch the one line in create_order_internal. Everything else about the
-- function is byte-identical to 0033.
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
end $$;

revoke all on function public.order_source_label(public.order_source) from public;
grant execute on function public.order_source_label(public.order_source) to authenticated;


-- ========== supabase/migrations/0047_clear_seeded_governorates.sql ====

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


-- ========== supabase/migrations/0048_backfill_factory_coords_from_maps_url.sql 

-- 0048_backfill_factory_coords_from_maps_url.sql
--
-- Fills in lat/lng for factories that have a pasted Google Maps link but no
-- coordinates, so they appear on the map instead of being invisible.
--
-- The app already extracts coordinates when a link is entered (it runs when
-- the موقع field loses focus). But that only helps going forward: a factory
-- saved before that existed — or one where the field was never blurred,
-- because the link was pasted and the form submitted straight away — keeps
-- the link and no numbers. The map plots lat/lng, so those factories are
-- simply absent from it with nothing to indicate why.
--
-- Idempotent, and it only ever writes where both columns are currently
-- null, so a pin someone placed by hand is never overwritten by a less
-- precise value from a URL.

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

    -- !3d<lat>!4d<lng> — the place itself. Preferred, because the other
    -- pair in a Google place URL (@lat,lng) is where the camera was
    -- pointing when the link was made, which in a real pasted example sat
    -- about 250 m away from the building. Close enough to look right on a
    -- map and wrong enough to send a driver to the wrong gate.
    if v_row.maps_url ~ '!3d-?[0-9.]+!4d-?[0-9.]+' then
      v_lat := (regexp_match(v_row.maps_url, '!3d(-?[0-9]+(?:\.[0-9]+)?)'))[1]::double precision;
      v_lng := (regexp_match(v_row.maps_url, '!4d(-?[0-9]+(?:\.[0-9]+)?)'))[1]::double precision;

    -- @<lat>,<lng> — the camera centre. Only when there is no place pair,
    -- which is what a dropped pin or a plain map view looks like.
    elsif v_row.maps_url ~ '@-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?' then
      v_lat := (regexp_match(v_row.maps_url, '@(-?[0-9]+(?:\.[0-9]+)?),'))[1]::double precision;
      v_lng := (regexp_match(v_row.maps_url, '@-?[0-9]+(?:\.[0-9]+)?,(-?[0-9]+(?:\.[0-9]+)?)'))[1]::double precision;

    -- ?q=<lat>,<lng> — older share format, and hand-built links.
    elsif v_row.maps_url ~ '[?&]q=-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?' then
      v_lat := (regexp_match(v_row.maps_url, '[?&]q=(-?[0-9]+(?:\.[0-9]+)?),'))[1]::double precision;
      v_lng := (regexp_match(v_row.maps_url, '[?&]q=-?[0-9]+(?:\.[0-9]+)?,(-?[0-9]+(?:\.[0-9]+)?)'))[1]::double precision;
    end if;

    -- A short share link (maps.app.goo.gl/…) carries no coordinates at all
    -- and can only be resolved by following its redirect, which the
    -- database cannot do. Those are counted and reported rather than
    -- guessed at — re-saving the factory in the app resolves them.
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
end $$;


-- ========== supabase/migrations/0049_repeat_customer_check.sql ========

-- 0049_repeat_customer_check.sql
--
-- Before an order is created, whoever is creating it is told whether this
-- phone number has ordered before — and if so, that this is order number N
-- for that customer.
--
-- The count is deliberately across EVERY creator: the website, Messenger
-- orders taken by a manager or moderator, and field orders a driver opened
-- in the street. A repeat customer is a repeat customer regardless of who
-- happened to answer the phone, and a count scoped to the current user
-- would quietly report "first order" to a driver about a customer the
-- office has served five times.
--
-- Two separate things this makes visible, both invisible today:
--   * a returning customer, which is worth knowing while they are still on
--     the line (and is the number the person creating the order is asked to
--     confirm);
--   * the same customer already having an OPEN order — usually a second
--     entry of the same job by someone who did not know it was already in,
--     which until now only surfaced when two drivers turned up.

-- ── matching rule ───────────────────────────────────────────────────────
--
-- The last 8 digits of the digits-only number, which is exactly what
-- track_order() has matched on since migration 0009. Reused rather than
-- invented so that "this customer's orders" means the same thing here as
-- it does on the public tracking page — a second, stricter rule would
-- produce a count that disagrees with what the customer themselves can see.
--
-- It also absorbs the ways one Egyptian number gets written: 01012345678,
-- +201012345678, 0020 10 1234 5678 and 010-1234-5678 all reduce to the
-- same 8 digits, so a returning customer is still recognised when the
-- number was typed differently the first time.
--
-- Written out here rather than wrapped in a helper function on purpose: an
-- index expression that calls a user-defined function is silently
-- invalidated by a later CREATE OR REPLACE of that function, and this
-- expression has to stay in step with the index below to be used by it.

-- The existing orders_customer_phone_idx is a plain btree on the raw text,
-- which no query in this system can use: nothing looks a customer up by an
-- exact, character-for-character phone string (search goes through the
-- trigram index orders_search_idx; tracking and this new function both go
-- through the last-8-digits expression). It is replaced rather than added
-- to, so the number of indexes paid for on every insert does not grow —
-- and the lookups that do happen stop being sequential scans.
create index if not exists orders_customer_phone_last8_idx
  on public.orders (right(regexp_replace(customer_phone, '\D', '', 'g'), 8));

drop index if exists public.orders_customer_phone_idx;

-- ── the lookup ──────────────────────────────────────────────────────────
--
-- SECURITY DEFINER because it has to see every order on that number,
-- including ones RLS hides from the caller — a driver can normally only
-- read their own orders, so a plain select would make them see "first
-- order" for a customer the office has served. That is the entire point of
-- the function, so the aggregate is computed with RLS bypassed and what
-- comes back is kept to aggregates plus the one most recent order:
-- quantities, dates, a status and the names the number has been saved
-- under. No addresses, no notes, no codes, no other order's details.
--
-- Returns exactly one row, always — zero counts for a number that has
-- never ordered. `returns table` (a set) rather than a composite scalar for
-- the reason migration 0017 switched track_order over: a composite NULL
-- reaches supabase-js as an object of all-null fields, which client code
-- mistakes for a real answer, whereas a set is always a plain array.
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

  -- Staff and drivers only. Never granted to anon, and not readable by one:
  -- answering "how many orders does this number have" for any number handed
  -- in is a membership oracle over the customer list, so it stays behind a
  -- login. The public order form therefore does not get this check — the
  -- person filling that in is the customer, who knows their own history.
  if v_role is null or not v_active then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if v_role not in ('owner', 'moderator', 'driver') then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  -- Too short to identify anybody. Returning zeros rather than raising
  -- keeps the caller simple: the form looks this up while the number is
  -- still being typed, and a half-entered number is not an error.
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
      -- "Open" is every non-terminal status, matching TERMINAL_STATUSES in
      -- src/lib/domain/order-status.ts. This is the number that matters
      -- most: a customer with an order already in flight is the duplicate
      -- case, not just a returning one.
      (select count(*) from matched m where m.status not in ('delivered', 'refused', 'cancelled')),
      (select count(*) from matched m where m.status = 'delivered'),
      (select count(*) from matched m where m.status = 'cancelled'),
      (select count(*) from matched m where m.status = 'refused'),
      (select l.order_number from latest l),
      (select l.created_at from latest l),
      (select l.status from latest l),
      -- The names this number has been saved under, most recent first.
      -- Shown so a mistyped phone number is caught: if the number belongs
      -- to someone else entirely, the name coming back is the giveaway, and
      -- otherwise it confirms it really is the same customer. Capped at
      -- five because it is a reassurance line, not a report.
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


-- ========== supabase/migrations/0050_order_customer_context.sql =======

-- 0050_order_customer_context.sql
--
-- The repeat-customer count, for an order that already exists.
--
-- Migration 0049 answers "has this number ordered before" while an order is
-- being created. This answers the different question a manager or moderator
-- asks when they open an order someone else created — above all a driver's
-- field order, which reaches a driver with nobody approving it, so looking
-- at it afterwards is the only control there is.
--
-- REQUIRES 0049 to have been applied (it relies on the last-8-digits index
-- that migration creates; it still works without it, just by scanning).
--
-- WHY THIS IS NOT customer_order_history() WITH THE ORDER'S PHONE
--
-- "Order number 3 for this customer" has to mean this order's own position
-- in that customer's sequence, counted at the time it was created. Feeding
-- the phone to 0049's function and adding one would instead answer "how
-- many has this customer had in total, plus one", so an order would be
-- labelled 3 today and 5 next month without anything about it changing —
-- and the oldest order in a customer's history would show the highest
-- number. The index below is counted against this order's own position, so
-- it is fixed the moment the order exists and never moves.
--
-- Ordered by (created_at, order_number) rather than created_at alone: two
-- orders for one customer created in the same instant would otherwise each
-- count the other, and both would claim the same position. The pair is
-- unique, because order_number is.

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
  -- Owner and moderator only, which is who the order pages are for. Drivers
  -- are told about a repeat customer at creation time instead (0049), on the
  -- form, where it can still change what they do.
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if v_order is null then
    return; -- zero rows; the page shows nothing rather than erroring
  end if;

  v_key := right(regexp_replace(v_order.customer_phone, '\D', '', 'g'), 8);
  if length(v_key) < 8 then
    return; -- a number too short to identify anybody
  end if;

  return query
    with matched as (
      select o.id, o.order_number, o.created_at, o.status
        from public.orders o
       where right(regexp_replace(o.customer_phone, '\D', '', 'g'), 8) = v_key
    ),
    -- The one immediately before this order, so the page can link straight
    -- to it. This is what someone checking "is this a duplicate?" opens
    -- next, and making them search for it by phone is the slow version of
    -- the same thing.
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
      -- Open orders OTHER than this one. Excluding it matters: an order
      -- being looked at is itself usually open, and counting it would make
      -- every single order look like it had a duplicate.
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


-- ========== supabase/migrations/0051_fail_closed_role_guards.sql ======

-- 0051_fail_closed_role_guards.sql
--
-- Two holes in the authorization helpers that every other check in this
-- schema is built on. Both are closed here, in three function bodies,
-- rather than in the 49 places that call them.
--
-- APPLY THIS TO SUPABASE AS WELL AS NEON. It is a security fix, not a
-- migration artifact, and it changes nothing for a legitimate signed-in
-- user.
--
--
-- HOLE 1: `if not is_owner_or_moderator() then raise` DOES NOT RAISE FOR AN
-- UNAUTHENTICATED CALLER
--
-- is_owner_or_moderator() is `current_user_role() in ('owner','moderator')`.
-- With no session, auth.uid() is NULL, the subselect returns no row,
-- current_user_role() is NULL, and `NULL in (...)` is NULL — not false.
-- Then `not NULL` is NULL, and a plpgsql `if` on NULL takes neither branch.
-- The guard is skipped and the function body runs.
--
-- Measured on a replayed copy of this schema, as a non-superuser with no
-- identity set: orders_by_source_report(), dashboard_stats() and —
-- worst — get_order_delivery_codes() all ran and returned. That last one
-- hands out the codes a driver must quote to collect and to deliver.
--
-- 30 guards call is_owner_or_moderator() and 19 call is_owner(). All 49 had
-- this shape.
--
-- On Supabase this is currently masked: these functions are granted to
-- `authenticated` only, so an anonymous PostgREST request arrives as `anon`
-- and cannot execute them at all. The mask is real but it is one stray
-- grant away from failing, and it is the only thing standing there — the
-- function's own check contributes nothing. On a single-application-role
-- database (the Neon setup, where every request connects as app_user) the
-- mask does not exist and the hole is wide open.
--
-- The fix is to make the two boolean helpers return false rather than NULL.
-- Every one of the 49 guards then behaves as it was plainly written to.
--
--
-- HOLE 2: A DEACTIVATED ACCOUNT KEEPS FULL DATABASE AUTHORITY
--
-- current_user_role() reads the role with no regard for is_active, so
-- is_owner() stays true for a manager who has been switched off. The
-- application redirects them at the proxy, which is why this has never been
-- visible, but the database — the layer that is supposed to be the real
-- boundary — still answers yes.
--
-- That gap widens under a stateless session cookie, where deactivation
-- takes effect at the next cookie refresh rather than the next request. A
-- deactivated manager holding a live cookie would keep approving
-- distribution and reading delivery codes until it expired.
--
-- is_active is now part of the answer. A deactivated account resolves to
-- NULL — no role at all — which, with hole 1 closed, means every guard
-- refuses it.

-- ── the caller's role, only while their account is live ─────────────────

create or replace function public.current_user_role()
returns public.user_role
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles
   where id = auth.uid()
     -- Deactivating an account now removes its authority at the database,
     -- not only in the UI. Functions that need to distinguish "no such
     -- profile" from "switched off" read profiles directly and already do
     -- (see driver_create_field_order, which checks both explicitly).
     and is_active;
$$;

-- ── the two booleans every guard in the schema negates ──────────────────
--
-- coalesce is the whole fix. `select … in (…)` over zero rows is NULL, and
-- a NULL here is what let 49 guards fall open. These must answer false, not
-- "unknown", because every caller treats them as a yes/no decision.

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

-- Grants are unchanged from 0002; restated because CREATE OR REPLACE on a
-- function keeps its ACL, and being explicit here means this file can be
-- read on its own without having to go and check.
revoke all on function public.current_user_role() from public;
revoke all on function public.is_owner() from public;
revoke all on function public.is_owner_or_moderator() from public;

do $$
begin
  -- Supabase's PostgREST roles. Skipped on a database that does not have
  -- them, so this one file applies to both.
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
end $$;

-- ── prove it, here, at apply time ───────────────────────────────────────
--
-- Not a test file somewhere else: this asserts the fix took, in the
-- transaction that applies it, against the database it is being applied to.
-- If a future edit reintroduces a NULL, this migration refuses to apply.
do $$
declare
  v_role_before public.user_role;
begin
  -- auth.uid() is NULL in this session: a migration runs with no app
  -- identity, which is exactly the unauthenticated case.
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

  -- The actual thing that was broken: the guard shape used 49 times.
  if not public.is_owner_or_moderator() then
    raise notice 'verified: the `if not is_owner_or_moderator()` guard now fires with no session';
  else
    raise exception
      'The guard still does not fire with no session. All 49 authorization '
      'checks in this schema remain open. Refusing to apply.';
  end if;
end $$;
