-- 0010_reporting_and_views.sql
-- Factory-safe view (no customer PII) + Owner reporting/analytics RPCs.

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
  o.collected_at,
  o.factory_received_at,
  o.factory_ready_at,
  o.created_at
from public.orders o
left join public.profiles p on p.id = o.assigned_driver_id
where o.status in ('collected', 'at_factory', 'ready')
  and public.current_user_role() in ('factory', 'owner', 'moderator');

-- (grant select on this view to authenticated is in 0011_table_grants.sql)

-- Owner dashboard summary cards.
create or replace function public.dashboard_stats()
returns table (
  total_orders bigint,
  new_orders bigint,
  assigned_orders bigint,
  collected_orders bigint,
  at_factory_orders bigint,
  ready_orders bigint,
  with_driver_orders bigint,
  delivered_orders bigint,
  refused_orders bigint,
  cancelled_orders bigint,
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
      count(*),
      count(*) filter (where status = 'new'),
      count(*) filter (where status = 'assigned'),
      count(*) filter (where status = 'collected'),
      count(*) filter (where status = 'at_factory'),
      count(*) filter (where status = 'ready'),
      count(*) filter (where status = 'with_driver'),
      count(*) filter (where status = 'delivered'),
      count(*) filter (where status = 'refused'),
      count(*) filter (where status = 'cancelled'),
      count(*) filter (where public.is_order_delayed(orders.*))
    from public.orders;
end;
$$;

-- Daily report for a given day (defaults to today).
create or replace function public.daily_report(p_day date default current_date)
returns table (
  new_orders bigint,
  collected_orders bigint,
  entered_factory bigint,
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
      count(*) filter (where delivered_at::date = p_day),
      count(*) filter (where public.is_order_delayed(orders.*))
    from public.orders;
end;
$$;

-- Monthly report for the month containing p_month (defaults to current month).
create or replace function public.monthly_report(p_month date default current_date)
returns table (
  total_orders bigint,
  total_pieces bigint,
  completed_orders bigint,
  delayed_orders bigint,
  avg_completion_hours numeric,
  on_time_rate numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_end date := (date_trunc('month', p_month) + interval '1 month')::date;
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    select
      count(*),
      coalesce(sum(pieces_count), 0),
      count(*) filter (where status = 'delivered'),
      count(*) filter (where public.is_order_delayed(orders.*)),
      round(avg(extract(epoch from (delivered_at - created_at)) / 3600.0) filter (where status = 'delivered'), 1),
      round(
        100.0 * count(*) filter (where status = 'delivered' and delivered_at <= created_at + (public.order_sla_hours() || ' hours')::interval)
        / nullif(count(*) filter (where status = 'delivered'), 0),
        1
      )
    from public.orders
    where created_at >= v_start and created_at < v_end;
end;
$$;

-- Per-driver performance.
create or replace function public.driver_performance_report()
returns table (
  driver_id uuid,
  full_name text,
  total_orders bigint,
  completed_orders bigint,
  delayed_orders bigint,
  active_orders bigint,
  avg_completion_hours numeric,
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
      count(o.id) filter (where o.status = 'refused')
    from public.profiles p
    left join public.orders o on o.assigned_driver_id = p.id
    where p.role = 'driver'
    group by p.id, p.full_name
    order by p.full_name;
end;
$$;

-- Currently delayed orders, with enough context for the Owner to act.
create or replace function public.delayed_orders_report()
returns table (
  id uuid,
  order_number text,
  customer_name text,
  region_name text,
  driver_name text,
  status order_status,
  created_at timestamptz,
  hours_open numeric
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    select
      o.id, o.order_number, o.customer_name, r.name, p.full_name, o.status, o.created_at,
      round(extract(epoch from (now() - o.created_at)) / 3600.0, 1)
    from public.orders o
    left join public.regions r on r.id = o.region_id
    left join public.profiles p on p.id = o.assigned_driver_id
    where public.is_order_delayed(o.*)
    order by o.created_at asc;
end;
$$;

-- Most-requested regions.
create or replace function public.top_regions_report()
returns table (region_name text, order_count bigint)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    select coalesce(r.name, 'غير محدد'), count(*)
    from public.orders o
    left join public.regions r on r.id = o.region_id
    group by r.name
    order by count(*) desc;
end;
$$;

revoke all on function public.dashboard_stats() from public;
revoke all on function public.daily_report(date) from public;
revoke all on function public.monthly_report(date) from public;
revoke all on function public.driver_performance_report() from public;
revoke all on function public.delayed_orders_report() from public;
revoke all on function public.top_regions_report() from public;

grant execute on function public.dashboard_stats() to authenticated;
grant execute on function public.daily_report(date) to authenticated;
grant execute on function public.monthly_report(date) to authenticated;
grant execute on function public.driver_performance_report() to authenticated;
grant execute on function public.delayed_orders_report() to authenticated;
grant execute on function public.top_regions_report() to authenticated;
