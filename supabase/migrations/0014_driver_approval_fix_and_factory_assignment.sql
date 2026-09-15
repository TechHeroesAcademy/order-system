-- 0014_driver_approval_fix_and_factory_assignment.sql
-- Two fixes, both from the same round of bug reports:
--
--   1) "I assigned the driver and nothing appears on his page" — root cause
--      confirmed by direct reproduction: reassign_order_driver() (the RPC
--      behind the "تعيين مندوب" / ChangeDriverButton control) sets
--      assigned_driver_id but never sets distribution_approved_at. The
--      orders_select_driver RLS policy (0008) requires
--      distribution_approved_at IS NOT NULL before a driver can see ANY
--      order, even one directly assigned to them — so an order assigned
--      this way was permanently invisible to that driver, with no
--      self-service recovery (approve_distribution, the only other RPC that
--      sets that column, is Owner-only and only reachable from the
--      suggest -> approve flow, not this one). Fix: reassign_order_driver
--      now also stamps distribution_approved_at (if not already set) and
--      advances a still-'new' order to 'assigned', exactly like
--      approve_distribution does — direct assignment is just a shortcut
--      through the same two steps, so it should leave the order in the same
--      state. Also fixes a smaller side effect of the same gap: the newly
--      assigned driver was never notified when the order was still 'new'
--      (skipped on purpose because the order wasn't visible to them yet) —
--      now that it's always visible immediately, always notify.
--
--   2) "I need to assign the factory when create the order" — multiple
--      factory accounts are already a normal, supported staff role (see
--      team-manager.tsx's role options), so this adds the same kind of
--      per-order routing that already exists for drivers: an optional
--      assigned_factory_id on the order, settable at creation, which
--      narrows that order's visibility on the factory dashboard to the
--      chosen factory account (an order left unassigned stays visible to
--      every factory account, same as today).

-- ---------- 1) fix reassign_order_driver ----------

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
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
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

  -- A direct assignment must make the order visible to the driver right
  -- away, so it always carries the same "approval" step that the
  -- suggest -> approve flow would otherwise require separately.
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

  -- Previously skipped for a brand-new order because it wasn't visible to
  -- the driver yet — now it always is, so always notify.
  perform public.notify_user(p_new_driver_id, p_order_id, 'order_assigned',
    'تم إسناد أوردر إليك ' || v_order.order_number, 'العميل: ' || v_order.customer_name);
end;
$$;

-- ---------- 2) factory assignment ----------

alter table public.orders add column if not exists assigned_factory_id uuid references public.profiles (id);
create index if not exists orders_factory_idx on public.orders (assigned_factory_id);

comment on column public.orders.assigned_factory_id is
  'Optional: which factory account this order is routed to, set at creation. NULL means unassigned — visible to every factory account, same as before this column existed.';

-- create_order_internal gains an optional p_factory_id. A new trailing
-- parameter changes the function's argument-type signature, and Postgres
-- treats a changed signature as a distinct function rather than something
-- CREATE OR REPLACE can update in place — it would silently leave the old
-- 9/11-arg versions in the catalog alongside the new ones (and then every
-- call site becomes ambiguous, "is not unique"). Drop the old signatures
-- first so each function has exactly one, current version.
drop function if exists public.create_order_internal(text, text, text, uuid, integer, text, text, text, text, order_source, uuid);
drop function if exists public.public_create_order(text, text, text, uuid, integer, text, text, text, text);
drop function if exists public.moderator_create_order(text, text, text, uuid, integer, text, text, text, text);

