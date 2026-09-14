-- 0009_workflow_rpcs.sql
-- Every legal state transition in the order lifecycle, each as its own RPC:
--   new -> (distribution set, pending approval) -> assigned -> collected
--        -> at_factory -> ready -> with_driver -> delivered
-- with 'refused' and 'cancelled' as side-exits. Each function checks the caller's
-- role and the order's current status server-side, so the workflow cannot be
-- skipped or reordered from the client no matter what the UI sends.

-- ---------- distribution ----------

create or replace function public.suggest_drivers(p_order_id uuid)
returns table (
  driver_id uuid,
  full_name text,
  covers_region boolean,
  active_orders_count bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_region_id uuid;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select region_id into v_region_id from public.orders where id = p_order_id;

  return query
    select
      p.id,
      p.full_name,
      exists (
        select 1 from public.driver_regions dr
        where dr.driver_id = p.id and dr.region_id = v_region_id
      ) as covers_region,
      (
        select count(*) from public.orders o
        where o.assigned_driver_id = p.id
          and o.status not in ('delivered', 'cancelled', 'refused')
      ) as active_orders_count
    from public.profiles p
    where p.role = 'driver' and p.is_active
    order by covers_region desc, active_orders_count asc, p.full_name asc;
end;
$$;

create or replace function public.set_order_distribution(p_order_id uuid, p_driver_id uuid, p_is_suggestion boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status order_status;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
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
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select status into v_status from public.orders where id = p_order_id for update;
  if v_status <> 'new' then
    raise exception 'لا يمكن إلغاء توزيع أوردر تم اعتماده بالفعل';
  end if;

  update public.orders set assigned_driver_id = null where id = p_order_id;
  perform public.log_order_event(p_order_id, 'distribution_cleared', v_status, v_status, 'تم إلغاء التوزيع المقترح');
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
end;
$$;

-- ---------- driver actions ----------

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

  perform public.log_order_event(p_order_id, 'handed_to_factory', 'collected', 'collected', 'المندوب توجه بالأوردر إلى المصنع');
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
end;
$$;

create or replace function public.driver_deliver_to_customer(p_order_id uuid, p_code text)
returns boolean
language plpgsql
security definer
set search_path = public
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
  perform public.notify_role('owner', p_order_id, 'order_refused', 'رفض استلام أوردر ' || v_order.order_number, p_reason);
end;
$$;

-- ---------- factory actions ----------

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
end;
$$;

-- ---------- owner: cancel ----------

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
end;
$$;

-- ---------- public customer tracking ----------

drop type if exists public.tracked_order cascade;

create type public.tracked_order as (
  order_number text,
  status order_status,
  pieces_count integer,
  created_at timestamptz,
  collected_at timestamptz,
  factory_received_at timestamptz,
  factory_ready_at timestamptz,
  driver_pickup_at timestamptz,
  delivered_at timestamptz,
  refused_at timestamptz,
  is_delayed boolean
);

create or replace function public.track_order(p_order_number text, p_phone text)
returns public.tracked_order
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_result public.tracked_order;
  v_digits_input text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  select * into v_order
  from public.orders o
  where upper(o.order_number) = upper(trim(coalesce(p_order_number, '')))
    and right(regexp_replace(o.customer_phone, '\D', '', 'g'), 8) = right(v_digits_input, 8)
  limit 1;

  if v_order is null then
    return null;
  end if;

  v_result.order_number := v_order.order_number;
  v_result.status := v_order.status;
  v_result.pieces_count := v_order.pieces_count;
  v_result.created_at := v_order.created_at;
  v_result.collected_at := v_order.collected_at;
  v_result.factory_received_at := v_order.factory_received_at;
  v_result.factory_ready_at := v_order.factory_ready_at;
  v_result.driver_pickup_at := v_order.driver_pickup_at;
  v_result.delivered_at := v_order.delivered_at;
  v_result.refused_at := v_order.refused_at;
  v_result.is_delayed := public.is_order_delayed(v_order);
  return v_result;
end;
$$;

revoke all on function public.track_order from public;
grant execute on function public.track_order to anon, authenticated;

-- ---------- lock down the rest to authenticated users only ----------
-- (Postgres grants EXECUTE to PUBLIC by default; every workflow RPC below does its
-- own role/ownership check internally, but we still remove anon access entirely
-- as defense in depth — an anonymous caller should never reach these at all.)
revoke all on function public.suggest_drivers(uuid) from public;
revoke all on function public.set_order_distribution(uuid, uuid, boolean) from public;
revoke all on function public.clear_order_distribution(uuid) from public;
revoke all on function public.approve_distribution(uuid) from public;
revoke all on function public.driver_mark_collected(uuid) from public;
revoke all on function public.driver_hand_to_factory(uuid) from public;
revoke all on function public.driver_confirm_factory_pickup(uuid) from public;
revoke all on function public.driver_deliver_to_customer(uuid, text) from public;
revoke all on function public.driver_log_refusal(uuid, text) from public;
revoke all on function public.factory_confirm_receipt(uuid) from public;
revoke all on function public.factory_mark_ready(uuid) from public;
revoke all on function public.owner_cancel_order(uuid, text) from public;

grant execute on function public.suggest_drivers(uuid) to authenticated;
grant execute on function public.set_order_distribution(uuid, uuid, boolean) to authenticated;
grant execute on function public.clear_order_distribution(uuid) to authenticated;
grant execute on function public.approve_distribution(uuid) to authenticated;
grant execute on function public.driver_mark_collected(uuid) to authenticated;
grant execute on function public.driver_hand_to_factory(uuid) to authenticated;
grant execute on function public.driver_confirm_factory_pickup(uuid) to authenticated;
grant execute on function public.driver_deliver_to_customer(uuid, text) to authenticated;
grant execute on function public.driver_log_refusal(uuid, text) to authenticated;
grant execute on function public.factory_confirm_receipt(uuid) to authenticated;
grant execute on function public.factory_mark_ready(uuid) to authenticated;
grant execute on function public.owner_cancel_order(uuid, text) to authenticated;
