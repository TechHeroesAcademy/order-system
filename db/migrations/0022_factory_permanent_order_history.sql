drop policy if exists orders_select_factory on public.orders;
create policy orders_select_factory on public.orders
  for select using (
    public.current_user_role() = 'factory'
    and (
      assigned_factory_id = auth.uid()
      or (assigned_factory_id is null and status in ('collected', 'at_factory', 'ready'))
    )
  );

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
