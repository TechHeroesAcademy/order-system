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
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
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
end;
$$;

revoke all on function public.reassign_order_factory from public;
grant execute on function public.reassign_order_factory to authenticated;

create or replace function public.get_order_delivery_codes(p_order_ids uuid[])
returns table (order_id uuid, code text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  return query
    select c.order_id, c.code
    from public.order_delivery_codes c
    where c.order_id = any (p_order_ids);
end;
$$;

revoke all on function public.get_order_delivery_codes from public;
grant execute on function public.get_order_delivery_codes to authenticated;

create table if not exists public.order_messages (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  sender_id uuid not null references public.profiles (id),
  sender_role user_role not null,
  body text not null,
  created_at timestamptz not null default now()
);

create index if not exists order_messages_order_idx on public.order_messages (order_id, created_at);

alter table public.order_messages enable row level security;
revoke all on public.order_messages from public, anon, authenticated;

create policy order_messages_select on public.order_messages
  for select using (
    public.is_owner_or_moderator()
    or exists (
      select 1 from public.orders o
      where o.id = order_messages.order_id
        and o.assigned_driver_id = auth.uid()
    )
  );

grant select on public.order_messages to authenticated;

create or replace function public.send_order_message(p_order_id uuid, p_body text)
returns public.order_messages
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_role user_role := public.current_user_role();
  v_body text := trim(coalesce(p_body, ''));
  v_row public.order_messages;
begin
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
    or (v_role = 'driver' and v_order.assigned_driver_id = auth.uid())
  ) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  insert into public.order_messages (order_id, sender_id, sender_role, body)
  values (p_order_id, auth.uid(), v_role, v_body)
  returning * into v_row;

  if v_role = 'driver' then
    perform public.notify_role('owner', p_order_id, 'chat_message',
      'رسالة جديدة على الأوردر ' || v_order.order_number, v_body);
    perform public.notify_role('moderator', p_order_id, 'chat_message',
      'رسالة جديدة على الأوردر ' || v_order.order_number, v_body);
  elsif v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'chat_message',
      'رسالة جديدة على الأوردر ' || v_order.order_number, v_body);
  end if;

  return v_row;
end;
$$;

revoke all on function public.send_order_message from public;
grant execute on function public.send_order_message to authenticated;
