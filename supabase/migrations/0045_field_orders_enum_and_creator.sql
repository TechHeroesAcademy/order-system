-- 0045_field_orders_enum_and_creator.sql
--
-- Two additive changes, split into their own migration for one specific
-- reason: a new enum value cannot be USED in the same transaction that adds
-- it. Postgres accepts the ALTER, but any statement in that transaction
-- referencing the new label fails. Keeping the ALTER here and the RPC that
-- uses it in 0046 means each file commits cleanly on its own, whichever way
-- the SQL editor wraps it.
--
-- RUN THIS BEFORE 0046.

-- ── a third way an order can arrive ─────────────────────────────────────
--
-- A driver out delivering negotiates a new job on the doorstep. Until now
-- every order came from the website or from Messenger via a staff member;
-- this is a third channel with genuinely different economics, and it needs
-- to be countable on its own. Without a distinct source these orders are
-- indistinguishable from approved ones in every report — which would hide
-- both the upside (how much business drivers bring in) and the downside (a
-- driver creating orders that never get delivered).
alter type public.order_source add value if not exists 'driver_field';

-- ── who created this order ──────────────────────────────────────────────
--
-- orders.created_by has existed since 0004 and points at profiles, but
-- nothing in the app ever showed it. With drivers about to create orders
-- themselves, "who opened this" stops being trivia and becomes the first
-- question a manager asks about an unfamiliar order.
--
-- Snapshot columns rather than a live join, for exactly the reason 0032
-- introduced assigned_driver_name: a join loses the name the moment that
-- account is deleted, and the orders that most need explaining are often
-- the ones whose creator has since left.
alter table public.orders add column if not exists created_by_name text;
alter table public.orders add column if not exists created_by_role public.user_role;

-- Backfill what can still be resolved. Orders whose creator is already gone
-- keep a null name, which is honest — the information was never recorded at
-- the time and inventing one would be worse than showing nothing.
update public.orders o
   set created_by_name = p.full_name,
       created_by_role = p.role
  from public.profiles p
 where p.id = o.created_by
   and o.created_by_name is null;

-- ── stamp it at insert ──────────────────────────────────────────────────
--
-- Its own trigger rather than an addition to stamp_order_assignee_names:
-- that one fires on insert AND update because a driver or factory can
-- change over an order's life. A creator cannot. Folding this in would mean
-- re-resolving the creator on every status change for a value that can
-- never differ, and would make it possible for a later edit to rewrite
-- history. before insert only, so the creator is fixed at birth.
create or replace function public.stamp_order_creator_name()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.created_by is not null then
    select full_name, role into new.created_by_name, new.created_by_role
      from public.profiles where id = new.created_by;
  end if;
  return new;
end;
$$;

drop trigger if exists stamp_order_creator on public.orders;
create trigger stamp_order_creator
  before insert on public.orders
  for each row execute function public.stamp_order_creator_name();

revoke all on function public.stamp_order_creator_name() from public;
