-- ============================================================================
-- NEON SETUP — PART 2 OF 6
--
-- PASTE THIS WHOLE FILE INTO NEON'S SQL EDITOR AND RUN IT.
-- Run the parts in order. Wait for each to finish before starting the next.
-- Each part is safe to re-run: every statement is idempotent.
--
-- Requires the previous part to have finished.
--
-- GENERATED — do not edit. Edit the source files listed below and re-run
-- scripts/build-neon-bundle.mjs, so Supabase and Neon cannot drift apart.
--
-- Contains, in order:
--    1. supabase/migrations/0019_dual_channel_chat_and_full_step_notifications.sql
--    2. supabase/migrations/0020_google_maps_links.sql
--    3. supabase/migrations/0021_editable_order_details.sql
--    4. supabase/migrations/0022_factory_permanent_order_history.sql
--    5. supabase/migrations/0023_fix_factory_premature_visibility.sql
--    6. supabase/migrations/0024_pickup_code_owner_only_assignment_and_fair_auto_distribution.sql
--    7. supabase/migrations/0025_region_free_text_matching.sql
--    8. supabase/migrations/0026_pickup_points.sql
--    9. supabase/migrations/0027_factory_only_order_creation.sql
--   10. supabase/migrations/0028_remove_pickup_points.sql
--   11. supabase/migrations/0029_driver_chat_hidden_after_reassignment.sql
--   12. supabase/migrations/0030_owner_only_cancel_and_no_moderator_team.sql
--   13. supabase/migrations/0031_wider_order_numbers.sql
-- ============================================================================

-- The chain installs pgcrypto/pg_trgm into the extensions schema (as Supabase
-- does) and several functions resolve against it. Declared per part rather
-- than relied on from the database default, so pasting a part into a fresh
-- editor session always works.
set search_path = public, extensions;



-- ========== supabase/migrations/0019_dual_channel_chat_and_full_step_notifications.sql 

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


-- ========== supabase/migrations/0020_google_maps_links.sql ============

-- 0020_google_maps_links.sql
--
-- "Add another field for the Google Maps link (like
-- https://www.google.com/maps/place/...)" — until now, a location's map link
-- was always *derived* (precise lat/lng from the picker, or a free-text
-- address run through a Maps search). That's fine for a factory pinned with
-- the Leaflet picker, but a customer's exact location often only exists as a
-- link someone already shares on WhatsApp/Messenger (Google Maps app >
-- Share > Copy link) — a long "place" URL carrying its own precise
-- coordinates that a text search can't reconstruct. This adds an optional,
-- directly-pasted Google Maps link field for both the customer (on the
-- order) and the factory (on its profile), which mapsUrlFor() now prefers
-- over lat/lng and over a text-address search whenever it's present.
--
-- Also powers "pressing open shows both the customer's and the factory's
-- location" for the driver — see driver-order-actions.tsx and
-- driver/orders/[id]/page.tsx, updated alongside this migration.

-- ---------- customer's pasted Maps link (per order) ----------

alter table public.orders add column if not exists customer_maps_url text;

comment on column public.orders.customer_maps_url is
  'Optional Google Maps link pasted by staff at order creation (a Maps "share" link, e.g. https://www.google.com/maps/place/...). Preferred over a free-text customer_address search by mapsUrlFor() whenever present. Null falls back to searching customer_address.';

-- ---------- factory's pasted Maps link (per profile) ----------

alter table public.profiles add column if not exists maps_url text;

comment on column public.profiles.maps_url is
  'Only meaningful for role=factory — same idea as orders.customer_maps_url: an optional pasted Google Maps link, preferred over lat/lng/address by mapsUrlFor() whenever present. Read from signup metadata by handle_new_user(), editable later alongside address/lat/lng (see updateStaffLocationAction / FactoryLocationCell).';

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, phone, role, address, lat, lng, maps_url)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.email, 'مستخدم جديد'),
    new.raw_user_meta_data ->> 'phone',
    coalesce((new.raw_user_meta_data ->> 'role')::user_role, 'driver'),
    new.raw_user_meta_data ->> 'address',
    nullif(new.raw_user_meta_data ->> 'lat', '')::double precision,
    nullif(new.raw_user_meta_data ->> 'lng', '')::double precision,
    new.raw_user_meta_data ->> 'maps_url'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

-- ---------- order-creation RPCs: add p_customer_maps_url ----------
--
-- A new trailing parameter changes the argument-type signature — Postgres
-- would otherwise leave the old signature in the catalog alongside the new
-- one (an overload), and every call site becomes ambiguous. Same pattern as
-- every previous parameter addition here (0014, 0016): drop the exact old
-- signature first, then recreate with the new trailing (default-null)
-- parameter appended.

drop function if exists public.create_order_internal(text, text, text, uuid, integer, text, text, text, text, order_source, uuid, uuid, uuid);
drop function if exists public.public_create_order(text, text, text, uuid, integer, text, text, text, text, uuid);
drop function if exists public.moderator_create_order(text, text, text, uuid, integer, text, text, text, text, uuid, uuid);

create or replace function public.create_order_internal(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text,
  p_color text,
  p_work_required text,
  p_customer_notes text,
  p_source order_source,
  p_created_by uuid,
  p_factory_id uuid default null,
  p_driver_id uuid default null,
  p_customer_maps_url text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := public.generate_delivery_code();
  v_order public.orders;
  v_result public.new_order_result;
  v_factory public.profiles;
  v_driver public.profiles;
  v_new_status public.order_status;
  v_maps_url text := nullif(trim(coalesce(p_customer_maps_url, '')), '');
begin
  if length(trim(p_customer_name)) = 0 then
    raise exception 'اسم العميل مطلوب' using errcode = '22023';
  end if;
  if length(trim(p_customer_phone)) < 8 then
    raise exception 'رقم هاتف العميل غير صالح' using errcode = '22023';
  end if;
  if p_pieces_count is null or p_pieces_count < 1 then
    raise exception 'عدد القطع يجب أن يكون 1 على الأقل' using errcode = '22023';
  end if;

  if p_factory_id is not null then
    select * into v_factory from public.profiles where id = p_factory_id;
    if v_factory is null or v_factory.role <> 'factory' or not v_factory.is_active then
      raise exception 'المصنع المحدد غير صالح' using errcode = '22023';
    end if;
  end if;

  if p_driver_id is not null then
    select * into v_driver from public.profiles where id = p_driver_id;
    if v_driver is null or v_driver.role <> 'driver' or not v_driver.is_active then
      raise exception 'المندوب المحدد غير صالح' using errcode = '22023';
    end if;
  end if;

  insert into public.orders (
    customer_name, customer_phone, customer_address, customer_maps_url, region_id,
    pieces_count, piece_details, color, work_required, customer_notes,
    source, created_by, delivery_code_hash, assigned_factory_id
  ) values (
    trim(p_customer_name), trim(p_customer_phone), trim(p_customer_address), v_maps_url, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    p_source, p_created_by, crypt(v_code, gen_salt('bf')), p_factory_id
  )
  returning * into v_order;

  insert into public.order_delivery_codes (order_id, code) values (v_order.id, v_code);

  perform public.log_order_event(v_order.id, 'created', null, 'new',
    'تم إنشاء الأوردر عبر ' || case when p_source = 'website' then 'الموقع' else 'Messenger' end);

  if p_driver_id is not null then
    v_new_status := case when v_order.status = 'new' then 'assigned' else v_order.status end;

    update public.orders
      set assigned_driver_id = p_driver_id,
          distribution_approved_at = now(),
          distribution_approved_by = p_created_by,
          status = v_new_status
      where id = v_order.id;

    v_order.status := v_new_status;

    perform public.log_order_event(v_order.id, 'driver_reassigned', 'new', v_new_status,
      'تم تعيين مندوب عند إنشاء الأوردر: ' || v_driver.full_name);

    perform public.notify_user(p_driver_id, v_order.id, 'order_assigned',
      'تم إسناد أوردر إليك ' || v_order.order_number, 'العميل: ' || v_order.customer_name);
  end if;

  perform public.notify_role('owner', v_order.id, 'new_order', 'أوردر جديد ' || v_order.order_number,
    'تم استلام أوردر جديد من ' || v_order.customer_name);

  v_result.order_id := v_order.id;
  v_result.order_number := v_order.order_number;
  v_result.delivery_code := v_code;
  return v_result;
end;
$$;

revoke all on function public.create_order_internal from public, anon, authenticated;

create or replace function public.public_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null,
  p_factory_id uuid default null,
  p_customer_maps_url text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'website', null, p_factory_id, null, p_customer_maps_url
  );
