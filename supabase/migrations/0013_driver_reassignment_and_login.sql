-- 0013_driver_reassignment_and_login.sql
-- Three things:
--   1) Let Owner/Moderator change an order's driver at any point in its
--      lifecycle (not just before distribution is approved) — the spec
--      explicitly asks for "نقل أوردر من مندوب إلى آخر" and the Owner asked
--      for it again directly ("add driver or change it whenever I want").
--   2) profiles.password_set + a unique index on phone, backing a phone
--      number + password login flow (staff sign in with their phone number,
--      creating a password themselves on first login instead of an Owner
--      sharing one or relying on email delivery).
--   3) driver_performance_report gains a per-driver on-time delivery rate —
--      the one field from spec section 21 ("تقارير أداء المندوبين") that was
--      still missing.

-- ---------- 1) reassign driver at any (non-terminal) status ----------

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

  update public.orders set assigned_driver_id = p_new_driver_id where id = p_order_id;

  perform public.log_order_event(p_order_id, 'driver_reassigned', v_order.status, v_order.status,
    case when v_old_driver_name is not null
      then 'تم تغيير المندوب من ' || v_old_driver_name || ' إلى ' || v_new_driver.full_name
      else 'تم تعيين مندوب: ' || v_new_driver.full_name
    end);

  if v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'reassigned_away',
      'تم نقل الأوردر ' || v_order.order_number || ' إلى مندوب آخر', null);
  end if;

  -- Only notify the new driver immediately if they can already see the order
  -- (i.e. distribution is past the pending-approval stage); before approval
  -- this mirrors set_order_distribution, which doesn't notify either.
  if v_order.status <> 'new' then
    perform public.notify_user(p_new_driver_id, p_order_id, 'order_assigned',
      'تم إسناد أوردر إليك ' || v_order.order_number, 'العميل: ' || v_order.customer_name);
  end if;
end;
$$;

revoke all on function public.reassign_order_driver from public;
grant execute on function public.reassign_order_driver to authenticated;

-- ---------- 2) phone-number login support ----------

alter table public.profiles add column if not exists password_set boolean not null default true;

comment on column public.profiles.password_set is
  'false right after an Owner/Moderator creates the account (or resets its password) — the worker must set their own password on next login before signing in.';

create unique index if not exists profiles_phone_unique_idx on public.profiles (phone) where phone is not null;

-- ---------- 3) driver_performance_report: add on-time delivery rate ----------

drop function if exists public.driver_performance_report();

create function public.driver_performance_report()
returns table (
  driver_id uuid,
  full_name text,
  total_orders bigint,
  completed_orders bigint,
  delayed_orders bigint,
  active_orders bigint,
  avg_completion_hours numeric,
  on_time_rate numeric,
  refusal_count bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    select
      p.id,
      p.full_name,
      count(o.id),
      count(o.id) filter (where o.status = 'delivered'),
      count(o.id) filter (where public.is_order_delayed(o.*)),
      count(o.id) filter (where o.status not in ('delivered', 'cancelled', 'refused')),
      round(avg(extract(epoch from (o.delivered_at - o.created_at)) / 3600.0) filter (where o.status = 'delivered'), 1),
      round(
        100.0 * count(o.id) filter (where o.status = 'delivered' and o.delivered_at <= o.created_at + (public.order_sla_hours() || ' hours')::interval)
        / nullif(count(o.id) filter (where o.status = 'delivered'), 0),
        1
      ),
      count(o.id) filter (where o.status = 'refused')
    from public.profiles p
    left join public.orders o on o.assigned_driver_id = p.id
    where p.role = 'driver'
    group by p.id, p.full_name
    order by p.full_name;
end;
$$;

revoke all on function public.driver_performance_report() from public;
grant execute on function public.driver_performance_report() to authenticated;
