grant usage on schema public to anon, authenticated;

grant select, update on public.profiles to authenticated;

grant select on public.regions to anon, authenticated;
grant insert, update, delete on public.regions to authenticated;

grant select, insert, update, delete on public.driver_regions to authenticated;

grant select, insert, update on public.orders to authenticated;

grant select on public.order_history to authenticated;

grant select, update on public.notifications to authenticated;

grant select on public.factory_orders_view to authenticated;
