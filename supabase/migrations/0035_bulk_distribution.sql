-- 0035_bulk_distribution.sql
--
-- Approving distribution one order at a time, from inside each order's own
-- page, is the slowest thing a manager does. This adds set-based versions so
-- a whole area's worth of orders can be moved to a driver and approved in one
-- press, without changing what approving an order means.
--
-- Structure follows the create_order_internal pattern already used in
-- 0007/0014: the real work is extracted into an internal function, and both
-- the single-order RPC and the bulk RPC call it. That's what guarantees the
-- bulk path writes the same history event and sends the same notification as
-- the single path — there is no second copy of the logic to drift.

-- ── approve: the extracted body ─────────────────────────────────────────
-- Identical to the 0009 approve_distribution body with only the is_owner()
-- check lifted out to the callers. Internal: never granted to a client role.
create or replace function public.approve_distribution_one(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then
    raise exception 'الأوردر غير موجود';
  end if;
  if v_order.status <> 'new' then
    raise exception 'الأوردر ليس في حالة تسمح باعتماد التوزيع';
  end if;
  if v_order.assigned_driver_id is null then
    raise exception 'لا يوجد مندوب محدد لهذا الأوردر';
  end if;

  update public.orders
    set status = 'assigned',
        distribution_approved_at = now(),
        distribution_approved_by = auth.uid()
    where id = p_order_id;

  perform public.log_order_event(p_order_id, 'distribution_approved', 'new', 'assigned', 'تم اعتماد التوزيع وإرسال الأوردر للمندوب');
  perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'order_assigned',
    'أوردر جديد تم إسناده إليك ' || v_order.order_number,
    'العميل: ' || v_order.customer_name);
end;
$$;

