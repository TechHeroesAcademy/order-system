-- 0050_order_customer_context.sql
--
-- The repeat-customer count, for an order that already exists.
--
-- Migration 0049 answers "has this number ordered before" while an order is
-- being created. This answers the different question a manager or moderator
-- asks when they open an order someone else created — above all a driver's
-- field order, which reaches a driver with nobody approving it, so looking
-- at it afterwards is the only control there is.
--
-- REQUIRES 0049 to have been applied (it relies on the last-8-digits index
-- that migration creates; it still works without it, just by scanning).
--
-- WHY THIS IS NOT customer_order_history() WITH THE ORDER'S PHONE
--
-- "Order number 3 for this customer" has to mean this order's own position
-- in that customer's sequence, counted at the time it was created. Feeding
-- the phone to 0049's function and adding one would instead answer "how
-- many has this customer had in total, plus one", so an order would be
-- labelled 3 today and 5 next month without anything about it changing —
-- and the oldest order in a customer's history would show the highest
-- number. The index below is counted against this order's own position, so
-- it is fixed the moment the order exists and never moves.
--
-- Ordered by (created_at, order_number) rather than created_at alone: two
-- orders for one customer created in the same instant would otherwise each
-- count the other, and both would claim the same position. The pair is
-- unique, because order_number is.

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
  -- Owner and moderator only, which is who the order pages are for. Drivers
  -- are told about a repeat customer at creation time instead (0049), on the
  -- form, where it can still change what they do.
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if v_order is null then
    return; -- zero rows; the page shows nothing rather than erroring
  end if;

  v_key := right(regexp_replace(v_order.customer_phone, '\D', '', 'g'), 8);
  if length(v_key) < 8 then
    return; -- a number too short to identify anybody
  end if;

  return query
    with matched as (
      select o.id, o.order_number, o.created_at, o.status
        from public.orders o
       where right(regexp_replace(o.customer_phone, '\D', '', 'g'), 8) = v_key
    ),
    -- The one immediately before this order, so the page can link straight
    -- to it. This is what someone checking "is this a duplicate?" opens
    -- next, and making them search for it by phone is the slow version of
    -- the same thing.
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
      -- Open orders OTHER than this one. Excluding it matters: an order
      -- being looked at is itself usually open, and counting it would make
      -- every single order look like it had a duplicate.
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
