-- 0029_driver_chat_hidden_after_reassignment.sql
--
-- "when the order moved to another driver the chat of this order should be
-- erased from the new driver but should appear to the manager" —
--
-- Today, the driver channel's read policy (can_read_order_channel, 0019)
-- only checks "is this user the order's *current* assigned_driver_id" —
-- it has no idea when each message was sent relative to who was assigned
-- at the time. So reassigning an order to a new driver silently hands them
-- the *entire* prior conversation (including anything the old driver said
-- to Owner/Moderator), which is exactly the leak being closed here.
--
-- Fix: stamp every driver-channel message with which driver's "stint" it
-- belongs to (order_messages.driver_id = the order's assigned_driver_id
-- at send time), and require a driver's read to match *both* "I'm the
-- order's current driver" *and* "this message was sent during my own
-- stint". Owner/Moderator are untouched — is_owner_or_moderator() already
-- short-circuits the policy before either check runs, so they keep seeing
-- every message regardless of reassignment, exactly as asked. The factory
-- channel is untouched too — this request was about driver reassignment
-- specifically.
--
-- Existing rows are backfilled to the order's *current* driver, which is
-- the best available answer (there's no reliable per-message historical
-- record of who was assigned when) — this closes the leak for every
-- reassignment from this point forward; it can't retroactively un-leak a
-- conversation a driver already had open before this migration ran.

alter table public.order_messages add column if not exists driver_id uuid references public.profiles(id);

update public.order_messages om
  set driver_id = o.assigned_driver_id
  from public.orders o
  where om.order_id = o.id
    and om.channel = 'driver'
    and om.driver_id is distinct from o.assigned_driver_id;

create index if not exists order_messages_driver_stint_idx on public.order_messages (order_id, driver_id) where channel = 'driver';

-- can_read_order_channel gains a 4th parameter here. CREATE OR REPLACE
-- does *not* actually replace a function when the parameter list changes
-- (even by only adding a defaulted trailing one) — it silently creates a
-- second overload instead, leaving the old 3-arg signature callable and
-- ambiguous alongside the new one. Drop the old signature explicitly
-- first, same lesson as the create_order_internal "not unique" bug from
-- an earlier round — and the policy using it has to go first, since it
-- depends on that exact signature.
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

  -- driver_id stamps which driver's stint this message belongs to (null
  -- for the factory channel, where it's irrelevant) — see
  -- can_read_order_channel above for why this matters.
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
  else -- factory channel
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
