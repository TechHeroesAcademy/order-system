-- 0019_dual_channel_chat_and_full_step_notifications.sql
--
-- Two independent additions, both requested together:
--
--   1) Two separate chat channels per order instead of one — a driver
--      channel (driver <-> Owner/Moderator, from 0018) and a new factory
--      channel (factory <-> Owner/Moderator). order_messages gains a
--      `channel` column; the RLS select policy and send_order_message() are
--      rewritten to branch on it. A factory account was never part of the
--      driver channel and still isn't — this is a genuinely separate
--      conversation, not a shared one.
--
--   2) Every physical step in the order lifecycle now notifies BOTH Owner
--      and Moderator (not just whichever one happened to trigger it, and
--      not skipped entirely as several steps were before), via a new
--      notify_staff() helper that loops both roles and can exclude the
--      actor so people aren't notified of their own action. The factory is
--      also now notified specifically when the assigned driver is heading
--      to them (driver_hand_to_factory) and when the driver has picked the
--      order back up and left (driver_confirm_factory_pickup) — "going to
--      or going out", as requested.

-- ---------- helper: notify both staff roles at once ----------

create or replace function public.notify_staff(
  p_order_id uuid,
  p_type text,
  p_title text,
  p_body text default null,
  p_exclude uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user record;
begin
  for v_user in
    select id from public.profiles
    where role in ('owner', 'moderator') and is_active
      and (p_exclude is null or id <> p_exclude)
  loop
    perform public.notify_user(v_user.id, p_order_id, p_type, p_title, p_body);
  end loop;
end;
$$;

revoke all on function public.notify_staff from public;

-- ---------- 1) dual-channel chat ----------

alter table public.order_messages add column if not exists channel text not null default 'driver';
alter table public.order_messages drop constraint if exists order_messages_channel_check;
alter table public.order_messages add constraint order_messages_channel_check check (channel in ('driver', 'factory'));

create index if not exists order_messages_order_channel_idx on public.order_messages (order_id, channel, created_at);

-- Whether p_user_id may read p_channel's messages on p_order_id — SECURITY
-- DEFINER and deliberately bypasses orders' own RLS. orders_select_driver
-- has no status restriction (a driver keeps seeing their own past orders
-- forever), but orders_select_factory is scoped to the active statuses
-- ('collected'/'at_factory'/'ready') only — a plain `exists (select 1 from
-- orders o where ...)` inside the order_messages policy would run that
-- subquery under the factory's own RLS too, so once an order they were
-- assigned to moves on to 'ready' -> 'with_driver' -> 'delivered' the
-- factory would silently lose the ability to read messages it could still
-- send (send_order_message only checks assignment, not status) — its own
-- chat history vanishing out from under it mid-conversation. Routing the
-- check through this function instead means "was I assigned to this
-- order's channel" is answered directly against the raw row, so factory
-- chat access is exactly as permanent as driver chat access already is.
create or replace function public.can_read_order_channel(p_order_id uuid, p_channel text, p_user_id uuid)
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
        (p_channel = 'driver' and o.assigned_driver_id = p_user_id)
        or (p_channel = 'factory' and o.assigned_factory_id = p_user_id)
      )
  );
$$;

revoke all on function public.can_read_order_channel from public;
grant execute on function public.can_read_order_channel to authenticated;

drop policy if exists order_messages_select on public.order_messages;
create policy order_messages_select on public.order_messages
  for select using (
    public.is_owner_or_moderator()
    or public.can_read_order_channel(order_messages.order_id, order_messages.channel, auth.uid())
  );

drop function if exists public.send_order_message(uuid, text);

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

  insert into public.order_messages (order_id, channel, sender_id, sender_role, body)
  values (p_order_id, v_channel, auth.uid(), v_role, v_body)
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

revoke all on function public.send_order_message from public;
grant execute on function public.send_order_message to authenticated;

-- ---------- 2) notify Owner+Moderator (and the factory, for hand-off steps) on every step ----------

