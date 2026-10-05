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
