-- 0011_table_grants.sql
-- Explicit, portable table-level grants. RLS policies (0008) decide which *rows*
-- a role can see/touch; Postgres also requires the coarser table-level privilege
-- below before RLS is even evaluated. Written out explicitly here (rather than
-- relying on a Supabase project's implicit default grants) so this schema is
-- fully reproducible on any Postgres instance.
--
-- Note: anonymous (anon) access to orders/order_history/notifications is
-- intentionally granted nowhere — every anon-facing action (creating a website
-- order, tracking an order) goes through a SECURITY DEFINER RPC instead, which
-- bypasses table grants entirely. Direct table access for anon stays at zero.

grant usage on schema public to anon, authenticated;

grant select, update on public.profiles to authenticated;

grant select on public.regions to anon, authenticated;
grant insert, update, delete on public.regions to authenticated;

grant select, insert, update, delete on public.driver_regions to authenticated;

grant select, insert, update on public.orders to authenticated;

grant select on public.order_history to authenticated;

grant select, update on public.notifications to authenticated;

grant select on public.factory_orders_view to authenticated;