create or replace function public.driver_mark_collected(p_order_id uuid)
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
  if v_order.status <> 'assigned' then raise exception 'الأوردر ليس بحالة تسمح بتسجيل الاستلام من العميل'; end if;

  update public.orders set status = 'collected', collected_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'collected_from_customer', 'assigned', 'collected', 'تم استلام الأوردر من العميل');
  perform public.notify_staff(p_order_id, 'order_collected',
    'تم استلام الأوردر ' || v_order.order_number || ' من العميل', null, auth.uid());
end;
$$;

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
  if v_order.assigned_factory_id is not null then
    perform public.notify_user(v_order.assigned_factory_id, p_order_id, 'driver_heading_to_factory',
      'مندوب في الطريق إليكم بالأوردر ' || v_order.order_number, null);
  end if;
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
  if v_order.assigned_factory_id is not null then
    perform public.notify_user(v_order.assigned_factory_id, p_order_id, 'driver_left_factory',
      'المندوب استلم الأوردر ' || v_order.order_number || ' وغادر المصنع', null);
  end if;
end;
$$;

create or replace function public.driver_deliver_to_customer(p_order_id uuid, p_code text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public.orders;
  v_ok boolean;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.assigned_driver_id <> auth.uid() then raise exception 'غير مصرح' using errcode = '42501'; end if;
  if v_order.status <> 'with_driver' then raise exception 'الأوردر ليس بحالة تسمح بالتسليم للعميل'; end if;

  v_ok := (crypt(coalesce(p_code, ''), v_order.delivery_code_hash) = v_order.delivery_code_hash);

  if v_ok then
    update public.orders set status = 'delivered', delivered_at = now() where id = p_order_id;
    perform public.log_order_event(p_order_id, 'delivered', 'with_driver', 'delivered', 'تم التسليم للعميل وتأكيد الكود بنجاح');
    perform public.notify_staff(p_order_id, 'order_delivered',
      'تم تسليم الأوردر ' || v_order.order_number || ' للعميل', null, auth.uid());
  else
    update public.orders
      set failed_code_attempts = failed_code_attempts + 1,
          delivery_code_last_attempt_at = now()
      where id = p_order_id;
    perform public.log_order_event(p_order_id, 'delivery_code_mismatch', 'with_driver', 'with_driver', 'محاولة تسليم بكود غير صحيح');
  end if;

  return v_ok;
end;
$$;

create or replace function public.driver_log_refusal(p_order_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  if length(trim(coalesce(p_reason, ''))) = 0 then
    raise exception 'يجب كتابة سبب رفض الاستلام';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.assigned_driver_id <> auth.uid() then raise exception 'غير مصرح' using errcode = '42501'; end if;
  if v_order.status <> 'with_driver' then raise exception 'الأوردر ليس بحالة تسمح بتسجيل رفض الاستلام'; end if;

  update public.orders
    set status = 'refused', refused_at = now(), refusal_reason = trim(p_reason)
    where id = p_order_id;

  perform public.log_order_event(p_order_id, 'refused', 'with_driver', 'refused', p_reason);
  -- Was notify_role('owner', ...) only — Moderator gets it too now, via notify_staff.
  perform public.notify_staff(p_order_id, 'order_refused', 'رفض استلام أوردر ' || v_order.order_number, p_reason, auth.uid());
end;
$$;

create or replace function public.factory_confirm_receipt(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  if public.current_user_role() not in ('factory', 'owner', 'moderator') then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status <> 'collected' then raise exception 'الأوردر ليس بحالة تسمح بتأكيد الاستلام في المصنع'; end if;

  update public.orders set status = 'at_factory', factory_received_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'factory_confirmed_receipt', 'collected', 'at_factory', 'المصنع أكد استلام الأوردر');
  perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'factory_received',
    'تم استلام الأوردر ' || v_order.order_number || ' في المصنع', null);
  perform public.notify_staff(p_order_id, 'factory_received',
    'المصنع أكد استلام الأوردر ' || v_order.order_number, null, auth.uid());
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
  if public.current_user_role() not in ('factory', 'owner', 'moderator') then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status <> 'at_factory' then raise exception 'الأوردر ليس داخل المصنع حاليًا'; end if;

  update public.orders set status = 'ready', factory_ready_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'factory_marked_ready', 'at_factory', 'ready', 'المصنع أنهى العمل والأوردر جاهز للتسليم');
  perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'ready_for_pickup',
    'أوردر ' || v_order.order_number || ' جاهز للتسليم', 'يمكنك استلامه من المصنع الآن');
  perform public.notify_staff(p_order_id, 'ready_for_pickup',
    'الأوردر ' || v_order.order_number || ' جاهز للتسليم من المصنع', null, auth.uid());
