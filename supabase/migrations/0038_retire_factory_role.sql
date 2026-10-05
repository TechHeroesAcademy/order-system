do $$
declare
  v_remaining integer;
begin
  select count(*) into v_remaining from public.profiles where role = 'factory';
  if v_remaining > 0 then
    raise exception
      'ABORT: % factory account(s) still exist. Delete them first '
      '(delete from public.profiles where role = ''factory'';) and make sure the '
      'app build without /factory is live. Nothing has been changed.', v_remaining;
  end if;
end$$;

drop view if exists public.factory_orders_view;

drop policy if exists orders_select_factory on public.orders;
drop policy if exists order_history_select_factory on public.order_history;

drop policy if exists profiles_select_factory_for_assigned_driver on public.profiles;

drop policy if exists profiles_update_moderator on public.profiles;
create policy profiles_update_moderator on public.profiles
  for update using (public.current_user_role() = 'moderator' and role = 'driver')
  with check (public.current_user_role() = 'moderator' and role = 'driver');

create or replace function public.factory_confirm_receipt(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;

  if not (
    coalesce(public.is_owner_or_moderator(), false)
    or (public.current_user_role() = 'driver' and v_order.assigned_driver_id = auth.uid())
  ) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  if v_order.status <> 'collected' then raise exception 'الأوردر ليس بحالة تسمح بتأكيد الاستلام في المصنع'; end if;

  update public.orders
     set status = 'at_factory',
         factory_received_at = now(),
         handed_to_factory_at = coalesce(handed_to_factory_at, now())
   where id = p_order_id;

  perform public.log_order_event(p_order_id, 'factory_confirmed_receipt', 'collected', 'at_factory',
    'تم تسليم الأوردر للمصنع');

  if v_order.assigned_driver_id is not null and v_order.assigned_driver_id is distinct from auth.uid() then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'factory_received',
      'تم استلام الأوردر ' || v_order.order_number || ' في المصنع', null);
  end if;

  perform public.notify_staff(p_order_id, 'factory_received',
    'تم تسليم الأوردر ' || v_order.order_number || ' للمصنع', null, auth.uid());
end;
$$;

create or replace function public.factory_mark_ready(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;

  if not (
    coalesce(public.is_owner_or_moderator(), false)
    or (public.current_user_role() = 'driver' and v_order.assigned_driver_id = auth.uid())
  ) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  if v_order.status <> 'at_factory' then raise exception 'الأوردر ليس داخل المصنع حاليًا'; end if;

  update public.orders set status = 'ready', factory_ready_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'factory_marked_ready', 'at_factory', 'ready',
    'المصنع أنهى العمل والأوردر جاهز للاستلام');

  if v_order.assigned_driver_id is not null and v_order.assigned_driver_id is distinct from auth.uid() then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'ready_for_pickup',
      'أوردر ' || v_order.order_number || ' جاهز للتسليم', 'يمكنك استلامه من المصنع الآن');
  end if;

  perform public.notify_staff(p_order_id, 'ready_for_pickup',
    'الأوردر ' || v_order.order_number || ' جاهز للاستلام من المصنع', null, auth.uid());
end;
$$;

create or replace function public.can_read_order_channel(
  p_order_id uuid,
  p_channel text,
  p_user_id uuid,
  p_message_driver_id uuid default null
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.orders o
    where o.id = p_order_id
      and p_channel = 'driver'
      and o.assigned_driver_id = p_user_id
      and p_message_driver_id = p_user_id
  );
$$;

alter table public.profiles drop constraint if exists profiles_role_not_factory;
alter table public.profiles add constraint profiles_role_not_factory check (role <> 'factory');

comment on type public.user_role is
  'factory is retained for historical rows only (order_history.actor_role, '
  'order_messages.sender_role) — factories became a table of their own in '
  'migration 0033 and no profile may use this value; see the '
  'profiles_role_not_factory constraint.';
