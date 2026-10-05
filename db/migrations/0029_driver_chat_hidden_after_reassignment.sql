alter table public.order_messages add column if not exists driver_id uuid references public.profiles(id);

update public.order_messages om
  set driver_id = o.assigned_driver_id
  from public.orders o
  where om.order_id = o.id
    and om.channel = 'driver'
    and om.driver_id is distinct from o.assigned_driver_id;

create index if not exists order_messages_driver_stint_idx on public.order_messages (order_id, driver_id) where channel = 'driver';

drop policy if exists order_messages_select on public.order_messages;
drop function if exists public.can_read_order_channel(uuid, text, uuid);

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
      and (
        (p_channel = 'driver' and o.assigned_driver_id = p_user_id and p_message_driver_id = p_user_id)
        or (p_channel = 'factory' and o.assigned_factory_id = p_user_id)
      )
  );
$$;

revoke all on function public.can_read_order_channel(uuid, text, uuid, uuid) from public;
grant execute on function public.can_read_order_channel(uuid, text, uuid, uuid) to authenticated;

create policy order_messages_select on public.order_messages
  for select using (
    public.is_owner_or_moderator()
    or public.can_read_order_channel(order_messages.order_id, order_messages.channel, auth.uid(), order_messages.driver_id)
  );

create or replace function public.send_order_message(p_order_id uuid, p_channel text, p_body text)
returns public.order_messages
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_role user_role := public.current_user_role();
  v_body text := trim(coalesce(p_body, ''));
  v_channel text := coalesce(p_channel, 'driver');
  v_row public.order_messages;
begin
  if v_channel not in ('driver', 'factory') then
    raise exception 'قناة دردشة غير صالحة';
  end if;
  if length(v_body) = 0 then
    raise exception 'اكتب رسالة قبل الإرسال' using errcode = '22023';
  end if;
  if length(v_body) > 1000 then
    raise exception 'الرسالة طويلة جدًا — بحد أقصى 1000 حرف' using errcode = '22023';
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if v_order is null then
    raise exception 'الأوردر غير موجود';
  end if;

  if not (
    public.is_owner_or_moderator()
    or (v_channel = 'driver' and v_role = 'driver' and v_order.assigned_driver_id = auth.uid())
    or (v_channel = 'factory' and v_role = 'factory' and v_order.assigned_factory_id = auth.uid())
  ) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  insert into public.order_messages (order_id, channel, sender_id, sender_role, body, driver_id)
  values (
    p_order_id, v_channel, auth.uid(), v_role, v_body,
    case when v_channel = 'driver' then v_order.assigned_driver_id else null end
  )
  returning * into v_row;

  if v_channel = 'driver' then
    if v_role = 'driver' then
      perform public.notify_staff(p_order_id, 'chat_message',
        'رسالة جديدة (دردشة المندوب) على الأوردر ' || v_order.order_number, v_body);
    elsif v_order.assigned_driver_id is not null then
      perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'chat_message',
        'رسالة جديدة على الأوردر ' || v_order.order_number, v_body);
    end if;
  else
    if v_role = 'factory' then
      perform public.notify_staff(p_order_id, 'chat_message',
        'رسالة جديدة (دردشة المصنع) على الأوردر ' || v_order.order_number, v_body);
    elsif v_order.assigned_factory_id is not null then
      perform public.notify_user(v_order.assigned_factory_id, p_order_id, 'chat_message',
        'رسالة جديدة على الأوردر ' || v_order.order_number, v_body);
    end if;
  end if;

  return v_row;
end;
$$;

revoke all on function public.send_order_message(uuid, text, text) from public;
grant execute on function public.send_order_message(uuid, text, text) to authenticated;