end;
$$;

create or replace function public.owner_cancel_order(p_order_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status in ('delivered', 'cancelled') then
    raise exception 'لا يمكن إلغاء أوردر تم تسليمه أو ملغى بالفعل';
  end if;

  update public.orders set status = 'cancelled', cancelled_at = now(), cancel_reason = p_reason where id = p_order_id;
  perform public.log_order_event(p_order_id, 'cancelled', v_order.status, 'cancelled', p_reason);
  perform public.notify_staff(p_order_id, 'order_cancelled', 'تم إلغاء الأوردر ' || v_order.order_number, p_reason, auth.uid());
end;
$$;

create or replace function public.approve_distribution(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  if not public.is_owner() then
    raise exception 'اعتماد التوزيع من صلاحية Owner فقط' using errcode = '42501';
  end if;

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
  perform public.notify_staff(p_order_id, 'distribution_approved',
    'تم اعتماد توزيع الأوردر ' || v_order.order_number, null, auth.uid());
end;
$$;

create or replace function public.reassign_order_driver(p_order_id uuid, p_new_driver_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_new_driver public.profiles;
  v_old_driver_name text;
  v_new_status public.order_status;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status in ('delivered', 'cancelled', 'refused') then
    raise exception 'لا يمكن تغيير المندوب لأوردر منتهٍ';
  end if;

  select * into v_new_driver from public.profiles where id = p_new_driver_id;
  if v_new_driver is null or v_new_driver.role <> 'driver' or not v_new_driver.is_active then
    raise exception 'المندوب المحدد غير صالح';
  end if;
  if v_order.assigned_driver_id = p_new_driver_id then
    raise exception 'هذا المندوب مسؤول عن الأوردر بالفعل';
  end if;

  if v_order.assigned_driver_id is not null then
    select full_name into v_old_driver_name from public.profiles where id = v_order.assigned_driver_id;
  end if;

  v_new_status := case when v_order.status = 'new' then 'assigned' else v_order.status end;

  update public.orders
    set assigned_driver_id = p_new_driver_id,
        distribution_approved_at = coalesce(distribution_approved_at, now()),
        distribution_approved_by = coalesce(distribution_approved_by, auth.uid()),
        status = v_new_status
    where id = p_order_id;

  perform public.log_order_event(p_order_id, 'driver_reassigned', v_order.status, v_new_status,
    case when v_old_driver_name is not null
      then 'تم تغيير المندوب من ' || v_old_driver_name || ' إلى ' || v_new_driver.full_name
      else 'تم تعيين مندوب: ' || v_new_driver.full_name
    end);

  if v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'reassigned_away',
      'تم نقل الأوردر ' || v_order.order_number || ' إلى مندوب آخر', null);
  end if;

  perform public.notify_user(p_new_driver_id, p_order_id, 'order_assigned',
    'تم إسناد أوردر إليك ' || v_order.order_number, 'العميل: ' || v_order.customer_name);
  perform public.notify_staff(p_order_id, 'driver_reassigned',
    'تم تغيير مندوب الأوردر ' || v_order.order_number, null, auth.uid());
end;
$$;

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

  perform public.notify_staff(p_order_id, 'factory_reassigned',
    'تم تغيير مصنع الأوردر ' || v_order.order_number, null, auth.uid());
end;
$$;
