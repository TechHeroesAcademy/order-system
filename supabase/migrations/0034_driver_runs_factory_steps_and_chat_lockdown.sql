-- 0034_driver_runs_factory_steps_and_chat_lockdown.sql
--
-- Two changes, both prerequisites for retiring the factory accounts:
--
-- 1. The DRIVER now presses the factory steps. Waiting for a factory account
--    to confirm receipt and then mark the work finished was the bottleneck
--    this whole change exists to remove — the driver is standing at the
--    workshop, so the driver records what happened.
--
-- 2. Chat becomes driver <-> Manager only. The factory channel is closed,
--    and Moderators lose chat entirely (read and write).
--
-- Every function here keeps its exact signature and is replaced in place, so
-- this migration is correct for BOTH the currently-deployed build and the one
-- that follows it. That is what makes it safe to run this before deploying,
-- which is the required order — see the transitional note on the factory role
-- below.

-- ── the two factory steps, now driver-operated ──────────────────────────
-- Authorization changes shape here. The old check was role-only:
--   if public.current_user_role() not in ('factory','owner','moderator')
-- which never checked whether the order had anything to do with the caller —
-- any factory account could advance any order in the system. That gap is
-- fixed while we're in here: the row is now locked BEFORE the authorization
-- decision, because the decision needs the row.
--
-- The 'factory' term is TRANSITIONAL. It exists only so a factory account
-- still signed in on the current build keeps working between this migration
-- and the deploy that removes their screens. It is removed in the cleanup
-- migration once no profile carries that role.

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
    or public.current_user_role() = 'factory'  -- transitional, removed in cleanup
  ) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  if v_order.status <> 'collected' then raise exception 'الأوردر ليس بحالة تسمح بتأكيد الاستلام في المصنع'; end if;

  -- When the driver records this themselves they may never have pressed the
  -- separate "heading to the factory" button, which is what used to stamp
  -- handed_to_factory_at. Stamp it here if it's still empty so
  -- handed_to_factory_at <= factory_received_at always holds — the daily
  -- report's "entered factory" count and the customer tracking timeline both
  -- read those two together.
  update public.orders
     set status = 'at_factory',
         factory_received_at = now(),
         handed_to_factory_at = coalesce(handed_to_factory_at, now())
   where id = p_order_id;

  perform public.log_order_event(p_order_id, 'factory_confirmed_receipt', 'collected', 'at_factory',
    'تم تسليم الأوردر للمصنع');

  -- Don't notify the driver about their own press.
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
    or public.current_user_role() = 'factory'  -- transitional, removed in cleanup
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

-- ── stop notifying the factory account ──────────────────────────────────
-- Not cosmetic: notifications.user_id has a foreign key to profiles, and
-- assigned_factory_id now points at factories. Leaving these calls in place
-- would make the driver's hand-off and pickup raise a foreign-key violation
-- the moment the factory profile rows are deleted — the driver would simply
-- be unable to record either step. Bodies are otherwise unchanged from 0019.

create or replace function public.driver_hand_to_factory(p_order_id uuid)
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
  if v_order.assigned_driver_id <> auth.uid() then raise exception 'غير مصرح' using errcode = '42501'; end if;
  if v_order.status <> 'collected' then raise exception 'الأوردر ليس بحالة تسمح بالتوجه للمصنع'; end if;
  if v_order.handed_to_factory_at is not null then
    raise exception 'تم تسجيل هذه الخطوة بالفعل';
  end if;

  update public.orders set handed_to_factory_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'handed_to_factory', 'collected', 'collected', 'المندوب توجه بالأوردر إلى المصنع');
  perform public.notify_staff(p_order_id, 'driver_heading_to_factory',
    'المندوب في الطريق للمصنع — الأوردر ' || v_order.order_number, null, auth.uid());
end;
$$;

create or replace function public.driver_confirm_factory_pickup(p_order_id uuid)
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
  if v_order.assigned_driver_id <> auth.uid() then raise exception 'غير مصرح' using errcode = '42501'; end if;
  if v_order.status <> 'ready' then raise exception 'الأوردر ليس جاهزًا للاستلام من المصنع بعد'; end if;

  update public.orders set status = 'with_driver', driver_pickup_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'driver_picked_up_from_factory', 'ready', 'with_driver', 'استلم المندوب الأوردر من المصنع');
  perform public.notify_staff(p_order_id, 'driver_left_factory',
    'استلم المندوب الأوردر ' || v_order.order_number || ' من المصنع وغادر', null, auth.uid());
end;
$$;

-- ── chat: driver <-> Manager only ───────────────────────────────────────
-- The factory channel is closed to new messages (existing ones stay readable
-- by a Manager as history), and Moderators lose chat entirely.
--
-- Note the notification change at the bottom: driver messages used to go
-- through notify_staff, which notifies Managers AND Moderators, with the
-- message text as the notification body. Changing only the read policy would
-- have stopped Moderators opening the chat while still delivering them every
-- message verbatim in their notification bell.

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
  if v_channel <> 'driver' then
    raise exception 'قناة الدردشة الوحيدة المتاحة هي دردشة المندوب' using errcode = '22023';
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
    public.is_owner()
    or (v_role = 'driver' and v_order.assigned_driver_id = auth.uid())
  ) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  -- driver_id stamps which driver's stint this message belongs to — see
  -- can_read_order_channel (0029) for why that matters after a reassignment.
  insert into public.order_messages (order_id, channel, sender_id, sender_role, body, driver_id)
  values (p_order_id, v_channel, auth.uid(), v_role, v_body, v_order.assigned_driver_id)
  returning * into v_row;

  if v_role = 'driver' then
    -- notify_role('owner', ...) rather than notify_staff: the body carries
    -- the message text, and Moderators are no longer part of these
    -- conversations.
    perform public.notify_role('owner', p_order_id, 'chat_message',
      'رسالة جديدة من المندوب على الأوردر ' || v_order.order_number, v_body);
  elsif v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'chat_message',
      'رسالة جديدة على الأوردر ' || v_order.order_number, v_body);
  end if;

  return v_row;
end;
$$;

-- Read side. is_owner() replaces is_owner_or_moderator(); the
-- can_read_order_channel() branch is what still lets the assigned driver read
-- their own stint's messages.
drop policy if exists order_messages_select on public.order_messages;
create policy order_messages_select on public.order_messages
  for select using (
    public.is_owner()
    or public.can_read_order_channel(order_messages.order_id, order_messages.channel, auth.uid(), order_messages.driver_id)
  );