create or replace function public.approve_distribution(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner() then
    raise exception 'اعتماد التوزيع من صلاحية المدير فقط' using errcode = '42501';
  end if;
  perform public.approve_distribution_one(p_order_id);
end;
$$;

-- ── approve: the bulk version ───────────────────────────────────────────
-- Returns a row per requested order rather than failing the whole call, so
-- one order that someone else already approved (or that has no driver yet)
-- doesn't throw away the other nineteen.
--
-- The begin/exception block around each order is what makes that work: a
-- plpgsql block with an EXCEPTION clause opens an implicit subtransaction, so
-- a failure rolls back only that order's update, history row and
-- notification, and the loop carries on.
--
-- ORDER BY is load-bearing, not tidiness. A bulk call holds row locks for
-- every order it touches until it commits, so two managers approving
-- overlapping selections in different on-screen orders would deadlock. Taking
-- the locks in a deterministic order means one simply waits for the other.
create or replace function public.approve_distribution_bulk(p_order_ids uuid[])
returns table (order_id uuid, order_number text, succeeded boolean, error text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not public.is_owner() then
    raise exception 'اعتماد التوزيع من صلاحية المدير فقط' using errcode = '42501';
  end if;
  if coalesce(array_length(p_order_ids, 1), 0) = 0 then
    return;
  end if;
  -- Bounded so one press can't hold hundreds of row locks on a live system.
  if array_length(p_order_ids, 1) > 200 then
    raise exception 'لا يمكن اعتماد أكثر من 200 أوردر في المرة الواحدة' using errcode = '22023';
  end if;

  for v_id in select distinct u from unnest(p_order_ids) u order by 1 loop
    order_id := v_id;
    select o.order_number into order_number from public.orders o where o.id = v_id;

    begin
      perform public.approve_distribution_one(v_id);
      succeeded := true;
      error := null;
    exception when others then
      succeeded := false;
      error := sqlerrm;
    end;

    return next;
  end loop;
end;
$$;

-- ── assign a driver: the same split ─────────────────────────────────────
-- Used by the bulk screen's "move the selected orders to this driver" before
-- approving. set_order_distribution (rather than reassign_order_driver) is
-- the right primitive here: the screen only ever shows orders still waiting
-- for approval, and this leaves them waiting.
create or replace function public.set_order_distribution_one(
  p_order_id uuid,
  p_driver_id uuid,
  p_is_suggestion boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status order_status;
begin
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

create or replace function public.set_order_distribution(p_order_id uuid, p_driver_id uuid, p_is_suggestion boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner() then
    raise exception 'تحديد المندوب من صلاحية المدير فقط' using errcode = '42501';
  end if;
  perform public.set_order_distribution_one(p_order_id, p_driver_id, p_is_suggestion);
end;
$$;

create or replace function public.set_order_distribution_bulk(p_order_ids uuid[], p_driver_id uuid)
returns table (order_id uuid, order_number text, succeeded boolean, error text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_driver public.profiles;
begin
  if not public.is_owner() then
    raise exception 'تحديد المندوب من صلاحية المدير فقط' using errcode = '42501';
  end if;
  if coalesce(array_length(p_order_ids, 1), 0) = 0 then
    return;
  end if;
  if array_length(p_order_ids, 1) > 200 then
    raise exception 'لا يمكن تعديل أكثر من 200 أوردر في المرة الواحدة' using errcode = '22023';
  end if;

  -- Validated once, before touching anything: a bad driver id is a mistake
  -- about the whole selection, not a per-order outcome.
  select * into v_driver from public.profiles where id = p_driver_id;
  if v_driver is null or v_driver.role <> 'driver' or not v_driver.is_active then
    raise exception 'المندوب المحدد غير صالح' using errcode = '22023';
  end if;

  for v_id in select distinct u from unnest(p_order_ids) u order by 1 loop
    order_id := v_id;
    select o.order_number into order_number from public.orders o where o.id = v_id;

    begin
      perform public.set_order_distribution_one(v_id, p_driver_id, false);
      succeeded := true;
      error := null;
    exception when others then
      succeeded := false;
      error := sqlerrm;
    end;

    return next;
  end loop;
end;
$$;

-- ── grants ──────────────────────────────────────────────────────────────
-- The _one functions carry no authorization of their own, so they must never
-- be callable directly by a client — only through the wrappers above.
revoke all on function public.approve_distribution_one(uuid) from public, anon, authenticated;
revoke all on function public.set_order_distribution_one(uuid, uuid, boolean) from public, anon, authenticated;

revoke all on function public.approve_distribution_bulk(uuid[]) from public, anon;
revoke all on function public.set_order_distribution_bulk(uuid[], uuid) from public, anon;
grant execute on function public.approve_distribution_bulk(uuid[]) to authenticated;
grant execute on function public.set_order_distribution_bulk(uuid[], uuid) to authenticated;

-- ── "needs a driver" flag ───────────────────────────────────────────────
-- The board shows every order with no driver that isn't finished, which is a
-- derived predicate and needs no column. These two exist for the part that
-- can't be derived: WHY an order is sitting there, and how urgent it is.
--
-- An order at 'new' with no driver is routine backlog — nobody covers that
-- area yet, or a manager cleared the suggestion. An order at 'assigned' or
-- later with no driver is an orphan mid-delivery, which is impossible today
-- and only becomes reachable once removing a driver can strand their work
-- (the next migration). The flag is what tells those apart and carries the
-- reason into the notification.
--
-- Columns land here, one migration ahead of the code that sets them, so the
-- board can ship complete rather than with a half-built queue.
alter table public.orders add column if not exists needs_allocation_at timestamptz;
alter table public.orders add column if not exists needs_allocation_reason text;

create index if not exists orders_needs_allocation_idx
  on public.orders (needs_allocation_at) where needs_allocation_at is not null;

comment on column public.orders.needs_allocation_at is
  'Set when an order was left without a driver by something other than normal '
  'backlog (today: the assigned driver being removed with no one covering the '
  'area). Cleared automatically by stamp_order_assignee_names the moment a '
  'driver is assigned or the order reaches a terminal status.';

-- Clearing lives in the existing BEFORE INSERT OR UPDATE trigger rather than
-- in each RPC that can assign a driver. There are five such paths
-- (set_order_distribution, reassign_order_driver, approve_distribution,
-- create_order_internal, and a manual owner UPDATE); a flag that has to be
-- cleared by hand in each would eventually be forgotten in one, and a stale
-- "needs a driver" banner on an order that has one is worse than no banner.
-- Same signature as the 0033 version, so the trigger itself is untouched.
create or replace function public.stamp_order_assignee_names()
returns trigger
language plpgsql
as $$
begin
  if new.assigned_driver_id is not null
     and (tg_op = 'INSERT' or new.assigned_driver_id is distinct from old.assigned_driver_id) then
    select full_name into new.assigned_driver_name from public.profiles where id = new.assigned_driver_id;
  end if;

  if new.assigned_factory_id is not null
     and (tg_op = 'INSERT' or new.assigned_factory_id is distinct from old.assigned_factory_id) then
    select coalesce(f.name, new.assigned_factory_name) into new.assigned_factory_name
    from public.factories f where f.id = new.assigned_factory_id;
  end if;

  if new.assigned_driver_id is not null and (tg_op = 'INSERT' or old.assigned_driver_id is null) then
    new.needs_allocation_at := null;
    new.needs_allocation_reason := null;
  end if;

  if new.status in ('delivered', 'cancelled', 'refused') then
    new.needs_allocation_at := null;
    new.needs_allocation_reason := null;
  end if;

  return new;
end;
$$;
