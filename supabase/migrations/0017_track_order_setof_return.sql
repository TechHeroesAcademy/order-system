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
  select * into v_order
  from public.orders o
  where upper(o.order_number) = upper(trim(coalesce(p_order_number, '')))
    and right(regexp_replace(o.customer_phone, '\D', '', 'g'), 8) = right(v_digits_input, 8)
  limit 1;

  if v_order is null then
    return;
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