end;
$$;

revoke all on function public.public_create_order from public;
grant execute on function public.public_create_order to anon, authenticated;

create or replace function public.moderator_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null,
  p_factory_id uuid default null,
  p_driver_id uuid default null,
  p_customer_maps_url text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح لك بإنشاء أوردر' using errcode = '42501';
  end if;

  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'messenger', auth.uid(), p_factory_id, p_driver_id, p_customer_maps_url
  );
end;
$$;

revoke all on function public.moderator_create_order from public;
grant execute on function public.moderator_create_order to authenticated;


-- ========== supabase/migrations/0021_editable_order_details.sql =======

-- 0021_editable_order_details.sql
--
-- "make every info about the order changeable" — until now, everything
-- captured on order creation (customer name/phone/address, the Google Maps
-- link, region, pieces count, piece details, color, work required, customer
-- notes) was write-once: set by create_order_internal and never touched by
-- any other RPC. A typo in the phone number or a corrected piece count had
-- no fix short of a fresh order. Adds one new Owner/Moderator-only RPC that
-- can update any of those fields on an existing order, at any status —
-- these are staff correcting/updating their own records, not a customer-
-- facing state change, so there's no lifecycle gate here (contrast with the
-- workflow RPCs in 0009, which do gate on status). Every edit is logged to
-- order_history with a summary of exactly which fields changed, so the
-- timeline still shows an honest record even though the row itself was
-- mutated in place.

