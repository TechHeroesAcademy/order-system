-- 0024_pickup_code_owner_only_assignment_and_fair_auto_distribution.sql
--
-- Three requests, shipped together since the third depends on groundwork
-- the other two don't touch:
--
--   1) "code for taking the order from the customer" — a pickup
--      confirmation code, mirroring the existing delivery code exactly:
--      generated at creation, only a bcrypt hash stored, the driver must
--      get it from the customer and enter it to mark the order collected.
--      Without this, a driver could tap "collected" without ever actually
--      visiting the customer, the same gap the delivery code already closes
--      on the other end of the trip.
--
--   2) "moderator cannot assign or edit or change drivers or factories and
--      adding new worker or factory only manager who can do that" — every
--      RPC that assigns/reassigns a driver or factory on an order, and
--      every account-creation path (driver/moderator/owner/factory), moves
--      from Owner-or-Moderator to Owner-only. approve_distribution() was
--      already Owner-only (migration 0009) and needs no change.
--
--   3) "when create driver or order ask for the region and the order will
--      be assigned auto for these drivers based on the region and for
--      places with more than order try to be fair for orders and also the
--      manager should confirm the assignment for each order manually
--      before it goes to the driver" — a driver account creation already
--      asks for coverage regions (see driver_regions, 0003, and the
--      "المناطق التي يغطيها" field in AddStaffDialog), and an order already
--      asks for a region (mandatory since 0004). What's new is automatic:
--      whenever an order is created with no explicit driver, the system
--      now picks the least-busy active driver who covers that region
--      itself (self-balancing over time, since "least busy" changes as
--      orders pile up) instead of leaving it to a human to notice and pick.
--      Crucially this auto-pick is only ever a *suggestion* — it sets
--      assigned_driver_id/suggested_driver_id but deliberately leaves
--      distribution_approved_at null, so orders_select_driver (0008) keeps
--      it invisible to the driver exactly like a manually-suggested pick
--      already was. The existing <DistributionPanel> UI and
--      approve_distribution() RPC (Owner-only already) are exactly the
--      "manager confirms before it goes to the driver" gate asked for here
--      — nothing new was needed there, only feeding it automatically
--      instead of requiring a human to open suggest_drivers() first.
--      Owner creating an order directly with an explicit driver keeps
--      today's immediate-approve behavior unchanged (that action already
--      *is* the manager's confirmation).

-- ========== 1) pickup confirmation code ==========

alter table public.orders add column if not exists pickup_code_hash text;
alter table public.orders add column if not exists failed_pickup_code_attempts integer not null default 0;
alter table public.orders add column if not exists pickup_code_last_attempt_at timestamptz;

comment on column public.orders.pickup_code_hash is
  'bcrypt hash of the code the driver must get from the customer to confirm pickup (driver_mark_collected) — same protection model as delivery_code_hash, just at the other end of the trip. Null for orders created before this migration; driver_mark_collected treats a null hash as "no code was ever issued" and skips the check rather than rejecting the driver forever.';

create table if not exists public.order_pickup_codes (
  order_id uuid primary key references public.orders (id) on delete cascade,
  code text not null,
  created_at timestamptz not null default now()
);

comment on table public.order_pickup_codes is
  'Plaintext pickup codes, mirroring order_delivery_codes (0016) exactly: RLS enabled with zero policies (every direct client request denied by default), reachable only through get_order_pickup_code() below.';

alter table public.order_pickup_codes enable row level security;
revoke all on public.order_pickup_codes from public, anon, authenticated;

