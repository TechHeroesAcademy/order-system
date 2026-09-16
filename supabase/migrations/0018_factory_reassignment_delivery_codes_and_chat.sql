-- 0018_factory_reassignment_delivery_codes_and_chat.sql
--
-- Three independent additions, all requested together:
--
--   1) reassign_order_factory() — the factory routed to an order was only
--      ever settable once, at creation (0014/0016). Owner/Moderator can now
--      change it at any point before the order closes, mirroring
--      reassign_order_driver() exactly (same validation shape, same
--      "already assigned" guard, same terminal-status guard). The assigned
--      driver is notified so they know the pickup/drop-off location changed
--      — the location itself needs no separate propagation: every place
--      that shows it (driver order page, owner/moderator order detail) reads
--      assigned_factory_id fresh on each request, so a driver who reloads
--      always sees the new factory the moment this commits.
--
--   2) get_order_delivery_codes() — a batch counterpart to
--      get_order_delivery_code() (0016) so the orders list can show every
--      row's code without firing one RPC per row. Same authorization
--      (Owner/Moderator only), same underlying table.
--
--   3) Per-order chat between the assigned driver and Owner/Moderator —
--      order_messages table + send_order_message() RPC. Reads go straight
--      through RLS (same pattern as notifications/orders/order_history);
--      writes are forced through the RPC so sender_id/sender_role can never
--      be spoofed by a client, and so the other side gets notified the same
--      way every other cross-role event already does (notify_user/notify_role).
--      Factory accounts are deliberately not part of this — the request was
--      specifically "drivers and MODs and Manager and vice versa".

-- ---------- 1) factory reassignment ----------

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

  -- The driver's own screen reads assigned_factory_id fresh every time, so
  -- nothing else needs updating for them to see the new location — this is
  -- purely to make sure they notice the change happened at all.
  if v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'factory_reassigned',
      'تم تغيير المصنع الخاص بالأوردر ' || v_order.order_number,
      'المصنع الجديد: ' || v_new_factory.full_name);
  end if;

  -- Let the newly assigned factory know an order was routed to them, same
  -- as they'd see it appear on their dashboard — only meaningful once the
  -- order has actually reached the factory-handling stage.
  if v_order.status in ('collected', 'at_factory', 'ready') then
    perform public.notify_user(p_new_factory_id, p_order_id, 'order_assigned',
      'تم تخصيص أوردر لمصنعكم ' || v_order.order_number, null);
  end if;
end;
$$;

revoke all on function public.reassign_order_factory from public;
grant execute on function public.reassign_order_factory to authenticated;

-- ---------- 2) batch delivery-code lookup ----------

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

-- ---------- 3) per-order chat ----------

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

-- Reads go straight through RLS, same as orders/order_history/notifications
-- — no RPC needed for this side, just the standard "am I allowed to see
-- this order" check plus the driver's own narrower case.
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

-- Writes always go through this RPC — sender_id/sender_role come from the
-- verified session, never from client input, and the other side is always
-- notified the same way every other cross-role event already is.
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
