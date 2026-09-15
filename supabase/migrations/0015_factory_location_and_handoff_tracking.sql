-- 0015_factory_location_and_handoff_tracking.sql
-- Three fixes from the same round of driver-workflow reports:
--
--   1) "the factory and its location should be added when create the order
--      and assigned and appear to the driver" — factory accounts had no
--      address at all. Adds profiles.address (free text; only meaningful,
--      and only shown in the UI, for role='factory' — it's where a driver
--      drops off a collected order and picks it back up). Read from signup
--      metadata by handle_new_user(), same as full_name/phone/role.
--
--   2) "cannot take back from the factory until the factory press ready" —
--      already correctly enforced: driver_confirm_factory_pickup (0009)
--      requires status = 'ready', which only factory_mark_ready sets, and
--      the driver has no other write path to orders (RLS's only UPDATE
--      policy is Owner-only). No change needed here; this migration doesn't
--      touch that gate. Left as a comment so the next person auditing this
--      doesn't have to re-derive it from scratch.
--
--   3) "I need the driver when do any step show on the timeline correctly"
--      — one concrete, fixable cause: driver_hand_to_factory() logs an
--      order_history event but never changes order.status (status only
--      advances once the factory itself confirms receipt) and nothing in
--      `orders` recorded that the click happened. So the driver's action
--      card kept showing the exact same "hand off to factory" button after
--      being pressed — indistinguishable from having done nothing. Adds
--      handed_to_factory_at, set once by that RPC (and guarded against a
--      second call), so the frontend can swap to a "waiting on the
--      factory" state the same way it already does for 'at_factory'.

-- ---------- 1) factory location ----------

alter table public.profiles add column if not exists address text;

comment on column public.profiles.address is
  'Free-text location/address. Only meaningful for role=factory today — the physical place a driver drops off a collected order and later picks it back up. Shown in Team management, the order-creation factory picker, and the assigned order''s detail view (including the driver''s own).';

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, phone, role, address)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.email, 'مستخدم جديد'),
    new.raw_user_meta_data ->> 'phone',
    coalesce((new.raw_user_meta_data ->> 'role')::user_role, 'driver'),
    new.raw_user_meta_data ->> 'address'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

-- ---------- 3) handoff tracking ----------

alter table public.orders add column if not exists handed_to_factory_at timestamptz;

comment on column public.orders.handed_to_factory_at is
  'Set once by driver_hand_to_factory(). Status stays ''collected'' through this step (only factory_confirm_receipt advances it to ''at_factory''), so the frontend uses this column, not status, to tell "collected, not yet handed off" apart from "handed off, waiting on the factory".';

create or replace function public.driver_hand_to_factory(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.assigned_driver_id <> auth.uid() then raise exception 'غير مصرح' using errcode = '42501'; end if;
  if v_order.status <> 'collected' then raise exception 'الأوردر ليس بحالة تسمح بالتوجه للمصنع'; end if;
  if v_order.handed_to_factory_at is not null then
    raise exception 'تم تسجيل هذه الخطوة بالفعل';
  end if;

  update public.orders set handed_to_factory_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'handed_to_factory', 'collected', 'collected', 'المندوب توجه بالأوردر إلى المصنع');
end;
$$;

-- A driver's own order-detail page reads the assigned factory's profile
-- directly (name + address), through normal RLS rather than a
-- security-definer view — and profiles RLS (0008) previously gave a driver
-- no visibility into any other user's profile at all (only their own row).
-- Scoped narrowly: a driver can see a factory profile only while that
-- factory is assigned to one of their own orders, not the whole factory
-- roster.
drop policy if exists profiles_select_factory_for_assigned_driver on public.profiles;
create policy profiles_select_factory_for_assigned_driver on public.profiles
  for select using (
    role = 'factory'
    and exists (
      select 1 from public.orders o
      where o.assigned_factory_id = profiles.id
        and o.assigned_driver_id = auth.uid()
    )
  );

-- ---------- factory address on every "who/where is the factory" read path ----------

-- factory_orders_view has security_invoker = false and does its own
-- authorization (see 0014's note on this) — dropped and recreated, same as
-- 0014, since the new column lands in the middle of the column list.
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
  o.created_at
from public.orders o
left join public.profiles p on p.id = o.assigned_driver_id
left join public.profiles f on f.id = o.assigned_factory_id
where o.status in ('collected', 'at_factory', 'ready')
  and (
    public.current_user_role() in ('owner', 'moderator')
    or (
      public.current_user_role() = 'factory'
      and (o.assigned_factory_id is null or o.assigned_factory_id = auth.uid())
    )
  );

grant select on public.factory_orders_view to authenticated;
