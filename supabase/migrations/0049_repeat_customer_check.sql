create index if not exists orders_customer_phone_last8_idx
  on public.orders (right(regexp_replace(customer_phone, '\D', '', 'g'), 8));

drop index if exists public.orders_customer_phone_idx;

create or replace function public.customer_order_history(p_phone text)
returns table (
  previous_orders bigint,
  open_orders bigint,
  delivered_orders bigint,
  cancelled_orders bigint,
  refused_orders bigint,
  last_order_number text,
  last_order_at timestamptz,
  last_order_status public.order_status,
  names_seen text[]
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role public.user_role;
  v_active boolean;
  v_key text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 8);
begin
  select role, is_active into v_role, v_active
    from public.profiles where id = auth.uid();

  if v_role is null or not v_active then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if v_role not in ('owner', 'moderator', 'driver') then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  if length(v_key) < 8 then
    return query select 0::bigint, 0::bigint, 0::bigint, 0::bigint, 0::bigint,
                        null::text, null::timestamptz, null::public.order_status, null::text[];
    return;
  end if;

  return query
    with matched as (
      select o.id, o.order_number, o.created_at, o.status, o.customer_name
        from public.orders o
       where right(regexp_replace(o.customer_phone, '\D', '', 'g'), 8) = v_key
    ),
    latest as (
      select m.order_number, m.created_at, m.status
        from matched m
       order by m.created_at desc
       limit 1
    )
    select
      (select count(*) from matched),
      (select count(*) from matched m where m.status not in ('delivered', 'refused', 'cancelled')),
      (select count(*) from matched m where m.status = 'delivered'),
      (select count(*) from matched m where m.status = 'cancelled'),
      (select count(*) from matched m where m.status = 'refused'),
      (select l.order_number from latest l),
      (select l.created_at from latest l),
      (select l.status from latest l),
      (select array_agg(n.customer_name order by n.last_at desc)
         from (select m.customer_name, max(m.created_at) as last_at
                 from matched m
                where m.customer_name is not null and trim(m.customer_name) <> ''
                group by m.customer_name
                order by max(m.created_at) desc
                limit 5) n);
end;
$$;

revoke all on function public.customer_order_history(text) from public;
grant execute on function public.customer_order_history(text) to authenticated;

comment on function public.customer_order_history(text) is
  'Aggregate order history for a customer phone number, across every creator. Staff/driver only; shown as a confirmation before a new order is created.';