create or replace function public.update_order_details(
  p_order_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_customer_maps_url text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text,
  p_color text,
  p_work_required text,
  p_customer_notes text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_new_maps_url text := nullif(trim(coalesce(p_customer_maps_url, '')), '');
  v_changes text := '';
begin
  -- coalesce(..., false): is_owner_or_moderator() can return sql NULL (no
  -- profile row for auth.uid(), e.g. a race with handle_new_user() or a
  -- deleted account) and plpgsql's `if not null` silently skips the branch
  -- instead of raising — coalescing keeps that case correctly rejected.
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح لك بتعديل بيانات الأوردر' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then
    raise exception 'الأوردر غير موجود';
  end if;

  if length(trim(coalesce(p_customer_name, ''))) = 0 then
    raise exception 'اسم العميل مطلوب' using errcode = '22023';
  end if;
  if length(trim(coalesce(p_customer_phone, ''))) < 8 then
    raise exception 'رقم هاتف العميل غير صالح' using errcode = '22023';
  end if;
  if length(trim(coalesce(p_customer_address, ''))) < 5 then
    raise exception 'العنوان قصير جدًا' using errcode = '22023';
  end if;
  if p_pieces_count is null or p_pieces_count < 1 then
    raise exception 'عدد القطع يجب أن يكون 1 على الأقل' using errcode = '22023';
  end if;

  -- A human-readable diff for the history log, built before the update
  -- overwrites the "before" values.
  if trim(v_order.customer_name) is distinct from trim(p_customer_name) then
    v_changes := v_changes || 'الاسم، ';
  end if;
  if trim(v_order.customer_phone) is distinct from trim(p_customer_phone) then
    v_changes := v_changes || 'الهاتف، ';
  end if;
  if trim(v_order.customer_address) is distinct from trim(p_customer_address) then
    v_changes := v_changes || 'العنوان، ';
  end if;
  if coalesce(v_order.customer_maps_url, '') is distinct from coalesce(v_new_maps_url, '') then
    v_changes := v_changes || 'رابط الخريطة، ';
  end if;
  if v_order.region_id is distinct from p_region_id then
    v_changes := v_changes || 'المنطقة، ';
  end if;
  if v_order.pieces_count is distinct from p_pieces_count then
    v_changes := v_changes || 'عدد القطع، ';
  end if;
  if coalesce(v_order.piece_details, '') is distinct from coalesce(p_piece_details, '') then
    v_changes := v_changes || 'تفاصيل القطع، ';
  end if;
  if coalesce(v_order.color, '') is distinct from coalesce(p_color, '') then
    v_changes := v_changes || 'اللون، ';
  end if;
  if coalesce(v_order.work_required, '') is distinct from coalesce(p_work_required, '') then
    v_changes := v_changes || 'المطلوب عمله، ';
  end if;
  if coalesce(v_order.customer_notes, '') is distinct from coalesce(p_customer_notes, '') then
    v_changes := v_changes || 'الملاحظات، ';
  end if;

  update public.orders set
    customer_name = trim(p_customer_name),
    customer_phone = trim(p_customer_phone),
    customer_address = trim(p_customer_address),
    customer_maps_url = v_new_maps_url,
    region_id = p_region_id,
    pieces_count = p_pieces_count,
    piece_details = p_piece_details,
    color = p_color,
    work_required = p_work_required,
    customer_notes = p_customer_notes
  where id = p_order_id;

  if v_changes <> '' then
    perform public.log_order_event(p_order_id, 'details_edited', v_order.status, v_order.status,
      'تم تعديل: ' || left(v_changes, length(v_changes) - 2));
  end if;
end;
$$;

revoke all on function public.update_order_details from public, anon, authenticated;
grant execute on function public.update_order_details to authenticated;


-- ========== supabase/migrations/0022_factory_permanent_order_history.sql 

-- 0022_factory_permanent_order_history.sql
--
-- Reported as: "I need full history for the factory and when the factory
-- press on the order num to show the order details and chats it does not
-- work and gives an error."
--
-- Root cause, confirmed by direct reproduction against a local Postgres
-- copy of the schema (walked a real order through the full lifecycle to
-- 'delivered' as owner/driver/factory test accounts, then queried as the
-- factory account): orders_select_factory, order_history_select_factory,
-- and factory_orders_view (0014/0015) all scope factory access to the
-- three *active* statuses only ('collected', 'at_factory', 'ready'). The
-- moment an order the factory handled moves past 'ready' (driver picks it
-- back up, delivers it, or the customer refuses it), every one of those
-- three loses the row entirely — not just from the dashboard tabs (which
-- is intentional/by design there), but from the factory's own order-detail
-- page too. getFactoryOrderById() (src/lib/data/orders.ts) goes through
-- factory_orders_view, so a 0-row result there makes the page call
-- notFound() — and since this app has no custom not-found.tsx, that's
-- Next.js's bare unstyled default 404, which is exactly what "gives an
-- error" describes from the factory's side. There was and is no separate
-- bug in the chat itself: can_read_order_channel() (0019) was already
-- written to check assigned_factory_id directly against the raw orders
-- row, bypassing RLS, specifically so factory chat access never expires —
-- confirmed this still works correctly even on a delivered order. The
-- *page* just never got that far, because the order lookup above it 404'd
-- first.
--
-- Fix: give a factory permanent access to any order it was ever actually
-- assigned to (assigned_factory_id = them), at any status — the exact same
-- design orders_select_driver already uses for drivers (see the comment on
-- can_read_order_channel in 0019: "orders_select_driver has no status
-- restriction (a driver keeps seeing their own past orders forever)").
-- Access to an *unassigned* order stays exactly as before: visible only
-- while it's still active, since once it closes there's no specific
-- factory it belongs to. This also directly delivers "full history for the
-- factory" — every order this fixes visibility for is now also queryable
-- as history (see listFactoryOrderHistory in src/lib/data/orders.ts and
-- the new "السجل" tab on /factory).

-- ---------- orders ----------

drop policy if exists orders_select_factory on public.orders;
create policy orders_select_factory on public.orders
  for select using (
    public.current_user_role() = 'factory'
    and (
      assigned_factory_id = auth.uid()
      or (assigned_factory_id is null and status in ('collected', 'at_factory', 'ready'))
    )
  );

-- ---------- order_history ----------

drop policy if exists order_history_select_factory on public.order_history;
create policy order_history_select_factory on public.order_history
  for select using (
    public.current_user_role() = 'factory'
    and exists (
      select 1 from public.orders o
      where o.id = order_history.order_id
        and (
          o.assigned_factory_id = auth.uid()
          or (o.assigned_factory_id is null and o.status in ('collected', 'at_factory', 'ready'))
        )
    )
  );

-- ---------- factory_orders_view ----------
--
-- Same WHERE-clause change as the two policies above (this view does its
-- own authorization — security_invoker = false — rather than relying on
-- the orders RLS, see the comment in 0014), plus driver_pickup_at and
-- delivered_at added to the selected columns so a completed order's
-- history row actually shows when the driver picked it back up and when
-- it was delivered, not just the three factory-side timestamps that were
-- enough while this view only ever showed in-progress orders. Dropped and
-- recreated rather than CREATE OR REPLACE for the same reason as 0014: new
-- columns land in the middle of the list and Postgres won't let an
-- existing view's column order change in place.

drop view if exists public.factory_orders_view;

create view public.factory_orders_view
with (security_invoker = false) as
select
  o.id,
  o.order_number,
  o.status,
  o.pieces_count,
  o.piece_details,
  o.color,
  o.work_required,
  o.assigned_driver_id,
  p.full_name as assigned_driver_name,
  o.assigned_factory_id,
  f.full_name as assigned_factory_name,
  f.address as assigned_factory_address,
  o.collected_at,
  o.handed_to_factory_at,
  o.factory_received_at,
  o.factory_ready_at,
  o.driver_pickup_at,
  o.delivered_at,
  o.created_at
from public.orders o
left join public.profiles p on p.id = o.assigned_driver_id
left join public.profiles f on f.id = o.assigned_factory_id
where
  public.current_user_role() in ('owner', 'moderator')
  or (
    public.current_user_role() = 'factory'
    and (
      o.assigned_factory_id = auth.uid()
      or (o.assigned_factory_id is null and o.status in ('collected', 'at_factory', 'ready'))
    )
  );

grant select on public.factory_orders_view to authenticated;


-- ========== supabase/migrations/0023_fix_factory_premature_visibility.sql 

-- 0023_fix_factory_premature_visibility.sql
--
-- Follow-up to 0022, found while investigating a report of an error when
-- opening an order from the factory side. Direct reproduction against a
-- local Postgres copy of the schema (create an order with both driver and
-- factory assigned at creation — mandatory since Round 4 — leave it at its
-- freshly-created 'assigned' status, then query as that factory) showed the
-- order visible in factory_orders_view even though the driver hasn't even
-- collected it from the customer yet, let alone brought it to the factory.
--
-- Root cause: 0022's "give a factory permanent access to any order it was
-- ever assigned to" used `assigned_factory_id = auth.uid()` with no status
-- qualifier at all, intending to cover collected/at_factory/ready (as
-- before) plus everything past it (with_driver/delivered/refused/
-- cancelled, the actual point of that migration). It didn't account for the
-- two statuses that come *before* collected — 'new' and 'assigned' — during
-- which the order hasn't reached anyone's hands yet. A factory account was
-- never supposed to see an order that far ahead of its own involvement (the
-- original 0014/0015 design deliberately withheld it until 'collected'),
-- and now, since factory assignment is mandatory at order creation, this
-- wasn't a narrow edge case — every single new order was affected from the
-- moment it's created.
--
-- Fix: the permanent-access branch now explicitly excludes 'new' and
-- 'assigned' (the only two statuses that make no sense for a factory to
-- see at all — nothing has happened yet that involves them). Every other
-- status keeps 0022's behavior unchanged: collected/at_factory/ready
-- through the existing active-status handling, and with_driver/delivered/
-- refused/cancelled permanently, for the same order, once the factory has
-- actually been involved.

-- ---------- orders ----------

drop policy if exists orders_select_factory on public.orders;
create policy orders_select_factory on public.orders
  for select using (
    public.current_user_role() = 'factory'
    and (
      (assigned_factory_id = auth.uid() and status not in ('new', 'assigned'))
      or (assigned_factory_id is null and status in ('collected', 'at_factory', 'ready'))
    )
  );

-- ---------- order_history ----------

drop policy if exists order_history_select_factory on public.order_history;
create policy order_history_select_factory on public.order_history
  for select using (
    public.current_user_role() = 'factory'
    and exists (
      select 1 from public.orders o
      where o.id = order_history.order_id
        and (
          (o.assigned_factory_id = auth.uid() and o.status not in ('new', 'assigned'))
          or (o.assigned_factory_id is null and o.status in ('collected', 'at_factory', 'ready'))
        )
    )
  );

-- ---------- factory_orders_view ----------
--
-- Same predicate change, no column changes this time — CREATE OR REPLACE
-- is fine here since the SELECT list is identical to 0022's.

create or replace view public.factory_orders_view
with (security_invoker = false) as
select
  o.id,
  o.order_number,
  o.status,
  o.pieces_count,
  o.piece_details,
  o.color,
  o.work_required,
  o.assigned_driver_id,
  p.full_name as assigned_driver_name,
  o.assigned_factory_id,
  f.full_name as assigned_factory_name,
  f.address as assigned_factory_address,
  o.collected_at,
  o.handed_to_factory_at,
  o.factory_received_at,
  o.factory_ready_at,
  o.driver_pickup_at,
  o.delivered_at,
  o.created_at
from public.orders o
left join public.profiles p on p.id = o.assigned_driver_id
left join public.profiles f on f.id = o.assigned_factory_id
where
  public.current_user_role() in ('owner', 'moderator')
  or (
    public.current_user_role() = 'factory'
    and (
      (o.assigned_factory_id = auth.uid() and o.status not in ('new', 'assigned'))
      or (o.assigned_factory_id is null and o.status in ('collected', 'at_factory', 'ready'))
    )
  );

grant select on public.factory_orders_view to authenticated;


-- ========== supabase/migrations/0024_pickup_code_owner_only_assignment_and_fair_auto_distribution.sql 

-- 0024_pickup_code_owner_only_assignment_and_fair_auto_distribution.sql
--
-- Three requests, shipped together since the third depends on groundwork
-- the other two don't touch:
--
--   1) "code for taking the order from the customer" — a pickup
--      confirmation code, mirroring the existing delivery code exactly:
--      generated at creation, only a bcrypt hash stored, the driver must
--      get it from the customer and enter it to mark the order collected.
--      Without this, a driver could tap "collected" without ever actually
--      visiting the customer, the same gap the delivery code already closes
--      on the other end of the trip.
--
--   2) "moderator cannot assign or edit or change drivers or factories and
--      adding new worker or factory only manager who can do that" — every
--      RPC that assigns/reassigns a driver or factory on an order, and
--      every account-creation path (driver/moderator/owner/factory), moves
--      from Owner-or-Moderator to Owner-only. approve_distribution() was
--      already Owner-only (migration 0009) and needs no change.
--
--   3) "when create driver or order ask for the region and the order will
--      be assigned auto for these drivers based on the region and for
--      places with more than order try to be fair for orders and also the
--      manager should confirm the assignment for each order manually
--      before it goes to the driver" — a driver account creation already
--      asks for coverage regions (see driver_regions, 0003, and the
--      "المناطق التي يغطيها" field in AddStaffDialog), and an order already
--      asks for a region (mandatory since 0004). What's new is automatic:
--      whenever an order is created with no explicit driver, the system
--      now picks the least-busy active driver who covers that region
--      itself (self-balancing over time, since "least busy" changes as
--      orders pile up) instead of leaving it to a human to notice and pick.
--      Crucially this auto-pick is only ever a *suggestion* — it sets
--      assigned_driver_id/suggested_driver_id but deliberately leaves
--      distribution_approved_at null, so orders_select_driver (0008) keeps
--      it invisible to the driver exactly like a manually-suggested pick
--      already was. The existing <DistributionPanel> UI and
--      approve_distribution() RPC (Owner-only already) are exactly the
--      "manager confirms before it goes to the driver" gate asked for here
--      — nothing new was needed there, only feeding it automatically
--      instead of requiring a human to open suggest_drivers() first.
--      Owner creating an order directly with an explicit driver keeps
--      today's immediate-approve behavior unchanged (that action already
--      *is* the manager's confirmation).

