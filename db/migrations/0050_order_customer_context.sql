create or replace function public.order_customer_context(p_order_id uuid)
returns table (
  customer_order_index bigint,
  total_orders bigint,
  other_open_orders bigint,
  previous_order_id uuid,
  previous_order_number text,
  previous_order_at timestamptz,
  previous_order_status public.order_status
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_key text;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if v_order is null then
    return;
  end if;

  v_key := right(regexp_replace(v_order.customer_phone, '\D', '', 'g'), 8);
  if length(v_key) < 8 then
    return;
  end if;

  return query
    with matched as (
      select o.id, o.order_number, o.created_at, o.status
        from public.orders o
       where right(regexp_replace(o.customer_phone, '\D', '', 'g'), 8) = v_key
    ),
    prev as (
      select m.id, m.order_number, m.created_at, m.status
        from matched m
       where (m.created_at, m.order_number) < (v_order.created_at, v_order.order_number)
       order by m.created_at desc, m.order_number desc
       limit 1
    )
    select
      (select count(*) from matched m
        where (m.created_at, m.order_number) <= (v_order.created_at, v_order.order_number)),
      (select count(*) from matched),
      (select count(*) from matched m
        where m.id <> v_order.id
          and m.status not in ('delivered', 'refused', 'cancelled')),
      (select p.id from prev p),
      (select p.order_number from prev p),
      (select p.created_at from prev p),
      (select p.status from prev p);
end;
$$;

revoke all on function public.order_customer_context(uuid) from public;
grant execute on function public.order_customer_context(uuid) to authenticated;

comment on function public.order_customer_context(uuid) is
  'This order''s position in its customer''s sequence, plus that customer''s other open orders. Owner/moderator only; shown on the order page.';
