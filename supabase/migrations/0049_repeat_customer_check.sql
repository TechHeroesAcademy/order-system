-- 0049_repeat_customer_check.sql
--
-- Before an order is created, whoever is creating it is told whether this
-- phone number has ordered before — and if so, that this is order number N
-- for that customer.
--
-- The count is deliberately across EVERY creator: the website, Messenger
-- orders taken by a manager or moderator, and field orders a driver opened
-- in the street. A repeat customer is a repeat customer regardless of who
-- happened to answer the phone, and a count scoped to the current user
-- would quietly report "first order" to a driver about a customer the
-- office has served five times.
--
-- Two separate things this makes visible, both invisible today:
--   * a returning customer, which is worth knowing while they are still on
--     the line (and is the number the person creating the order is asked to
--     confirm);
--   * the same customer already having an OPEN order — usually a second
--     entry of the same job by someone who did not know it was already in,
--     which until now only surfaced when two drivers turned up.

-- ── matching rule ───────────────────────────────────────────────────────
--
-- The last 8 digits of the digits-only number, which is exactly what
-- track_order() has matched on since migration 0009. Reused rather than
-- invented so that "this customer's orders" means the same thing here as
-- it does on the public tracking page — a second, stricter rule would
-- produce a count that disagrees with what the customer themselves can see.
--
-- It also absorbs the ways one Egyptian number gets written: 01012345678,
-- +201012345678, 0020 10 1234 5678 and 010-1234-5678 all reduce to the
-- same 8 digits, so a returning customer is still recognised when the
-- number was typed differently the first time.
--
-- Written out here rather than wrapped in a helper function on purpose: an
-- index expression that calls a user-defined function is silently
-- invalidated by a later CREATE OR REPLACE of that function, and this
-- expression has to stay in step with the index below to be used by it.

-- The existing orders_customer_phone_idx is a plain btree on the raw text,
-- which no query in this system can use: nothing looks a customer up by an
-- exact, character-for-character phone string (search goes through the
-- trigram index orders_search_idx; tracking and this new function both go
-- through the last-8-digits expression). It is replaced rather than added
-- to, so the number of indexes paid for on every insert does not grow —
-- and the lookups that do happen stop being sequential scans.
create index if not exists orders_customer_phone_last8_idx
  on public.orders (right(regexp_replace(customer_phone, '\D', '', 'g'), 8));

drop index if exists public.orders_customer_phone_idx;

-- ── the lookup ──────────────────────────────────────────────────────────
--
-- SECURITY DEFINER because it has to see every order on that number,
-- including ones RLS hides from the caller — a driver can normally only
-- read their own orders, so a plain select would make them see "first
-- order" for a customer the office has served. That is the entire point of
-- the function, so the aggregate is computed with RLS bypassed and what
-- comes back is kept to aggregates plus the one most recent order:
-- quantities, dates, a status and the names the number has been saved
-- under. No addresses, no notes, no codes, no other order's details.
--
-- Returns exactly one row, always — zero counts for a number that has
-- never ordered. `returns table` (a set) rather than a composite scalar for
-- the reason migration 0017 switched track_order over: a composite NULL
-- reaches supabase-js as an object of all-null fields, which client code
-- mistakes for a real answer, whereas a set is always a plain array.
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

  -- Staff and drivers only. Never granted to anon, and not readable by one:
  -- answering "how many orders does this number have" for any number handed
  -- in is a membership oracle over the customer list, so it stays behind a
  -- login. The public order form therefore does not get this check — the
  -- person filling that in is the customer, who knows their own history.
  if v_role is null or not v_active then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if v_role not in ('owner', 'moderator', 'driver') then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  -- Too short to identify anybody. Returning zeros rather than raising
  -- keeps the caller simple: the form looks this up while the number is
  -- still being typed, and a half-entered number is not an error.
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
      -- "Open" is every non-terminal status, matching TERMINAL_STATUSES in
      -- src/lib/domain/order-status.ts. This is the number that matters
      -- most: a customer with an order already in flight is the duplicate
      -- case, not just a returning one.
      (select count(*) from matched m where m.status not in ('delivered', 'refused', 'cancelled')),
      (select count(*) from matched m where m.status = 'delivered'),
      (select count(*) from matched m where m.status = 'cancelled'),
      (select count(*) from matched m where m.status = 'refused'),
      (select l.order_number from latest l),
      (select l.created_at from latest l),
      (select l.status from latest l),
      -- The names this number has been saved under, most recent first.
      -- Shown so a mistyped phone number is caught: if the number belongs
      -- to someone else entirely, the name coming back is the giveaway, and
      -- otherwise it confirms it really is the same customer. Capped at
      -- five because it is a reassurance line, not a report.
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
