-- 0008_rls_policies.sql
-- Row Level Security for every table. Design principle: all order *status
-- transitions* happen exclusively through the SECURITY DEFINER RPCs in
-- 0009_workflow_rpcs.sql (which validate the state machine and write the audit
-- log atomically); direct table UPDATE from clients is restricted to the Owner
-- for manual corrections only. This keeps one source of truth for what
-- transitions are legal, instead of relying on RLS alone to express a workflow.
--
-- Every CREATE POLICY is preceded by a DROP POLICY IF EXISTS so this file can
-- be re-run safely (CREATE POLICY has no IF NOT EXISTS / OR REPLACE form).

-- ---------- profiles ----------
alter table public.profiles enable row level security;

drop policy if exists profiles_select_self on public.profiles;
create policy profiles_select_self on public.profiles
  for select using (id = auth.uid());

drop policy if exists profiles_select_staff on public.profiles;
create policy profiles_select_staff on public.profiles
  for select using (public.is_owner_or_moderator());

drop policy if exists profiles_update_self_limited on public.profiles;
create policy profiles_update_self_limited on public.profiles
  for update using (id = auth.uid())
  with check (id = auth.uid());

drop policy if exists profiles_update_owner on public.profiles;
create policy profiles_update_owner on public.profiles
  for update using (public.is_owner())
  with check (public.is_owner());

-- Only an Owner may change someone else's role/active flag; a self-update may
-- never change those two columns (checked in a trigger since RLS can't diff
-- old/new column values on its own).
create or replace function public.prevent_role_self_escalation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() = old.id and not public.is_owner() then
    if new.role is distinct from old.role or new.is_active is distinct from old.is_active then
      raise exception 'لا يمكنك تغيير الدور أو حالة التفعيل الخاصة بك' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_prevent_self_escalation on public.profiles;
create trigger profiles_prevent_self_escalation
  before update on public.profiles
  for each row execute function public.prevent_role_self_escalation();

-- ---------- regions ----------
alter table public.regions enable row level security;

drop policy if exists regions_select_all on public.regions;
create policy regions_select_all on public.regions
  for select using (true);

drop policy if exists regions_write_owner on public.regions;
create policy regions_write_owner on public.regions
  for all using (public.is_owner()) with check (public.is_owner());

-- ---------- driver_regions ----------
alter table public.driver_regions enable row level security;

drop policy if exists driver_regions_select on public.driver_regions;
create policy driver_regions_select on public.driver_regions
  for select using (public.is_owner_or_moderator() or driver_id = auth.uid());

drop policy if exists driver_regions_write_owner on public.driver_regions;
create policy driver_regions_write_owner on public.driver_regions
  for all using (public.is_owner()) with check (public.is_owner());

-- ---------- orders ----------
alter table public.orders enable row level security;

drop policy if exists orders_select_staff on public.orders;
create policy orders_select_staff on public.orders
  for select using (public.is_owner_or_moderator());

drop policy if exists orders_select_driver on public.orders;
create policy orders_select_driver on public.orders
  for select using (
    assigned_driver_id = auth.uid()
    and distribution_approved_at is not null
    and public.current_user_role() = 'driver'
  );

drop policy if exists orders_select_factory on public.orders;
create policy orders_select_factory on public.orders
  for select using (
    public.current_user_role() = 'factory'
    and status in ('collected', 'at_factory', 'ready')
  );

-- Direct inserts are for Owner/Moderator convenience only; the normal paths are
-- the public_create_order / moderator_create_order RPCs (SECURITY DEFINER).
drop policy if exists orders_insert_staff on public.orders;
create policy orders_insert_staff on public.orders
  for insert with check (public.is_owner_or_moderator());

-- Manual corrections only. All workflow transitions go through RPCs below.
drop policy if exists orders_update_owner on public.orders;
create policy orders_update_owner on public.orders
  for update using (public.is_owner()) with check (public.is_owner());

-- ---------- order_history ----------
alter table public.order_history enable row level security;

drop policy if exists order_history_select_staff on public.order_history;
create policy order_history_select_staff on public.order_history
  for select using (public.is_owner_or_moderator());

drop policy if exists order_history_select_driver on public.order_history;
create policy order_history_select_driver on public.order_history
  for select using (
    exists (
      select 1 from public.orders o
      where o.id = order_history.order_id
        and o.assigned_driver_id = auth.uid()
        and o.distribution_approved_at is not null
    )
  );

drop policy if exists order_history_select_factory on public.order_history;
create policy order_history_select_factory on public.order_history
  for select using (
    public.current_user_role() = 'factory'
    and exists (
      select 1 from public.orders o
      where o.id = order_history.order_id
        and o.status in ('collected', 'at_factory', 'ready')
    )
  );

-- ---------- notifications ----------
alter table public.notifications enable row level security;

drop policy if exists notifications_select_own on public.notifications;
create policy notifications_select_own on public.notifications
  for select using (user_id = auth.uid());

drop policy if exists notifications_update_own on public.notifications;
create policy notifications_update_own on public.notifications
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());
