-- 0036_driver_removal_reassignment.sql
--
-- Removing a driver used to silently strand their work. The foreign keys are
-- ON DELETE SET NULL, so every order they were carrying simply lost its
-- driver — no status change, no reassignment, no notification, nothing on any
-- screen to say it had happened. An order mid-delivery would just sit there
-- belonging to nobody.
--
-- Now their active orders move to another driver covering the same area, and
-- anything nobody covers is flagged and reported so a manager can place it.

-- ── successor picker ────────────────────────────────────────────────────
-- Same ranking as pick_fair_driver_for_region (0024) — fewest active orders,
-- then name — with the departing driver excluded.
--
-- A new name rather than a defaulted extra parameter on the existing
-- function: CREATE OR REPLACE with a changed argument list creates a second
-- overload instead of replacing, which this codebase has already been caught
-- by twice (0014's create_order_internal, and the note in 0029 about
-- can_read_order_channel).
create or replace function public.pick_fair_driver_for_region_excluding(
  p_region_id uuid,
  p_exclude_driver_id uuid
)
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
    and (p_exclude_driver_id is null or p.id <> p_exclude_driver_id)
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

-- ── move a departing driver's work ──────────────────────────────────────
-- Returns a row per order it touched so the caller can tell the manager what
-- actually happened, synchronously, instead of leaving them to discover it.
create or replace function public.reassign_orders_from_driver(p_driver_id uuid)
returns table (
  order_id uuid,
  order_number text,
  order_status public.order_status,
  new_driver_id uuid,
  new_driver_name text,
  outcome text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_driver public.profiles;
  v_fallback_regions uuid[];
  v_order record;
  v_successor uuid;
  v_region uuid;
  v_unallocated_ids uuid[] := array[]::uuid[];
  v_unallocated_numbers text[] := array[]::text[];
  v_idx integer;
begin
  if not public.is_owner() then
    raise exception 'حذف المندوب من صلاحية المدير فقط' using errcode = '42501';
  end if;

  select * into v_driver from public.profiles where id = p_driver_id;
  if v_driver is null then raise exception 'المندوب غير موجود'; end if;
  if v_driver.role <> 'driver' then raise exception 'هذا الحساب ليس مندوبًا'; end if;

  -- FIRST, before anything else touches this driver: snapshot the areas they
  -- cover. driver_regions is ON DELETE CASCADE, so the moment the profile row
  -- goes those rows are gone and there is no way to recover what this driver
  -- covered. It's also the only sensible basis for placing an order whose own
  -- region_id is null (nullable since 0004).
  v_fallback_regions := array(
    select dr.region_id from public.driver_regions dr where dr.driver_id = p_driver_id
  );

  for v_order in
    select o.id, o.order_number, o.status, o.region_id
    from public.orders o
    where o.assigned_driver_id = p_driver_id
      and o.status not in ('delivered', 'cancelled', 'refused')
    order by o.id
    for update
  loop
    -- The order's own area first, then anywhere the departing driver covered.
    v_successor := public.pick_fair_driver_for_region_excluding(v_order.region_id, p_driver_id);

    if v_successor is null then
      foreach v_region in array coalesce(v_fallback_regions, array[]::uuid[]) loop
        v_successor := public.pick_fair_driver_for_region_excluding(v_region, p_driver_id);
        exit when v_successor is not null;
      end loop;
    end if;

    order_id := v_order.id;
    order_number := v_order.order_number;
    order_status := v_order.status;

    if v_successor is null then
      update public.orders
         set assigned_driver_id = null,
             needs_allocation_at = now(),
             needs_allocation_reason = 'تم حذف المندوب ولا يوجد مندوب بديل يغطي المنطقة'
       where id = v_order.id;

      perform public.log_order_event(v_order.id, 'driver_unassigned', v_order.status, v_order.status,
        'تم حذف المندوب ولا يوجد بديل يغطي المنطقة — الأوردر بحاجة لتعيين مندوب');

      v_unallocated_ids := v_unallocated_ids || v_order.id;
      v_unallocated_numbers := v_unallocated_numbers || v_order.order_number;
      new_driver_id := null;
      new_driver_name := null;
      outcome := 'unallocated';

    elsif v_order.status = 'new' then
      -- Still waiting for approval, so the driver was only ever a suggestion
      -- and the order was never visible to them (orders_select_driver
      -- requires distribution_approved_at). Re-suggest and leave it pending:
      -- promoting it here would hand an order to a driver no manager ever
      -- confirmed, which is exactly what the approval step exists to prevent.
      update public.orders
         set assigned_driver_id = v_successor,
             suggested_driver_id = v_successor
       where id = v_order.id;

      perform public.log_order_event(v_order.id, 'distribution_set', v_order.status, v_order.status,
        'تم اقتراح مندوب بديل بعد حذف المندوب السابق (بانتظار اعتماد المدير)');

      new_driver_id := v_successor;
      select full_name into new_driver_name from public.profiles where id = v_successor;
      outcome := 'resuggested';

    else
      -- Already approved and in motion: hand it over as a real reassignment,
      -- leaving status and the original approval timestamp untouched.
      update public.orders set assigned_driver_id = v_successor where id = v_order.id;

      select full_name into new_driver_name from public.profiles where id = v_successor;

      perform public.log_order_event(v_order.id, 'driver_reassigned', v_order.status, v_order.status,
        'تم نقل الأوردر إلى ' || coalesce(new_driver_name, 'مندوب آخر') || ' بعد حذف المندوب السابق');

      perform public.notify_user(v_successor, v_order.id, 'order_assigned',
        'تم نقل أوردر إليك ' || v_order.order_number,
        'بعد حذف المندوب السابق');

      new_driver_id := v_successor;
      outcome := 'reassigned';
    end if;

    return next;
  end loop;

  -- Tell the other managers about anything left unplaced. Deliberately
  -- driven by the ids collected in the loop above rather than by re-querying
  -- for flagged orders: orders flagged by an earlier removal and still
  -- unplaced would otherwise be re-announced every time any driver is
  -- deleted, training everyone to ignore the alert.
  --
  -- Per order so the notification opens the right one — unless there are a
  -- lot, in which case one summary is more use than forty separate alerts
  -- (notifications.order_id is nullable and the bell already handles that).
  --
  -- notify_staff excludes the actor, which is right here: the manager doing
  -- the deletion is told synchronously by the action's own summary.
  if array_length(v_unallocated_ids, 1) between 1 and 10 then
    for v_idx in 1 .. array_length(v_unallocated_ids, 1) loop
      perform public.notify_staff(v_unallocated_ids[v_idx], 'needs_allocation',
        'الأوردر ' || v_unallocated_numbers[v_idx] || ' يحتاج تعيين مندوب',
        'تم حذف المندوب ولا يوجد بديل يغطي المنطقة', auth.uid());
    end loop;
  elsif coalesce(array_length(v_unallocated_ids, 1), 0) > 10 then
    perform public.notify_staff(null, 'needs_allocation',
      array_length(v_unallocated_ids, 1) || ' أوردر بحاجة لتعيين مندوب',
      'تم حذف مندوب ولا يوجد بديل يغطي مناطقه', auth.uid());
  end if;
end;
$$;

revoke all on function public.pick_fair_driver_for_region_excluding(uuid, uuid) from public, anon;
revoke all on function public.reassign_orders_from_driver(uuid) from public, anon;
grant execute on function public.reassign_orders_from_driver(uuid) to authenticated;
