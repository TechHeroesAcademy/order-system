-- 0017_track_order_setof_and_manager_label.sql
--
-- "order tracking is very bad" — track_order() already required both the
-- order number AND the phone to match (verified again below), and the
-- frontend already has a distinct "لا يوجد أوردر بهذه البيانات" state for
-- no-match. But track_order returns a single composite row (not SETOF),
-- and a composite-returning function that returns SQL NULL is a known thin
-- spot for PostgREST/supabase-js: depending on version it can come back as
-- a genuine JSON `null` (handled fine) or as an object with every field
-- null (NOT handled — the frontend would treat that as "order found" and
-- render a blank/broken result instead of the no-match message). Local SQL
-- testing against Postgres directly — how this was verified before — can't
-- catch that, because it never goes through PostgREST's serialization at
-- all. Switching to `setof` is the standard, unambiguous fix for "zero or
-- one row" RPCs under PostgREST: no match is always a plain empty array,
-- a match is always a one-element array, never a shape that could be
-- mistaken for a found order. src/lib/actions/orders.ts's trackOrderAction
-- is updated to match (data[0] ?? null instead of data ?? null).

drop function if exists public.track_order(text, text);

create or replace function public.track_order(p_order_number text, p_phone text)
returns setof public.tracked_order
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_result public.tracked_order;
  v_digits_input text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  -- Both the order number AND the phone's last 8 digits must match the same
  -- row — this was already an AND, not an OR; unchanged here.
  select * into v_order
  from public.orders o
  where upper(o.order_number) = upper(trim(coalesce(p_order_number, '')))
    and right(regexp_replace(o.customer_phone, '\D', '', 'g'), 8) = right(v_digits_input, 8)
  limit 1;

  if v_order is null then
    return; -- zero rows — an unambiguous "not found" over the wire
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
  return next v_result;
end;
$$;

revoke all on function public.track_order from public;
grant execute on function public.track_order to anon, authenticated;
