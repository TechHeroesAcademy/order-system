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
    or public.current_user_role() = 'factory'
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
    or public.current_user_role() = 'factory'
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

  insert into public.order_messages (order_id, channel, sender_id, sender_role, body, driver_id)
  values (p_order_id, v_channel, auth.uid(), v_role, v_body, v_order.assigned_driver_id)
  returning * into v_row;

  if v_role = 'driver' then
    perform public.notify_role('owner', p_order_id, 'chat_message',
      'رسالة جديدة من المندوب على الأوردر ' || v_order.order_number, v_body);
  elsif v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'chat_message',
      'رسالة جديدة على الأوردر ' || v_order.order_number, v_body);
  end if;

  return v_row;
end;
$$;

drop policy if exists order_messages_select on public.order_messages;
create policy order_messages_select on public.order_messages
  for select using (
    public.is_owner()
    or public.can_read_order_channel(order_messages.order_id, order_messages.channel, auth.uid(), order_messages.driver_id)
  );
