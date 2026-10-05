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

revoke all on function public.approve_distribution_one(uuid) from public, anon, authenticated;
revoke all on function public.set_order_distribution_one(uuid, uuid, boolean) from public, anon, authenticated;

revoke all on function public.approve_distribution_bulk(uuid[]) from public, anon;
revoke all on function public.set_order_distribution_bulk(uuid[], uuid) from public, anon;
grant execute on function public.approve_distribution_bulk(uuid[]) to authenticated;
grant execute on function public.set_order_distribution_bulk(uuid[], uuid) to authenticated;

alter table public.orders add column if not exists needs_allocation_at timestamptz;
alter table public.orders add column if not exists needs_allocation_reason text;

create index if not exists orders_needs_allocation_idx
  on public.orders (needs_allocation_at) where needs_allocation_at is not null;

comment on column public.orders.needs_allocation_at is
  'Set when an order was left without a driver by something other than normal '
  'backlog (today: the assigned driver being removed with no one covering the '
  'area). Cleared automatically by stamp_order_assignee_names the moment a '
  'driver is assigned or the order reaches a terminal status.';

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