-- Validated the same way p_region_id's driver-equivalent would be (must be
-- an active factory account).
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
  p_factory_id uuid default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := public.generate_delivery_code();
  v_order public.orders;
  v_result public.new_order_result;
  v_factory public.profiles;
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

  insert into public.orders (
    customer_name, customer_phone, customer_address, region_id,
    pieces_count, piece_details, color, work_required, customer_notes,
    source, created_by, delivery_code_hash, assigned_factory_id
  ) values (
    trim(p_customer_name), trim(p_customer_phone), trim(p_customer_address), p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    p_source, p_created_by, crypt(v_code, gen_salt('bf')), p_factory_id
  )
  returning * into v_order;

  perform public.log_order_event(v_order.id, 'created', null, 'new',
    'تم إنشاء الأوردر عبر ' || case when p_source = 'website' then 'الموقع' else 'Messenger' end);

  perform public.notify_role('owner', v_order.id, 'new_order', 'أوردر جديد ' || v_order.order_number,
    'تم استلام أوردر جديد من ' || v_order.customer_name);

  v_result.order_id := v_order.id;
  v_result.order_number := v_order.order_number;
  v_result.delivery_code := v_code;
  return v_result;
end;
$$;

-- The DROP above removed the old function object along with whatever
-- privileges 0007 had granted on it — CREATE OR REPLACE only updates an
-- existing object's body, it doesn't restore grants on one it just
-- recreated after a drop. Re-apply the same lockdown 0007 originally set:
-- this function trusts its caller completely, so it must stay unreachable
-- except through the two vetted wrappers below.
revoke all on function public.create_order_internal from public, anon, authenticated;

create or replace function public.public_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null,
  p_factory_id uuid default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'website', null, p_factory_id
  );
end;
$$;

revoke all on function public.public_create_order from public;
grant execute on function public.public_create_order to anon, authenticated;

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
  p_factory_id uuid default null
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

  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'messenger', auth.uid(), p_factory_id
  );
end;
$$;

revoke all on function public.moderator_create_order from public;
grant execute on function public.moderator_create_order to authenticated;

-- RLS: an order with a factory assigned is only visible to that factory
-- account (owner/moderator are unaffected — orders_select_staff already
-- gives them full access); an unassigned order stays visible to every
-- factory account, same as before this column existed.
drop policy if exists orders_select_factory on public.orders;
create policy orders_select_factory on public.orders
  for select using (
    public.current_user_role() = 'factory'
    and status in ('collected', 'at_factory', 'ready')
    and (assigned_factory_id is null or assigned_factory_id = auth.uid())
  );

drop policy if exists order_history_select_factory on public.order_history;
create policy order_history_select_factory on public.order_history
  for select using (
    public.current_user_role() = 'factory'
    and exists (
      select 1 from public.orders o
      where o.id = order_history.order_id
        and o.status in ('collected', 'at_factory', 'ready')
        and (o.assigned_factory_id is null or o.assigned_factory_id = auth.uid())
    )
  );

-- factory_orders_view has security_invoker = false and does its own
-- authorization in its WHERE clause instead of relying on the orders RLS
-- above (that's what every factory-role read actually goes through — see
-- listFactoryOrders/getFactoryOrderByNumber) — so the same per-factory
-- filter has to be applied here directly too, alongside the new columns
-- for display. Dropped and recreated rather than CREATE OR REPLACE because
-- the new columns land in the middle of the column list, and Postgres
-- refuses to change an existing view's column order/names in place.
drop view if exists public.factory_orders_view;

create view public.factory_orders_view
with (security_invoker = false) as
select
  o.id,
  o.order_number,
  o.status,
  o.pieces_count,
  o.piece_details,
  o.color,
  o.work_required,
  o.assigned_driver_id,
  p.full_name as assigned_driver_name,
  o.assigned_factory_id,
  f.full_name as assigned_factory_name,
  o.collected_at,
  o.factory_received_at,
  o.factory_ready_at,
  o.created_at
from public.orders o
left join public.profiles p on p.id = o.assigned_driver_id
left join public.profiles f on f.id = o.assigned_factory_id
where o.status in ('collected', 'at_factory', 'ready')
  and (
    public.current_user_role() in ('owner', 'moderator')
    or (
      public.current_user_role() = 'factory'
      and (o.assigned_factory_id is null or o.assigned_factory_id = auth.uid())
    )
  );

grant select on public.factory_orders_view to authenticated;
