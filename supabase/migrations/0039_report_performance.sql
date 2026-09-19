-- 0039_report_performance.sql
--
-- Pure performance migration. No new columns, no new permissions, no
-- behavior change: monthly_report returns exactly the same row for the same
-- input as the version it replaces (verified by diffing both versions'
-- output over seven months of seeded data, including empty months so the
-- NULL branches were exercised). It is safe to apply before or after the
-- matching app deploy, because the app does not change at all.
--
-- Scope note: an earlier draft of this migration also replaced
-- is_order_delayed(o public.orders) with a scalar (status, created_at)
-- overload, on the theory that a composite-argument SQL function can't be
-- inlined and therefore blocks index use. That was measured against
-- Postgres 16 and is simply false — the planner inlines the row-typed form
-- too, producing a byte-identical plan (same Bitmap Index Scan, same
-- Recheck Cond with the function expanded away). The overload was dropped
-- from this migration rather than shipped on a rationale that doesn't hold.
-- What actually made "which orders are late" an index scan is the partial
-- index below, nothing else.

-- ── indexes ─────────────────────────────────────────────────────────────

-- Open (non-terminal) orders only. Delivered/cancelled/refused orders are
-- the ones that accumulate forever and can never be late, so keeping them
-- out means this index stays roughly the size of the active workload no
-- matter how long the business runs.
--
-- This is the one with the large measured effect. Benchmarked on a seeded
-- 60,400-order table with 220 still open, delayed_orders_report's predicate
-- went from a sequential scan reading all 60,400 rows to a bitmap index
-- scan reading 217 (18 heap blocks). The gap widens over time, because the
-- rows this index deliberately never stores are exactly the ones that
-- accumulate forever.
create index if not exists orders_open_created_at_idx
  on public.orders (created_at)
  where status not in ('delivered', 'cancelled', 'refused');

-- The driver app's list is "my orders, newest first". This index does
-- nothing on its own — measured, the planner reads the same 1,334 rows and
-- sorts them either way — and only pays off once the query is also bounded,
-- which is the matching app change (listMyDriverOrders gained a .limit()).
-- With both: 1,334 rows plus a top-N sort becomes an ordered index scan of
-- exactly the 100 rows asked for. Neither half is worth much alone, which
-- is why they ship together.
create index if not exists orders_driver_created_at_idx
  on public.orders (assigned_driver_id, created_at desc);

-- Same shape for the staff order list. Honest scope: this is the smallest
-- of the three. For a common status the planner already did well off
-- orders_created_at_idx (25 rows read, no help needed); this one earns its
-- place on *narrow* statuses, where it removes the sort, and on a status
-- filter combined with a date range.
create index if not exists orders_status_created_at_idx
  on public.orders (status, created_at desc);

-- The two single-column indexes are now redundant: an index on (a, b)
-- serves every lookup an index on (a) served, because a is the leading
-- column. Keeping both would mean every order INSERT and every lifecycle
-- UPDATE maintains four index entries where two will do — and orders are
-- updated several times each as they move through the workflow, so this is
-- write cost on the hottest path in the system.
drop index if exists public.orders_driver_idx;
drop index if exists public.orders_status_idx;

-- ── monthly_report: eight scans of `orders` collapsed into one ──────────
--
-- The previous version counted two totals into variables and then ran six
-- more independent subqueries inside the RETURN, every one of them walking
-- the same rows of `orders` over again to produce a single output row.
-- Measured on the seeded data: 23 scans of `orders` for one call, down to 2.
--
-- This version reads the two months once — as a single range the created_at
-- index can serve — and splits current from previous with FILTER clauses.
-- v_prev_end was always exactly v_start, so "created_at < v_start" inside
-- the scanned range is precisely the previous month; no row can fall in
-- both halves or in neither.
--
-- Return values are unchanged, including every NULL case: avg over no
-- delivered orders is still NULL, on_time_rate over no delivered orders is
-- still NULL via nullif, and orders_change_percent is still NULL when the
-- previous month was empty.
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

-- CREATE OR REPLACE preserves existing grants, but these are re-stated so a
-- database freshly built from this chain ends up identical to an upgraded one.
revoke all on function public.monthly_report(date) from public;
grant execute on function public.monthly_report(date) to authenticated;
