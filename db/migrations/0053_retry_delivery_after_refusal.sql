begin;

alter table public.orders
  add column if not exists refusal_count integer not null default 0;

comment on column public.orders.refusal_count is
  'How many times the customer has refused this order. status and refused_at '
  'describe the CURRENT state and are cleared when delivery is retried, so '
  'without this the fact that a refusal happened would vanish from the row '
  'the moment someone reopened it.';

create or replace function public.driver_retry_delivery(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_role public.user_role;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then
    raise exception 'الأوردر غير موجود';
  end if;

  v_role := public.current_user_role();

  if not (
    coalesce(public.is_owner_or_moderator(), false)
    or (coalesce(v_role = 'driver', false) and v_order.assigned_driver_id = auth.uid())
  ) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  if v_order.status <> 'refused' then
    raise exception 'الأوردر ليس بحالة رفض استلام';
  end if;

  if v_order.assigned_driver_id is null then
    raise exception 'لا يوجد مندوب معيّن لهذا الأوردر';
  end if;

  update public.orders
     set status = 'with_driver',
         refused_at = null,
         failed_code_attempts = 0,
         delivery_code_last_attempt_at = null
   where id = p_order_id;

  perform public.log_order_event(
    p_order_id, 'delivery_retry', 'refused', 'with_driver',
    coalesce(v_order.refusal_reason, '')
  );

  perform public.notify_staff(
    p_order_id,
    'delivery_retry',
    'إعادة محاولة تسليم أوردر ' || v_order.order_number,
    coalesce(v_order.refusal_reason, ''),
    auth.uid()
  );

  if v_order.assigned_driver_id <> auth.uid() then
    perform public.notify_user(
      v_order.assigned_driver_id,
      'delivery_retry',
      'إعادة محاولة تسليم أوردر ' || v_order.order_number,
      'الأوردر رجع لحالة التسليم، حاول مع العميل مرة أخرى',
      p_order_id
    );
  end if;
end;
$$;

comment on function public.driver_retry_delivery(uuid) is
  'Reopens a refused order so the same driver can attempt delivery again '
  'later. The delivery code is unchanged — it was never cleared — so the '
  'customer confirms with the same four digits. The failed-attempt counter '
  'is reset, because the previous attempts belong to the previous visit.';

revoke all on function public.driver_retry_delivery(uuid) from public;
grant execute on function public.driver_retry_delivery(uuid) to authenticated, app_user;

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
  if v_order.assigned_driver_id <> auth.uid() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if v_order.status <> 'with_driver' then
    raise exception 'الأوردر ليس بحالة تسمح بتسجيل رفض الاستلام';
  end if;

  update public.orders
     set status = 'refused',
         refused_at = now(),
         refusal_reason = trim(p_reason),
         refusal_count = coalesce(refusal_count, 0) + 1
   where id = p_order_id;

  perform public.log_order_event(p_order_id, 'refused', 'with_driver', 'refused', p_reason);
  perform public.notify_staff(
    p_order_id, 'order_refused',
    'رفض استلام أوردر ' || v_order.order_number, p_reason, auth.uid()
  );
end;
$$;

do $$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'driver_retry_delivery' and p.prosecdef
  ) then
    raise exception 'driver_retry_delivery missing or not SECURITY DEFINER';
  end if;

  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'orders' and column_name = 'refusal_count'
  ) then
    raise exception 'orders.refusal_count missing';
  end if;
end;
$$;

commit;
