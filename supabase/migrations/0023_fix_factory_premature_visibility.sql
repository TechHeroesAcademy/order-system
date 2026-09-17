-- 0023_fix_factory_premature_visibility.sql
--
-- Follow-up to 0022, found while investigating a report of an error when
-- opening an order from the factory side. Direct reproduction against a
-- local Postgres copy of the schema (create an order with both driver and
-- factory assigned at creation — mandatory since Round 4 — leave it at its
-- freshly-created 'assigned' status, then query as that factory) showed the
-- order visible in factory_orders_view even though the driver hasn't even
-- collected it from the customer yet, let alone brought it to the factory.
--
-- Root cause: 0022's "give a factory permanent access to any order it was
-- ever assigned to" used `assigned_factory_id = auth.uid()` with no status
-- qualifier at all, intending to cover collected/at_factory/ready (as
-- before) plus everything past it (with_driver/delivered/refused/
-- cancelled, the actual point of that migration). It didn't account for the
-- two statuses that come *before* collected — 'new' and 'assigned' — during
-- which the order hasn't reached anyone's hands yet. A factory account was
-- never supposed to see an order that far ahead of its own involvement (the
-- original 0014/0015 design deliberately withheld it until 'collected'),
-- and now, since factory assignment is mandatory at order creation, this
-- wasn't a narrow edge case — every single new order was affected from the
-- moment it's created.
--
-- Fix: the permanent-access branch now explicitly excludes 'new' and
-- 'assigned' (the only two statuses that make no sense for a factory to
-- see at all — nothing has happened yet that involves them). Every other
-- status keeps 0022's behavior unchanged: collected/at_factory/ready
-- through the existing active-status handling, and with_driver/delivered/
-- refused/cancelled permanently, for the same order, once the factory has
-- actually been involved.

-- ---------- orders ----------

drop policy if exists orders_select_factory on public.orders;
create policy orders_select_factory on public.orders
  for select using (
    public.current_user_role() = 'factory'
    and (
      (assigned_factory_id = auth.uid() and status not in ('new', 'assigned'))
      or (assigned_factory_id is null and status in ('collected', 'at_factory', 'ready'))
    )
  );

-- ---------- order_history ----------

drop policy if exists order_history_select_factory on public.order_history;
create policy order_history_select_factory on public.order_history
  for select using (
    public.current_user_role() = 'factory'
    and exists (
      select 1 from public.orders o
      where o.id = order_history.order_id
        and (
          (o.assigned_factory_id = auth.uid() and o.status not in ('new', 'assigned'))
          or (o.assigned_factory_id is null and o.status in ('collected', 'at_factory', 'ready'))
        )
    )
  );

-- ---------- factory_orders_view ----------
--
-- Same predicate change, no column changes this time — CREATE OR REPLACE
-- is fine here since the SELECT list is identical to 0022's.

create or replace view public.factory_orders_view
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
  o.assigned_factory_id,
  f.full_name as assigned_factory_name,
  f.address as assigned_factory_address,
  o.collected_at,
  o.handed_to_factory_at,
  o.factory_received_at,
  o.factory_ready_at,
  o.driver_pickup_at,
  o.delivered_at,
  o.created_at
from public.orders o
left join public.profiles p on p.id = o.assigned_driver_id
left join public.profiles f on f.id = o.assigned_factory_id
where
  public.current_user_role() in ('owner', 'moderator')
  or (
    public.current_user_role() = 'factory'
    and (
      (o.assigned_factory_id = auth.uid() and o.status not in ('new', 'assigned'))
      or (o.assigned_factory_id is null and o.status in ('collected', 'at_factory', 'ready'))
    )
  );

grant select on public.factory_orders_view to authenticated;
