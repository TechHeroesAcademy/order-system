create index if not exists orders_open_created_at_idx
  on public.orders (created_at)
  where status not in ('delivered', 'cancelled', 'refused');

create index if not exists orders_driver_created_at_idx
  on public.orders (assigned_driver_id, created_at desc);

create index if not exists orders_status_created_at_idx
  on public.orders (status, created_at desc);

drop index if exists public.orders_driver_idx;
drop index if exists public.orders_status_idx;

create or replace function public.monthly_report(p_month date default current_date)
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
  v_sla interval := (public.order_sla_hours() || ' hours')::interval;
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    with agg as (
      select
        count(*) filter (where o.created_at >= v_start) as cur_total,
        coalesce(sum(o.pieces_count) filter (where o.created_at >= v_start), 0) as cur_pieces,
        count(*) filter (where o.created_at >= v_start and o.status = 'delivered') as cur_delivered,
        count(*) filter (
          where o.created_at >= v_start and public.is_order_delayed(o.*)
        ) as cur_delayed,
        round(
          avg(extract(epoch from (o.delivered_at - o.created_at)) / 3600.0)
            filter (where o.created_at >= v_start and o.status = 'delivered'),
          1
        ) as cur_avg_hours,
        count(*) filter (
          where o.created_at >= v_start
            and o.status = 'delivered'
            and o.delivered_at <= o.created_at + v_sla
        ) as cur_on_time,
        count(*) filter (where o.created_at < v_start) as prev_total,
        count(*) filter (where o.created_at < v_start and o.status = 'delivered') as prev_delivered
      from public.orders o
      where o.created_at >= v_prev_start
        and o.created_at < v_end
    )
    select
      agg.cur_total,
      agg.cur_pieces,
      agg.cur_delivered,
      agg.cur_delayed,
      agg.cur_avg_hours,
      round(100.0 * agg.cur_on_time / nullif(agg.cur_delivered, 0), 1),
      agg.prev_total,
      agg.prev_delivered,
      case
        when agg.prev_total = 0 then null
        else round(100.0 * (agg.cur_total - agg.prev_total) / agg.prev_total, 1)
      end
    from agg;
end;
$$;

revoke all on function public.monthly_report(date) from public;
grant execute on function public.monthly_report(date) to authenticated;
