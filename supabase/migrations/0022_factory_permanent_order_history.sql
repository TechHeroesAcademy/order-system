-- 0022_factory_permanent_order_history.sql
--
-- Reported as: "I need full history for the factory and when the factory
-- press on the order num to show the order details and chats it does not
-- work and gives an error."
--
-- Root cause, confirmed by direct reproduction against a local Postgres
-- copy of the schema (walked a real order through the full lifecycle to
-- 'delivered' as owner/driver/factory test accounts, then queried as the
-- factory account): orders_select_factory, order_history_select_factory,
-- and factory_orders_view (0014/0015) all scope factory access to the
-- three *active* statuses only ('collected', 'at_factory', 'ready'). The
-- moment an order the factory handled moves past 'ready' (driver picks it
-- back up, delivers it, or the customer refuses it), every one of those
-- three loses the row entirely — not just from the dashboard tabs (which
-- is intentional/by design there), but from the factory's own order-detail
-- page too. getFactoryOrderById() (src/lib/data/orders.ts) goes through
-- factory_orders_view, so a 0-row result there makes the page call
-- notFound() — and since this app has no custom not-found.tsx, that's
-- Next.js's bare unstyled default 404, which is exactly what "gives an
-- error" describes from the factory's side. There was and is no separate
-- bug in the chat itself: can_read_order_channel() (0019) was already
-- written to check assigned_factory_id directly against the raw orders
-- row, bypassing RLS, specifically so factory chat access never expires —
-- confirmed this still works correctly even on a delivered order. The
-- *page* just never got that far, because the order lookup above it 404'd
-- first.
--
-- Fix: give a factory permanent access to any order it was ever actually
-- assigned to (assigned_factory_id = them), at any status — the exact same
-- design orders_select_driver already uses for drivers (see the comment on
-- can_read_order_channel in 0019: "orders_select_driver has no status
-- restriction (a driver keeps seeing their own past orders forever)").
-- Access to an *unassigned* order stays exactly as before: visible only
-- while it's still active, since once it closes there's no specific
-- factory it belongs to. This also directly delivers "full history for the
-- factory" — every order this fixes visibility for is now also queryable
-- as history (see listFactoryOrderHistory in src/lib/data/orders.ts and
-- the new "السجل" tab on /factory).

-- ---------- orders ----------

drop policy if exists orders_select_factory on public.orders;
create policy orders_select_factory on public.orders
  for select using (
    public.current_user_role() = 'factory'
    and (
      assigned_factory_id = auth.uid()
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
          o.assigned_factory_id = auth.uid()
          or (o.assigned_factory_id is null and o.status in ('collected', 'at_factory', 'ready'))
        )
    )
  );

-- ---------- factory_orders_view ----------
--
-- Same WHERE-clause change as the two policies above (this view does its
-- own authorization — security_invoker = false — rather than relying on
-- the orders RLS, see the comment in 0014), plus driver_pickup_at and
-- delivered_at added to the selected columns so a completed order's
-- history row actually shows when the driver picked it back up and when
-- it was delivered, not just the three factory-side timestamps that were
-- enough while this view only ever showed in-progress orders. Dropped and
-- recreated rather than CREATE OR REPLACE for the same reason as 0014: new
-- columns land in the middle of the list and Postgres won't let an
-- existing view's column order change in place.

drop view if exists public.factory_orders_view;

create view public.factory_orders_view
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
      o.assigned_factory_id = auth.uid()
      or (o.assigned_factory_id is null and o.status in ('collected', 'at_factory', 'ready'))
    )
  );

grant select on public.factory_orders_view to authenticated;
