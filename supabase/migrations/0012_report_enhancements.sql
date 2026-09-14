-- 0012_report_enhancements.sql
-- Fills two gaps found against the original spec's reporting section:
-- 1. daily_report() was missing "currently in factory", "ready now", and
--    "exited factory today" counts (spec section 17).
-- 2. monthly_report() was missing a month-over-month comparison against the
--    previous month (spec section 18).
-- Postgres won't let CREATE OR REPLACE change a function's return type, so
-- both are dropped and recreated, then re-granted (grants on a dropped
-- function are lost with it).

drop function if exists public.daily_report(date);

create function public.daily_report(p_day date default current_date)
returns table (
  new_orders bigint,
  collected_orders bigint,
  entered_factory bigint,
  in_factory_now bigint,
  ready_now bigint,
  exited_factory bigint,
  delivered_orders bigint,
  delayed_orders bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    select
      count(*) filter (where created_at::date = p_day),
      count(*) filter (where collected_at::date = p_day),
      count(*) filter (where factory_received_at::date = p_day),
      count(*) filter (where status = 'at_factory'),
      count(*) filter (where status = 'ready'),
      count(*) filter (where driver_pickup_at::date = p_day),
      count(*) filter (where delivered_at::date = p_day),
      count(*) filter (where public.is_order_delayed(orders.*))
    from public.orders;
end;
$$;

drop function if exists public.monthly_report(date);

create function public.monthly_report(p_month date default current_date)
returns table (
  total_orders bigint,
  total_pieces bigint,
  completed_orders bigint,
  delayed_orders bigint,
  avg_completion_hours numeric,
  on_time_rate numeric,
  prev_total_orders bigint,
  prev_completed_orders bigint,
  orders_change_percent numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_end date := (date_trunc('month', p_month) + interval '1 month')::date;
  v_prev_start date := (date_trunc('month', p_month) - interval '1 month')::date;
  v_prev_end date := v_start;
  v_total bigint;
  v_prev_total bigint;
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  select count(*) into v_total from public.orders where created_at >= v_start and created_at < v_end;
  select count(*) into v_prev_total from public.orders where created_at >= v_prev_start and created_at < v_prev_end;

  return query
    select
      v_total,
      coalesce((select sum(pieces_count) from public.orders where created_at >= v_start and created_at < v_end), 0),
      (select count(*) from public.orders where created_at >= v_start and created_at < v_end and status = 'delivered'),
      (select count(*) from public.orders where created_at >= v_start and created_at < v_end and public.is_order_delayed(orders.*)),
      (select round(avg(extract(epoch from (delivered_at - created_at)) / 3600.0), 1)
         from public.orders
         where created_at >= v_start and created_at < v_end and status = 'delivered'),
      (select round(
          100.0 * count(*) filter (where delivered_at <= created_at + (public.order_sla_hours() || ' hours')::interval)
          / nullif(count(*), 0),
          1
        )
        from public.orders
        where created_at >= v_start and created_at < v_end and status = 'delivered'),
      v_prev_total,
      (select count(*) from public.orders where created_at >= v_prev_start and created_at < v_prev_end and status = 'delivered'),
      case when v_prev_total = 0 then null else round(100.0 * (v_total - v_prev_total) / v_prev_total, 1) end;
end;
$$;

grant execute on function public.daily_report(date) to authenticated;
grant execute on function public.monthly_report(date) to authenticated;