-- ========== 1) pickup confirmation code ==========

alter table public.orders add column if not exists pickup_code_hash text;
alter table public.orders add column if not exists failed_pickup_code_attempts integer not null default 0;
alter table public.orders add column if not exists pickup_code_last_attempt_at timestamptz;

comment on column public.orders.pickup_code_hash is
  'bcrypt hash of the code the driver must get from the customer to confirm pickup (driver_mark_collected) — same protection model as delivery_code_hash, just at the other end of the trip. Null for orders created before this migration; driver_mark_collected treats a null hash as "no code was ever issued" and skips the check rather than rejecting the driver forever.';

create table if not exists public.order_pickup_codes (
  order_id uuid primary key references public.orders (id) on delete cascade,
  code text not null,
  created_at timestamptz not null default now()
);

comment on table public.order_pickup_codes is
  'Plaintext pickup codes, mirroring order_delivery_codes (0016) exactly: RLS enabled with zero policies (every direct client request denied by default), reachable only through get_order_pickup_code() below.';

alter table public.order_pickup_codes enable row level security;
revoke all on public.order_pickup_codes from public, anon, authenticated;

create or replace function public.get_order_pickup_code(p_order_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select code into v_code from public.order_pickup_codes where order_id = p_order_id;
  return v_code;
end;
$$;

revoke all on function public.get_order_pickup_code from public;
grant execute on function public.get_order_pickup_code to authenticated;

-- new_order_result gains pickup_code alongside delivery_code — ADD ATTRIBUTE
-- extends the composite type in place (unlike DROP TYPE ... CASCADE, this
-- doesn't touch any function that returns it), so create_order_internal and
-- every function that calls it keep working unchanged except for the one
-- new field this migration actually sets. Postgres has no
-- "ADD ATTRIBUTE IF NOT EXISTS" for composite types, so this is wrapped in
-- an existence check to make it safe to re-run against a database that
-- already picked up this change (this migration re-applied on top of
-- itself, or a partially-applied migration history).
do $$
begin
  if not exists (
    select 1
    from pg_attribute a
    join pg_type t on t.typrelid = a.attrelid
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public'
      and t.typname = 'new_order_result'
      and a.attname = 'pickup_code'
      and not a.attisdropped
  ) then
    alter type public.new_order_result add attribute pickup_code text;
  end if;
end $$;

-- driver_mark_collected(uuid) -> driver_mark_collected(uuid, text) and
-- void -> boolean (so the UI can tell "wrong code" apart from a hard
-- error, exactly like driver_deliver_to_customer already does) is a
-- signature AND return-type change, so the old function has to be dropped
-- first — CREATE OR REPLACE can't change a return type.
drop function if exists public.driver_mark_collected(uuid);

create or replace function public.driver_mark_collected(p_order_id uuid, p_code text)
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
  if v_order.status <> 'assigned' then raise exception 'الأوردر ليس بحالة تسمح بتسجيل الاستلام من العميل'; end if;

  -- Orders created before this migration never had a pickup code issued —
  -- treat that as "nothing to check" rather than permanently blocking
  -- collection on those pre-existing orders (same spirit as the delivery
  -- code reveal's "غير متاح" state for old orders, just applied to the
  -- check itself instead of a lookup).
  if v_order.pickup_code_hash is null then
    v_ok := true;
  else
    v_ok := (crypt(coalesce(p_code, ''), v_order.pickup_code_hash) = v_order.pickup_code_hash);
  end if;

  if v_ok then
    update public.orders set status = 'collected', collected_at = now() where id = p_order_id;
    perform public.log_order_event(p_order_id, 'collected_from_customer', 'assigned', 'collected', 'تم استلام الأوردر من العميل');
    perform public.notify_staff(p_order_id, 'order_collected',
      'تم استلام الأوردر ' || v_order.order_number || ' من العميل', null, auth.uid());
  else
    update public.orders
      set failed_pickup_code_attempts = failed_pickup_code_attempts + 1,
          pickup_code_last_attempt_at = now()
      where id = p_order_id;
    perform public.log_order_event(p_order_id, 'pickup_code_mismatch', 'assigned', 'assigned', 'محاولة استلام من العميل بكود غير صحيح');
  end if;

  return v_ok;
end;
$$;

revoke all on function public.driver_mark_collected(uuid, text) from public;
grant execute on function public.driver_mark_collected(uuid, text) to authenticated;

-- ========== 2) driver/factory assignment and staff creation: Owner-only ==========
--
-- Every one of these already had is_owner_or_moderator() as its authorization
-- check (see 0009, 0018, 0019) — only that one check changes to is_owner(),
-- nothing else about their bodies. Kept as separate create-or-replace blocks
-- (same signatures as their current versions) rather than a bulk find/replace
-- across files, so this migration is a readable, self-contained diff of
-- exactly what changed.

create or replace function public.set_order_distribution(p_order_id uuid, p_driver_id uuid, p_is_suggestion boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status order_status;
begin
  if not public.is_owner() then
    raise exception 'تحديد المندوب من صلاحية المدير فقط' using errcode = '42501';
  end if;

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

create or replace function public.clear_order_distribution(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status order_status;
begin
  if not public.is_owner() then
    raise exception 'تحديد المندوب من صلاحية المدير فقط' using errcode = '42501';
  end if;

  select status into v_status from public.orders where id = p_order_id for update;
  if v_status <> 'new' then
    raise exception 'لا يمكن إلغاء توزيع أوردر تم اعتماده بالفعل';
  end if;

  update public.orders set assigned_driver_id = null where id = p_order_id;
  perform public.log_order_event(p_order_id, 'distribution_cleared', v_status, v_status, 'تم إلغاء التوزيع المقترح');
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
  if not public.is_owner() then
    raise exception 'تغيير المندوب من صلاحية المدير فقط' using errcode = '42501';
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
  if not public.is_owner() then
    raise exception 'تغيير المصنع من صلاحية المدير فقط' using errcode = '42501';
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

-- ========== 3) fair, region-based auto-suggestion at order creation ==========

-- The least-busy active driver who covers p_region_id, or null if none do
-- (an order with no covering driver is left unassigned, same as it would be
-- if a human opened suggest_drivers() and found nobody to pick — it is NOT
-- assigned to an out-of-region driver just to fill the field). "Least busy"
-- is the same active_orders_count suggest_drivers() already ranks by, so
-- this is that function's own ranking, just applied automatically instead
-- of requiring a human to open the panel first — and because it's evaluated
-- fresh for every new order, load naturally levels out across a region's
-- drivers over time instead of always stacking onto whoever's first alphabetically.
create or replace function public.pick_fair_driver_for_region(p_region_id uuid)
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

create or replace function public.create_order_internal(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text,
  p_color text,
  p_work_required text,
  p_customer_notes text,
  p_source order_source,
  p_created_by uuid,
  p_factory_id uuid default null,
  p_driver_id uuid default null,
  p_customer_maps_url text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := public.generate_delivery_code();
  v_pickup_code text := public.generate_delivery_code();
  v_order public.orders;
  v_result public.new_order_result;
  v_factory public.profiles;
  v_driver public.profiles;
  v_new_status public.order_status;
  v_maps_url text := nullif(trim(coalesce(p_customer_maps_url, '')), '');
  v_auto_driver_id uuid;
  v_auto_driver_name text;
begin
  if length(trim(p_customer_name)) = 0 then
    raise exception 'اسم العميل مطلوب' using errcode = '22023';
  end if;
  if length(trim(p_customer_phone)) < 8 then
    raise exception 'رقم هاتف العميل غير صالح' using errcode = '22023';
  end if;
  if p_pieces_count is null or p_pieces_count < 1 then
    raise exception 'عدد القطع يجب أن يكون 1 على الأقل' using errcode = '22023';
  end if;

  if p_factory_id is not null then
    select * into v_factory from public.profiles where id = p_factory_id;
    if v_factory is null or v_factory.role <> 'factory' or not v_factory.is_active then
      raise exception 'المصنع المحدد غير صالح' using errcode = '22023';
    end if;
  end if;

  if p_driver_id is not null then
    select * into v_driver from public.profiles where id = p_driver_id;
    if v_driver is null or v_driver.role <> 'driver' or not v_driver.is_active then
      raise exception 'المندوب المحدد غير صالح' using errcode = '22023';
    end if;
  end if;

  insert into public.orders (
    customer_name, customer_phone, customer_address, customer_maps_url, region_id,
    pieces_count, piece_details, color, work_required, customer_notes,
    source, created_by, delivery_code_hash, pickup_code_hash, assigned_factory_id
  ) values (
    trim(p_customer_name), trim(p_customer_phone), trim(p_customer_address), v_maps_url, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    p_source, p_created_by, crypt(v_code, gen_salt('bf')), crypt(v_pickup_code, gen_salt('bf')), p_factory_id
  )
  returning * into v_order;

  insert into public.order_delivery_codes (order_id, code) values (v_order.id, v_code);
  insert into public.order_pickup_codes (order_id, code) values (v_order.id, v_pickup_code);

  perform public.log_order_event(v_order.id, 'created', null, 'new',
    'تم إنشاء الأوردر عبر ' || case when p_source = 'website' then 'الموقع' else 'Messenger' end);

  if p_driver_id is not null then
    -- Explicit driver given by the caller (an Owner creating an order
    -- directly) — same immediate-approve behavior as before this
    -- migration; the Owner's own pick already *is* the manager's
    -- confirmation, so there's nothing left to approve separately.
    v_new_status := case when v_order.status = 'new' then 'assigned' else v_order.status end;

    update public.orders
      set assigned_driver_id = p_driver_id,
          distribution_approved_at = now(),
          distribution_approved_by = p_created_by,
          status = v_new_status
      where id = v_order.id;

    v_order.status := v_new_status;

    perform public.log_order_event(v_order.id, 'driver_reassigned', 'new', v_new_status,
      'تم تعيين مندوب عند إنشاء الأوردر: ' || v_driver.full_name);

    perform public.notify_user(p_driver_id, v_order.id, 'order_assigned',
      'تم إسناد أوردر إليك ' || v_order.order_number, 'العميل: ' || v_order.customer_name);
  else
    -- No driver given — try to fairly auto-suggest one from the order's own
    -- region. This only ever sets a *pending* suggestion (assigned_driver_id
    -- + suggested_driver_id, status stays 'new', distribution_approved_at
    -- stays null) — orders_select_driver (0008) keeps it invisible to the
    -- driver until an Owner calls approve_distribution(), exactly the
    -- "manager confirms before it reaches the driver" requirement. If no
    -- active driver covers this region, the order is simply left unassigned,
    -- same as it always was — an Owner can still pick manually from
    -- <DistributionPanel> (suggest_drivers() ranks every active driver, not
    -- just ones covering the region, as a fallback).
    v_auto_driver_id := public.pick_fair_driver_for_region(p_region_id);
    if v_auto_driver_id is not null then
      update public.orders
        set assigned_driver_id = v_auto_driver_id,
            suggested_driver_id = v_auto_driver_id
        where id = v_order.id;

      select full_name into v_auto_driver_name from public.profiles where id = v_auto_driver_id;
      perform public.log_order_event(v_order.id, 'distribution_set', 'new', 'new',
        'تم اقتراح مندوب تلقائيًا حسب المنطقة: ' || v_auto_driver_name || ' (بانتظار اعتماد المدير)');
    end if;
  end if;

  perform public.notify_role('owner', v_order.id, 'new_order', 'أوردر جديد ' || v_order.order_number,
    'تم استلام أوردر جديد من ' || v_order.customer_name);

  v_result.order_id := v_order.id;
  v_result.order_number := v_order.order_number;
  v_result.delivery_code := v_code;
  v_result.pickup_code := v_pickup_code;
  return v_result;
end;
$$;

revoke all on function public.create_order_internal from public, anon, authenticated;

create or replace function public.moderator_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null,
  p_factory_id uuid default null,
  p_driver_id uuid default null,
  p_customer_maps_url text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح لك بإنشاء أوردر' using errcode = '42501';
  end if;

  -- A Moderator can create the order itself, but picking who handles it is
  -- the manager's job now (see this migration's header) — the frontend
  -- already never shows these fields to a Moderator, this is the
  -- server-side half of that same rule (defense in depth, same pattern as
  -- every other role check in this file).
  if not public.is_owner() and (p_driver_id is not null or p_factory_id is not null) then
    raise exception 'تحديد المندوب أو المصنع من صلاحية المدير فقط' using errcode = '42501';
  end if;

  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'messenger', auth.uid(), p_factory_id, p_driver_id, p_customer_maps_url
  );
end;
$$;

revoke all on function public.moderator_create_order from public;
grant execute on function public.moderator_create_order to authenticated;


-- ========== supabase/migrations/0025_region_free_text_matching.sql ====

-- 0025_region_free_text_matching.sql
--
-- Reported as: "the منطقة should be different from the city and it should
-- be used for matching with the orders in the same منطقة and match 100%
-- and should written by keybord not list and mandatory."
--
-- Until now, المنطقة was picked from a fixed dropdown of regions an Owner
-- had to pre-create from Team management first — in practice that list
-- tended to fill up with broad, city-level entries, which is exactly what
-- was reported as "the منطقة should be different from the city": too
-- coarse to be useful for fair, same-area driver matching. This migration
-- doesn't add a separate "city" concept — it makes المنطقة itself granular
-- and frictionless to add, by switching the *input* from "pick off a list"
-- to "type it": both the order's own region and a driver's covered-areas
-- field now take free-typed text. To keep matching genuinely 100% exact
-- (a typo silently breaking a driver's auto-assignment would be worse than
-- the dropdown it replaces), a typed name is resolved through
-- find_or_create_region() below, which normalizes (trim + collapse
-- whitespace) and reuses the existing public.regions row for that exact
-- name if one exists, or creates it on the spot if not. Matching itself is
-- still the same exact region_id equality pick_fair_driver_for_region()
-- (0024) already used — only how a name becomes that id has changed, so
-- "match 100%" is actually easier to guarantee now, not looser: two people
-- who type the same area name (after normalizing) always resolve to the
-- same canonical region row.
--
-- region_id itself is deliberately left nullable at the column level (no
-- database-level NOT NULL added here) — this migration has no way to
-- backfill whatever null region_id rows may already exist on the live
-- database from here. "Mandatory" is instead enforced at the two layers
-- that actually gate new writes: the order form's Zod schema client-side,
-- and find_or_create_region() itself raising if the typed name is empty —
-- every one of the SQL entry points below (public_create_order,
-- moderator_create_order, update_order_details) now runs through it.

-- ========== find_or_create_region: the shared name -> id resolver ==========

create or replace function public.find_or_create_region(p_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_id uuid;
begin
  if length(v_name) < 2 then
    raise exception 'اكتب اسم المنطقة' using errcode = '22023';
  end if;
  if length(v_name) > 100 then
    raise exception 'اسم المنطقة طويل جدًا' using errcode = '22023';
  end if;

  -- regions.name already has a UNIQUE constraint (0003) — this upsert is
  -- the atomic, race-safe "find it, or create it" this feature needs: two
  -- staff typing the same new area name at the same moment both resolve to
  -- the one row that wins, never two near-duplicate regions.
  insert into public.regions (name) values (v_name)
  on conflict (name) do update set name = excluded.name
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.find_or_create_region from public;
grant execute on function public.find_or_create_region to authenticated;

-- ========== driver coverage areas: typed, same resolver, one atomic replace ==========

create or replace function public.set_driver_regions_by_name(p_driver_id uuid, p_region_names text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
  v_id uuid;
  v_ids uuid[] := '{}';
begin
  -- Editing a driver's covered areas was deliberately left Owner+Moderator
  -- (not narrowed to Owner-only like assignment/new-account-creation in
  -- 0024) — same authorization this replaces (setDriverRegionsAction).
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  if not exists (select 1 from public.profiles where id = p_driver_id and role = 'driver') then
    raise exception 'هذا الحساب ليس مندوبًا';
  end if;

  foreach v_name in array coalesce(p_region_names, '{}'::text[])
  loop
    if length(trim(coalesce(v_name, ''))) > 0 then
      v_id := public.find_or_create_region(v_name);
      if not (v_id = any(v_ids)) then
        v_ids := array_append(v_ids, v_id);
      end if;
    end if;
  end loop;

  delete from public.driver_regions where driver_id = p_driver_id;

  if array_length(v_ids, 1) > 0 then
    insert into public.driver_regions (driver_id, region_id)
    select p_driver_id, x from unnest(v_ids) as x;
  end if;
end;
$$;

revoke all on function public.set_driver_regions_by_name from public;
grant execute on function public.set_driver_regions_by_name to authenticated;

-- ========== order creation / edit: p_region_id uuid -> p_region_name text ==========

drop function if exists public.create_order_internal(
  text, text, text, uuid, integer, text, text, text, text, order_source, uuid, uuid, uuid, text
);

create or replace function public.create_order_internal(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_name text,
  p_pieces_count integer,
  p_piece_details text,
  p_color text,
  p_work_required text,
  p_customer_notes text,
  p_source order_source,
  p_created_by uuid,
  p_factory_id uuid default null,
  p_driver_id uuid default null,
  p_customer_maps_url text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := public.generate_delivery_code();
  v_pickup_code text := public.generate_delivery_code();
  v_region_id uuid;
  v_order public.orders;
  v_result public.new_order_result;
  v_factory public.profiles;
  v_driver public.profiles;
  v_new_status public.order_status;
  v_maps_url text := nullif(trim(coalesce(p_customer_maps_url, '')), '');
  v_auto_driver_id uuid;
  v_auto_driver_name text;
begin
  if length(trim(p_customer_name)) = 0 then
    raise exception 'اسم العميل مطلوب' using errcode = '22023';
  end if;
  if length(trim(p_customer_phone)) < 8 then
    raise exception 'رقم هاتف العميل غير صالح' using errcode = '22023';
  end if;
  if p_pieces_count is null or p_pieces_count < 1 then
    raise exception 'عدد القطع يجب أن يكون 1 على الأقل' using errcode = '22023';
  end if;

  -- Mandatory + resolved to a canonical region row here — after the basic
  -- field checks above, so an invalid name never gets created as a
  -- side effect of a request that was going to fail anyway.
  v_region_id := public.find_or_create_region(p_region_name);

  if p_factory_id is not null then
    select * into v_factory from public.profiles where id = p_factory_id;
    if v_factory is null or v_factory.role <> 'factory' or not v_factory.is_active then
      raise exception 'المصنع المحدد غير صالح' using errcode = '22023';
    end if;
  end if;

  if p_driver_id is not null then
    select * into v_driver from public.profiles where id = p_driver_id;
    if v_driver is null or v_driver.role <> 'driver' or not v_driver.is_active then
      raise exception 'المندوب المحدد غير صالح' using errcode = '22023';
    end if;
  end if;

  insert into public.orders (
    customer_name, customer_phone, customer_address, customer_maps_url, region_id,
    pieces_count, piece_details, color, work_required, customer_notes,
    source, created_by, delivery_code_hash, pickup_code_hash, assigned_factory_id
  ) values (
    trim(p_customer_name), trim(p_customer_phone), trim(p_customer_address), v_maps_url, v_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    p_source, p_created_by, crypt(v_code, gen_salt('bf')), crypt(v_pickup_code, gen_salt('bf')), p_factory_id
  )
  returning * into v_order;

  insert into public.order_delivery_codes (order_id, code) values (v_order.id, v_code);
  insert into public.order_pickup_codes (order_id, code) values (v_order.id, v_pickup_code);

  perform public.log_order_event(v_order.id, 'created', null, 'new',
    'تم إنشاء الأوردر عبر ' || case when p_source = 'website' then 'الموقع' else 'Messenger' end);

  if p_driver_id is not null then
    v_new_status := case when v_order.status = 'new' then 'assigned' else v_order.status end;

    update public.orders
      set assigned_driver_id = p_driver_id,
          distribution_approved_at = now(),
          distribution_approved_by = p_created_by,
          status = v_new_status
      where id = v_order.id;

    v_order.status := v_new_status;

    perform public.log_order_event(v_order.id, 'driver_reassigned', 'new', v_new_status,
      'تم تعيين مندوب عند إنشاء الأوردر: ' || v_driver.full_name);

    perform public.notify_user(p_driver_id, v_order.id, 'order_assigned',
      'تم إسناد أوردر إليك ' || v_order.order_number, 'العميل: ' || v_order.customer_name);
  else
    -- Same fair, region-based suggestion as 0024 — only the input changed,
    -- not the matching itself: v_region_id is the same canonical id
    -- pick_fair_driver_for_region() always matched on before this.
    v_auto_driver_id := public.pick_fair_driver_for_region(v_region_id);
    if v_auto_driver_id is not null then
      update public.orders
        set assigned_driver_id = v_auto_driver_id,
            suggested_driver_id = v_auto_driver_id
        where id = v_order.id;

      select full_name into v_auto_driver_name from public.profiles where id = v_auto_driver_id;
      perform public.log_order_event(v_order.id, 'distribution_set', 'new', 'new',
        'تم اقتراح مندوب تلقائيًا حسب المنطقة: ' || v_auto_driver_name || ' (بانتظار اعتماد المدير)');
    end if;
  end if;

  perform public.notify_role('owner', v_order.id, 'new_order', 'أوردر جديد ' || v_order.order_number,
    'تم استلام أوردر جديد من ' || v_order.customer_name);

  v_result.order_id := v_order.id;
  v_result.order_number := v_order.order_number;
  v_result.delivery_code := v_code;
  v_result.pickup_code := v_pickup_code;
  return v_result;
end;
$$;

revoke all on function public.create_order_internal from public, anon, authenticated;

drop function if exists public.public_create_order(
  text, text, text, uuid, integer, text, text, text, text, uuid, text
);

create or replace function public.public_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_name text,
  p_pieces_count integer,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null,
  p_factory_id uuid default null,
  p_customer_maps_url text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_name,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'website', null, p_factory_id, null, p_customer_maps_url
  );
end;
$$;

revoke all on function public.public_create_order from public;
grant execute on function public.public_create_order to anon, authenticated;

drop function if exists public.moderator_create_order(
  text, text, text, uuid, integer, text, text, text, text, uuid, uuid, text
);

create or replace function public.moderator_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_name text,
  p_pieces_count integer,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null,
  p_factory_id uuid default null,
  p_driver_id uuid default null,
  p_customer_maps_url text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح لك بإنشاء أوردر' using errcode = '42501';
  end if;

  if not public.is_owner() and (p_driver_id is not null or p_factory_id is not null) then
    raise exception 'تحديد المندوب أو المصنع من صلاحية المدير فقط' using errcode = '42501';
  end if;

  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_name,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'messenger', auth.uid(), p_factory_id, p_driver_id, p_customer_maps_url
  );
end;
$$;

revoke all on function public.moderator_create_order from public;
grant execute on function public.moderator_create_order to authenticated;

drop function if exists public.update_order_details(
  uuid, text, text, text, text, uuid, integer, text, text, text, text
);

create or replace function public.update_order_details(
  p_order_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_customer_maps_url text,
  p_region_name text,
  p_pieces_count integer,
  p_piece_details text,
  p_color text,
  p_work_required text,
  p_customer_notes text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_new_maps_url text := nullif(trim(coalesce(p_customer_maps_url, '')), '');
  v_region_id uuid;
  v_changes text := '';
begin
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح لك بتعديل بيانات الأوردر' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then
    raise exception 'الأوردر غير موجود';
  end if;

  if length(trim(coalesce(p_customer_name, ''))) = 0 then
    raise exception 'اسم العميل مطلوب' using errcode = '22023';
  end if;
  if length(trim(coalesce(p_customer_phone, ''))) < 8 then
    raise exception 'رقم هاتف العميل غير صالح' using errcode = '22023';
  end if;
  if length(trim(coalesce(p_customer_address, ''))) < 5 then
    raise exception 'العنوان قصير جدًا' using errcode = '22023';
  end if;
  if p_pieces_count is null or p_pieces_count < 1 then
    raise exception 'عدد القطع يجب أن يكون 1 على الأقل' using errcode = '22023';
  end if;

  v_region_id := public.find_or_create_region(p_region_name);

  if trim(v_order.customer_name) is distinct from trim(p_customer_name) then
    v_changes := v_changes || 'الاسم، ';
  end if;
  if trim(v_order.customer_phone) is distinct from trim(p_customer_phone) then
    v_changes := v_changes || 'الهاتف، ';
  end if;
  if trim(v_order.customer_address) is distinct from trim(p_customer_address) then
    v_changes := v_changes || 'العنوان، ';
  end if;
  if coalesce(v_order.customer_maps_url, '') is distinct from coalesce(v_new_maps_url, '') then
    v_changes := v_changes || 'رابط الخريطة، ';
  end if;
  if v_order.region_id is distinct from v_region_id then
    v_changes := v_changes || 'المنطقة، ';
  end if;
  if v_order.pieces_count is distinct from p_pieces_count then
    v_changes := v_changes || 'عدد القطع، ';
  end if;
  if coalesce(v_order.piece_details, '') is distinct from coalesce(p_piece_details, '') then
    v_changes := v_changes || 'تفاصيل القطع، ';
  end if;
  if coalesce(v_order.color, '') is distinct from coalesce(p_color, '') then
    v_changes := v_changes || 'اللون، ';
  end if;
  if coalesce(v_order.work_required, '') is distinct from coalesce(p_work_required, '') then
    v_changes := v_changes || 'المطلوب عمله، ';
  end if;
  if coalesce(v_order.customer_notes, '') is distinct from coalesce(p_customer_notes, '') then
    v_changes := v_changes || 'الملاحظات، ';
  end if;

  update public.orders set
    customer_name = trim(p_customer_name),
    customer_phone = trim(p_customer_phone),
    customer_address = trim(p_customer_address),
    customer_maps_url = v_new_maps_url,
    region_id = v_region_id,
    pieces_count = p_pieces_count,
    piece_details = p_piece_details,
    color = p_color,
    work_required = p_work_required,
    customer_notes = p_customer_notes
  where id = p_order_id;

  if v_changes <> '' then
    perform public.log_order_event(p_order_id, 'details_edited', v_order.status, v_order.status,
      'تم تعديل: ' || left(v_changes, length(v_changes) - 2));
  end if;
end;
$$;

revoke all on function public.update_order_details from public, anon, authenticated;
grant execute on function public.update_order_details to authenticated;


-- ========== supabase/migrations/0026_pickup_points.sql ================

-- Pickup points — drop-off locations for collected cooking utensils.
--
-- EL REWAD only runs two factories (Cairo, Alexandria), but drivers cover
-- many more neighborhoods than that — so rather than every driver making a
-- long trip to one of the two factories after every single collection,
-- Owner/Moderator can set up local pickup points where drivers drop off
-- what they've collected. Getting a pickup point's accumulated utensils to
-- the actual factory is a separate, bulk logistics step this app doesn't
-- track order-by-order (per the round-16 decision) — pickup points are
-- purely a "where do I go" reference for drivers, modeled the same
-- region-scoped way driver coverage areas already are.
--
-- Not another `profiles` role: a pickup point has no login of its own, so a
-- plain table (mirroring the factory's own address/lat/lng/maps_url shape,
-- see mapsUrlFor()) is the right fit, not an auth user.

create table if not exists public.pickup_points (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text,
  lat double precision,
  lng double precision,
  maps_url text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.pickup_points is
  'Drop-off locations for collected cooking utensils, region-scoped like driver coverage areas (see pickup_point_regions). The pickup-point-to-factory leg itself is not tracked here — see the migration header comment.';

drop trigger if exists set_pickup_points_updated_at on public.pickup_points;
create trigger set_pickup_points_updated_at
  before update on public.pickup_points
  for each row execute function public.set_updated_at();

create table if not exists public.pickup_point_regions (
  pickup_point_id uuid not null references public.pickup_points(id) on delete cascade,
  region_id uuid not null references public.regions(id) on delete cascade,
  primary key (pickup_point_id, region_id)
);

comment on table public.pickup_point_regions is
  'Which منطقة name(s) each pickup point covers — same shape as driver_regions.';

alter table public.pickup_points enable row level security;
alter table public.pickup_point_regions enable row level security;

-- Read: any signed-in staff member. This is just reference data (a name,
-- an address, a map link) — nothing sensitive — and drivers specifically
-- need to read it to know where to go, same reasoning as why every role
-- can already read `regions`.
drop policy if exists pickup_points_select_staff on public.pickup_points;
create policy pickup_points_select_staff on public.pickup_points
  for select using (auth.role() = 'authenticated');

drop policy if exists pickup_point_regions_select_staff on public.pickup_point_regions;
create policy pickup_point_regions_select_staff on public.pickup_point_regions
  for select using (auth.role() = 'authenticated');

-- Write access is Owner/Moderator-only, entirely through the
-- security-definer RPCs below (same pattern as regions/driver_regions) —
-- no direct INSERT/UPDATE/DELETE policy is needed on either table.

grant select on public.pickup_points to authenticated;
grant select on public.pickup_point_regions to authenticated;

-- ---------- create / update / activate ----------

create or replace function public.create_pickup_point(
  p_name text,
  p_address text,
  p_maps_url text,
  p_region_names text[]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_name text;
  v_region_id uuid;
begin
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'اسم نقطة التجميع مطلوب' using errcode = '22023';
  end if;

  insert into public.pickup_points (name, address, maps_url)
  values (
    trim(p_name),
    nullif(trim(coalesce(p_address, '')), ''),
    nullif(trim(coalesce(p_maps_url, '')), '')
  )
  returning id into v_id;

  -- Same find-or-create-by-name resolver the region feature already uses
  -- (migration 0025) — typing a brand-new منطقة name here creates it too.
  foreach v_name in array coalesce(p_region_names, '{}'::text[])
  loop
    if length(trim(coalesce(v_name, ''))) > 0 then
      v_region_id := public.find_or_create_region(v_name);
      insert into public.pickup_point_regions (pickup_point_id, region_id)
        values (v_id, v_region_id)
        on conflict do nothing;
    end if;
  end loop;

  return v_id;
end;
$$;
revoke all on function public.create_pickup_point(text, text, text, text[]) from public;
grant execute on function public.create_pickup_point(text, text, text, text[]) to authenticated;

create or replace function public.update_pickup_point(
  p_id uuid,
  p_name text,
  p_address text,
  p_maps_url text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'اسم نقطة التجميع مطلوب' using errcode = '22023';
  end if;

  update public.pickup_points
    set name = trim(p_name),
        address = nullif(trim(coalesce(p_address, '')), ''),
        maps_url = nullif(trim(coalesce(p_maps_url, '')), '')
    where id = p_id;

  if not found then
    raise exception 'نقطة التجميع غير موجودة';
  end if;
end;
$$;
revoke all on function public.update_pickup_point(uuid, text, text, text) from public;
grant execute on function public.update_pickup_point(uuid, text, text, text) to authenticated;

create or replace function public.set_pickup_point_active(p_id uuid, p_is_active boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  update public.pickup_points set is_active = p_is_active where id = p_id;
  if not found then
    raise exception 'نقطة التجميع غير موجودة';
  end if;
end;
$$;
revoke all on function public.set_pickup_point_active(uuid, boolean) from public;
grant execute on function public.set_pickup_point_active(uuid, boolean) to authenticated;

create or replace function public.set_pickup_point_regions(p_pickup_point_id uuid, p_region_names text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
  v_id uuid;
  v_ids uuid[] := '{}';
begin
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if not exists (select 1 from public.pickup_points where id = p_pickup_point_id) then
    raise exception 'نقطة التجميع غير موجودة';
  end if;

  foreach v_name in array coalesce(p_region_names, '{}'::text[]) loop
    if length(trim(coalesce(v_name, ''))) > 0 then
      v_id := public.find_or_create_region(v_name);
      if not (v_id = any(v_ids)) then
        v_ids := array_append(v_ids, v_id);
      end if;
    end if;
  end loop;

  delete from public.pickup_point_regions where pickup_point_id = p_pickup_point_id;
  if array_length(v_ids, 1) > 0 then
    insert into public.pickup_point_regions (pickup_point_id, region_id)
      select p_pickup_point_id, x from unnest(v_ids) as x;
  end if;
end;
$$;
revoke all on function public.set_pickup_point_regions(uuid, text[]) from public;
grant execute on function public.set_pickup_point_regions(uuid, text[]) to authenticated;


-- ========== supabase/migrations/0027_factory_only_order_creation.sql ==

-- 0027_factory_only_order_creation.sql
--
-- "when creating orders choose the factory only not the driver and it
-- should [be] assigned auto" — clarified: the Moderator now also gets a
-- factory picker at order creation (previously Owner-only, migration 0024),
-- but nobody picks a driver manually at creation time anymore, not even
-- the Owner — it is always the fair region-based auto-pick
-- (create_order_internal's p_driver_id-is-null branch, unchanged since
-- 0024/0025), and it always stays a *pending suggestion* until the Owner
-- approves or reassigns it from <DistributionPanel> — same gate a
-- Moderator's order already went through, now also applied to an Owner's
-- own orders. Assigning/reassigning/approving a driver after creation
-- remains Owner-only (set_order_distribution / reassign_order_driver /
-- approve_distribution / clear_order_distribution — all unchanged, already
-- Owner-only since 0024).
--
-- create_order_internal itself needs no change: it has done exactly the
-- right thing since 0024 (then 0025's p_region_id -> p_region_name switch)
-- whenever p_driver_id is null. Only moderator_create_order's gate
-- changes — factory_id opens up to any staff member who can create an
-- order, and driver_id is rejected from everyone rather than only from a
-- Moderator. Signature (text,text,text,text,integer,text,text,text,text,
-- uuid,uuid,text) is unchanged from 0025 — only the body changes, so this
-- is a plain CREATE OR REPLACE, no drop/ambiguity risk.
create or replace function public.moderator_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_name text,
  p_pieces_count integer,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null,
  p_factory_id uuid default null,
  p_driver_id uuid default null,
  p_customer_maps_url text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح لك بإنشاء أوردر' using errcode = '42501';
  end if;

  -- The driver is never picked directly at order creation by anyone,
  -- Owner included, as of this migration — it's always the fair
  -- region-based auto-suggestion, pending the Owner's approval. The
  -- frontend never sends p_driver_id from this form anymore; this is the
  -- server-side half of that rule (defense in depth, same pattern as
  -- every other role check in this file).
  if p_driver_id is not null then
    raise exception 'يتم تعيين المندوب تلقائيًا عند إنشاء الأوردر، لا يمكن اختياره يدويًا' using errcode = '42501';
  end if;

  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_name,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'messenger', auth.uid(), p_factory_id, null, p_customer_maps_url
  );
end;
$$;

revoke all on function public.moderator_create_order(text, text, text, text, integer, text, text, text, text, uuid, uuid, text) from public;
grant execute on function public.moderator_create_order(text, text, text, text, integer, text, text, text, text, uuid, uuid, text) to authenticated;


-- ========== supabase/migrations/0028_remove_pickup_points.sql =========

-- 0028_remove_pickup_points.sql
--
-- Rolls back the pickup points feature added in 0026 entirely, per a later
-- decision to cancel it rather than fold it into order creation. Written
-- so it's safe to run whether or not 0026 was ever applied to this
-- database — every drop uses IF EXISTS, and drop table ... cascade takes
-- pickup_point_regions (and its FK back to pickup_points) with it, so the
-- table order below doesn't actually matter, but is kept parent-last for
-- clarity anyway.
--
-- 0026/0027 are left in place, unedited, as history — this migration is
-- the reversal, not a rewrite of the past.

drop function if exists public.set_pickup_point_regions(uuid, text[]);
drop function if exists public.set_pickup_point_active(uuid, boolean);
drop function if exists public.update_pickup_point(uuid, text, text, text);
drop function if exists public.create_pickup_point(text, text, text, text[]);

drop table if exists public.pickup_point_regions cascade;
drop table if exists public.pickup_points cascade;


-- ========== supabase/migrations/0029_driver_chat_hidden_after_reassignment.sql 

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


-- ========== supabase/migrations/0030_owner_only_cancel_and_no_moderator_team.sql 

-- 0030_owner_only_cancel_and_no_moderator_team.sql
--
-- "the moderator should not see the team tab and cannot cancel the order"
-- (the Team tab itself is a frontend-only concern — no schema change there,
-- see the app-side commit removing /moderator/team and its nav item) —
-- this migration is the other half: owner_cancel_order, despite its name,
-- has allowed Owner *or* Moderator since it was first written (0009/0019).
-- Lock it to the Owner alone, same is_owner() check every other
-- Owner-only RPC in this app already uses. Everything else a Moderator
-- could do on an order (create, edit its details, chat) is unchanged —
-- only cancelling and, already since migration 0024, picking/changing the
-- driver or factory are off-limits to them.

create or replace function public.owner_cancel_order(p_order_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  if not public.is_owner() then
    raise exception 'إلغاء الأوردر من صلاحية المدير فقط' using errcode = '42501';
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

revoke all on function public.owner_cancel_order(uuid, text) from public;
grant execute on function public.owner_cancel_order(uuid, text) to authenticated;


-- ========== supabase/migrations/0031_wider_order_numbers.sql ==========

-- 0031_wider_order_numbers.sql
--
-- "increase zeros in ORD bcs the mass is maybe high... tell me what will
-- happen when reach 9999" —
--
-- What actually happens at 9999 with the old 4-digit lpad: nothing breaks.
-- lpad() only *pads up to* a width, it never truncates — order #10000
-- would simply become "ORD-10000" (5 digits) on its own, #100000 becomes
-- "ORD-100000", and so on forever, with no collision risk either way
-- (uniqueness comes from the sequence, not the digit count). The only real
-- downside is cosmetic: sorting order_number as *text* breaks exactly at
-- that width boundary ("ORD-10000" sorts before "ORD-9999", since '1' <
-- '9') — orders are actually listed by created_at everywhere in this app,
-- never by order_number text, so this was never going to bite functionally
-- either. Still, widening now — while the numbers are still small — means
-- the vast majority of this business's order history stays visually
-- consistent at one width, rather than only the last handful of orders
-- before some future 99999-order milestone looking different from
-- everything before them.
--
-- This only changes new orders going forward — every existing order
-- number is already stored as plain text on its row and is never
-- recomputed, so nothing already printed on a receipt or read out to a
-- customer changes.

create or replace function public.set_order_number()
returns trigger
language plpgsql
as $$
begin
  if new.order_number is null or new.order_number = '' then
    new.order_number := 'ORD-' || lpad(nextval('public.order_number_seq')::text, 5, '0');
  end if;
  return new;
end;
$$;
