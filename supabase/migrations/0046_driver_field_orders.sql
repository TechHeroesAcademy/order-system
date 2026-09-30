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