create or replace function public.get_order_pickup_code(p_order_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select code into v_code from public.order_pickup_codes where order_id = p_order_id;
  return v_code;
end;
$$;

revoke all on function public.get_order_pickup_code from public;
grant execute on function public.get_order_pickup_code to authenticated;

-- new_order_result gains pickup_code alongside delivery_code — ADD ATTRIBUTE
-- extends the composite type in place (unlike DROP TYPE ... CASCADE, this
-- doesn't touch any function that returns it), so create_order_internal and
-- every function that calls it keep working unchanged except for the one
-- new field this migration actually sets. Postgres has no
-- "ADD ATTRIBUTE IF NOT EXISTS" for composite types, so this is wrapped in
-- an existence check to make it safe to re-run against a database that
-- already picked up this change (this migration re-applied on top of
-- itself, or a partially-applied migration history).
do $$
begin
  if not exists (
    select 1
    from pg_attribute a
    join pg_type t on t.typrelid = a.attrelid
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public'
      and t.typname = 'new_order_result'
      and a.attname = 'pickup_code'
      and not a.attisdropped
  ) then
    alter type public.new_order_result add attribute pickup_code text;
  end if;
end $$;

-- driver_mark_collected(uuid) -> driver_mark_collected(uuid, text) and
-- void -> boolean (so the UI can tell "wrong code" apart from a hard
-- error, exactly like driver_deliver_to_customer already does) is a
-- signature AND return-type change, so the old function has to be dropped
-- first — CREATE OR REPLACE can't change a return type.
drop function if exists public.driver_mark_collected(uuid);

create or replace function public.driver_mark_collected(p_order_id uuid, p_code text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public.orders;
  v_ok boolean;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.assigned_driver_id <> auth.uid() then raise exception 'غير مصرح' using errcode = '42501'; end if;
  if v_order.status <> 'assigned' then raise exception 'الأوردر ليس بحالة تسمح بتسجيل الاستلام من العميل'; end if;

  -- Orders created before this migration never had a pickup code issued —
  -- treat that as "nothing to check" rather than permanently blocking
  -- collection on those pre-existing orders (same spirit as the delivery
  -- code reveal's "غير متاح" state for old orders, just applied to the
  -- check itself instead of a lookup).
  if v_order.pickup_code_hash is null then
    v_ok := true;
  else
    v_ok := (crypt(coalesce(p_code, ''), v_order.pickup_code_hash) = v_order.pickup_code_hash);
  end if;

  if v_ok then
    update public.orders set status = 'collected', collected_at = now() where id = p_order_id;
    perform public.log_order_event(p_order_id, 'collected_from_customer', 'assigned', 'collected', 'تم استلام الأوردر من العميل');
    perform public.notify_staff(p_order_id, 'order_collected',
      'تم استلام الأوردر ' || v_order.order_number || ' من العميل', null, auth.uid());
  else
    update public.orders
      set failed_pickup_code_attempts = failed_pickup_code_attempts + 1,
          pickup_code_last_attempt_at = now()
      where id = p_order_id;
    perform public.log_order_event(p_order_id, 'pickup_code_mismatch', 'assigned', 'assigned', 'محاولة استلام من العميل بكود غير صحيح');
  end if;

  return v_ok;
end;
$$;

revoke all on function public.driver_mark_collected(uuid, text) from public;
grant execute on function public.driver_mark_collected(uuid, text) to authenticated;

-- ========== 2) driver/factory assignment and staff creation: Owner-only ==========
--
-- Every one of these already had is_owner_or_moderator() as its authorization
-- check (see 0009, 0018, 0019) — only that one check changes to is_owner(),
-- nothing else about their bodies. Kept as separate create-or-replace blocks
-- (same signatures as their current versions) rather than a bulk find/replace
-- across files, so this migration is a readable, self-contained diff of
-- exactly what changed.

create or replace function public.set_order_distribution(p_order_id uuid, p_driver_id uuid, p_is_suggestion boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status order_status;
begin
  if not public.is_owner() then
    raise exception 'تحديد المندوب من صلاحية المدير فقط' using errcode = '42501';
  end if;

  select status into v_status from public.orders where id = p_order_id for update;
  if v_status is null then
    raise exception 'الأوردر غير موجود';
  end if;
  if v_status <> 'new' then
    raise exception 'لا يمكن تعديل توزيع أوردر تم اعتماده بالفعل';
  end if;

  update public.orders
    set assigned_driver_id = p_driver_id,
        suggested_driver_id = case when p_is_suggestion then p_driver_id else suggested_driver_id end
    where id = p_order_id;

  perform public.log_order_event(p_order_id, 'distribution_set', v_status, v_status,
    'تم تحديد مندوب للتوزيع (بانتظار الاعتماد)');
end;
$$;

create or replace function public.clear_order_distribution(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status order_status;
begin
  if not public.is_owner() then
    raise exception 'تحديد المندوب من صلاحية المدير فقط' using errcode = '42501';
  end if;

  select status into v_status from public.orders where id = p_order_id for update;
  if v_status <> 'new' then
    raise exception 'لا يمكن إلغاء توزيع أوردر تم اعتماده بالفعل';
  end if;

  update public.orders set assigned_driver_id = null where id = p_order_id;
  perform public.log_order_event(p_order_id, 'distribution_cleared', v_status, v_status, 'تم إلغاء التوزيع المقترح');
end;
$$;

create or replace function public.reassign_order_driver(p_order_id uuid, p_new_driver_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_new_driver public.profiles;
  v_old_driver_name text;
  v_new_status public.order_status;
begin
  if not public.is_owner() then
    raise exception 'تغيير المندوب من صلاحية المدير فقط' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status in ('delivered', 'cancelled', 'refused') then
    raise exception 'لا يمكن تغيير المندوب لأوردر منتهٍ';
  end if;

  select * into v_new_driver from public.profiles where id = p_new_driver_id;
  if v_new_driver is null or v_new_driver.role <> 'driver' or not v_new_driver.is_active then
    raise exception 'المندوب المحدد غير صالح';
  end if;
  if v_order.assigned_driver_id = p_new_driver_id then
    raise exception 'هذا المندوب مسؤول عن الأوردر بالفعل';
  end if;

  if v_order.assigned_driver_id is not null then
    select full_name into v_old_driver_name from public.profiles where id = v_order.assigned_driver_id;
  end if;

  v_new_status := case when v_order.status = 'new' then 'assigned' else v_order.status end;

  update public.orders
    set assigned_driver_id = p_new_driver_id,
        distribution_approved_at = coalesce(distribution_approved_at, now()),
        distribution_approved_by = coalesce(distribution_approved_by, auth.uid()),
        status = v_new_status
    where id = p_order_id;

  perform public.log_order_event(p_order_id, 'driver_reassigned', v_order.status, v_new_status,
    case when v_old_driver_name is not null
      then 'تم تغيير المندوب من ' || v_old_driver_name || ' إلى ' || v_new_driver.full_name
      else 'تم تعيين مندوب: ' || v_new_driver.full_name
    end);

  if v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'reassigned_away',
      'تم نقل الأوردر ' || v_order.order_number || ' إلى مندوب آخر', null);
  end if;

  perform public.notify_user(p_new_driver_id, p_order_id, 'order_assigned',
    'تم إسناد أوردر إليك ' || v_order.order_number, 'العميل: ' || v_order.customer_name);
  perform public.notify_staff(p_order_id, 'driver_reassigned',
    'تم تغيير مندوب الأوردر ' || v_order.order_number, null, auth.uid());
end;
$$;

create or replace function public.reassign_order_factory(p_order_id uuid, p_new_factory_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_new_factory public.profiles;
  v_old_factory_name text;
begin
  if not public.is_owner() then
    raise exception 'تغيير المصنع من صلاحية المدير فقط' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status in ('delivered', 'cancelled', 'refused') then
    raise exception 'لا يمكن تغيير المصنع لأوردر منتهٍ';
  end if;

  select * into v_new_factory from public.profiles where id = p_new_factory_id;
  if v_new_factory is null or v_new_factory.role <> 'factory' or not v_new_factory.is_active then
    raise exception 'المصنع المحدد غير صالح';
  end if;
  if v_order.assigned_factory_id = p_new_factory_id then
    raise exception 'هذا المصنع مخصص للأوردر بالفعل';
  end if;

  if v_order.assigned_factory_id is not null then
    select full_name into v_old_factory_name from public.profiles where id = v_order.assigned_factory_id;
  end if;

  update public.orders set assigned_factory_id = p_new_factory_id where id = p_order_id;

  perform public.log_order_event(p_order_id, 'factory_reassigned', v_order.status, v_order.status,
    case when v_old_factory_name is not null
      then 'تم تغيير المصنع من ' || v_old_factory_name || ' إلى ' || v_new_factory.full_name
      else 'تم تحديد المصنع: ' || v_new_factory.full_name
    end);

  if v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'factory_reassigned',
      'تم تغيير المصنع الخاص بالأوردر ' || v_order.order_number,
      'المصنع الجديد: ' || v_new_factory.full_name);
  end if;

  if v_order.status in ('collected', 'at_factory', 'ready') then
    perform public.notify_user(p_new_factory_id, p_order_id, 'order_assigned',
      'تم تخصيص أوردر لمصنعكم ' || v_order.order_number, null);
  end if;

  perform public.notify_staff(p_order_id, 'factory_reassigned',
    'تم تغيير مصنع الأوردر ' || v_order.order_number, null, auth.uid());
end;
$$;

-- ========== 3) fair, region-based auto-suggestion at order creation ==========

-- The least-busy active driver who covers p_region_id, or null if none do
-- (an order with no covering driver is left unassigned, same as it would be
-- if a human opened suggest_drivers() and found nobody to pick — it is NOT
-- assigned to an out-of-region driver just to fill the field). "Least busy"
-- is the same active_orders_count suggest_drivers() already ranks by, so
-- this is that function's own ranking, just applied automatically instead
-- of requiring a human to open the panel first — and because it's evaluated
-- fresh for every new order, load naturally levels out across a region's
-- drivers over time instead of always stacking onto whoever's first alphabetically.
create or replace function public.pick_fair_driver_for_region(p_region_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select p.id
  from public.profiles p
  where p.role = 'driver'
    and p.is_active
    and p_region_id is not null
    and exists (
      select 1 from public.driver_regions dr
      where dr.driver_id = p.id and dr.region_id = p_region_id
    )
  order by (
    select count(*) from public.orders o
    where o.assigned_driver_id = p.id
      and o.status not in ('delivered', 'cancelled', 'refused')
  ) asc, p.full_name asc
  limit 1;
$$;

create or replace function public.create_order_internal(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text,
  p_color text,
  p_work_required text,
  p_customer_notes text,
  p_source order_source,
  p_created_by uuid,
  p_factory_id uuid default null,
  p_driver_id uuid default null,
  p_customer_maps_url text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := public.generate_delivery_code();
  v_pickup_code text := public.generate_delivery_code();
  v_order public.orders;
  v_result public.new_order_result;
  v_factory public.profiles;
  v_driver public.profiles;
  v_new_status public.order_status;
  v_maps_url text := nullif(trim(coalesce(p_customer_maps_url, '')), '');
  v_auto_driver_id uuid;
  v_auto_driver_name text;
begin
  if length(trim(p_customer_name)) = 0 then
    raise exception 'اسم العميل مطلوب' using errcode = '22023';
  end if;
  if length(trim(p_customer_phone)) < 8 then
    raise exception 'رقم هاتف العميل غير صالح' using errcode = '22023';
  end if;
  if p_pieces_count is null or p_pieces_count < 1 then
    raise exception 'عدد القطع يجب أن يكون 1 على الأقل' using errcode = '22023';
  end if;

  if p_factory_id is not null then
    select * into v_factory from public.profiles where id = p_factory_id;
    if v_factory is null or v_factory.role <> 'factory' or not v_factory.is_active then
      raise exception 'المصنع المحدد غير صالح' using errcode = '22023';
    end if;
  end if;

  if p_driver_id is not null then
    select * into v_driver from public.profiles where id = p_driver_id;
    if v_driver is null or v_driver.role <> 'driver' or not v_driver.is_active then
      raise exception 'المندوب المحدد غير صالح' using errcode = '22023';
    end if;
  end if;

  insert into public.orders (
    customer_name, customer_phone, customer_address, customer_maps_url, region_id,
    pieces_count, piece_details, color, work_required, customer_notes,
    source, created_by, delivery_code_hash, pickup_code_hash, assigned_factory_id
  ) values (
    trim(p_customer_name), trim(p_customer_phone), trim(p_customer_address), v_maps_url, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    p_source, p_created_by, crypt(v_code, gen_salt('bf')), crypt(v_pickup_code, gen_salt('bf')), p_factory_id
  )
  returning * into v_order;

  insert into public.order_delivery_codes (order_id, code) values (v_order.id, v_code);
  insert into public.order_pickup_codes (order_id, code) values (v_order.id, v_pickup_code);

  perform public.log_order_event(v_order.id, 'created', null, 'new',
    'تم إنشاء الأوردر عبر ' || case when p_source = 'website' then 'الموقع' else 'Messenger' end);

  if p_driver_id is not null then
    -- Explicit driver given by the caller (an Owner creating an order
    -- directly) — same immediate-approve behavior as before this
    -- migration; the Owner's own pick already *is* the manager's
    -- confirmation, so there's nothing left to approve separately.
    v_new_status := case when v_order.status = 'new' then 'assigned' else v_order.status end;

    update public.orders
      set assigned_driver_id = p_driver_id,
          distribution_approved_at = now(),
          distribution_approved_by = p_created_by,
          status = v_new_status
      where id = v_order.id;

    v_order.status := v_new_status;

    perform public.log_order_event(v_order.id, 'driver_reassigned', 'new', v_new_status,
      'تم تعيين مندوب عند إنشاء الأوردر: ' || v_driver.full_name);

    perform public.notify_user(p_driver_id, v_order.id, 'order_assigned',
      'تم إسناد أوردر إليك ' || v_order.order_number, 'العميل: ' || v_order.customer_name);
  else
    -- No driver given — try to fairly auto-suggest one from the order's own
    -- region. This only ever sets a *pending* suggestion (assigned_driver_id
    -- + suggested_driver_id, status stays 'new', distribution_approved_at
    -- stays null) — orders_select_driver (0008) keeps it invisible to the
    -- driver until an Owner calls approve_distribution(), exactly the
    -- "manager confirms before it reaches the driver" requirement. If no
    -- active driver covers this region, the order is simply left unassigned,
    -- same as it always was — an Owner can still pick manually from
    -- <DistributionPanel> (suggest_drivers() ranks every active driver, not
    -- just ones covering the region, as a fallback).
    v_auto_driver_id := public.pick_fair_driver_for_region(p_region_id);
    if v_auto_driver_id is not null then
      update public.orders
        set assigned_driver_id = v_auto_driver_id,
            suggested_driver_id = v_auto_driver_id
        where id = v_order.id;

      select full_name into v_auto_driver_name from public.profiles where id = v_auto_driver_id;
      perform public.log_order_event(v_order.id, 'distribution_set', 'new', 'new',
        'تم اقتراح مندوب تلقائيًا حسب المنطقة: ' || v_auto_driver_name || ' (بانتظار اعتماد المدير)');
    end if;
  end if;

  perform public.notify_role('owner', v_order.id, 'new_order', 'أوردر جديد ' || v_order.order_number,
    'تم استلام أوردر جديد من ' || v_order.customer_name);

  v_result.order_id := v_order.id;
  v_result.order_number := v_order.order_number;
  v_result.delivery_code := v_code;
  v_result.pickup_code := v_pickup_code;
  return v_result;
end;
$$;

revoke all on function public.create_order_internal from public, anon, authenticated;

create or replace function public.moderator_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null,
  p_factory_id uuid default null,
  p_driver_id uuid default null,
  p_customer_maps_url text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح لك بإنشاء أوردر' using errcode = '42501';
  end if;

  -- A Moderator can create the order itself, but picking who handles it is
  -- the manager's job now (see this migration's header) — the frontend
  -- already never shows these fields to a Moderator, this is the
  -- server-side half of that same rule (defense in depth, same pattern as
  -- every other role check in this file).
  if not public.is_owner() and (p_driver_id is not null or p_factory_id is not null) then
    raise exception 'تحديد المندوب أو المصنع من صلاحية المدير فقط' using errcode = '42501';
  end if;

  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'messenger', auth.uid(), p_factory_id, p_driver_id, p_customer_maps_url
  );
end;
$$;

revoke all on function public.moderator_create_order from public;
grant execute on function public.moderator_create_order to authenticated;
