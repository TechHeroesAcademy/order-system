-- 0032_delete_worker.sql
--
-- "I need the access for the manager to delete the worker and it will
-- fully erased but the orders with his name still saved" —
--
-- "Fully erased" means the Owner can permanently remove a driver/moderator/
-- factory account (no login, gone from the team list) via the Auth Admin
-- API (auth.users delete — profiles.id already cascades off that, see
-- 0002). The problem: orders.assigned_driver_id / assigned_factory_id (and
-- a few internal-only columns below) reference profiles(id) with the
-- Postgres default ON DELETE NO ACTION, which currently BLOCKS deleting
-- any worker who was ever assigned to an order — i.e. almost every real
-- driver/factory account.
--
-- Fix, two parts:
--   1) Snapshot the driver/factory name onto the order itself the moment
--      it's assigned (trigger below), so the order keeps showing "delivered
--      by Ahmed" forever, independent of whether profiles still has a row
--      for Ahmed.
--   2) Change every profiles(id) foreign key that can point at a worker to
--      ON DELETE SET NULL, so deleting the account detaches it from old
--      rows instead of failing outright. For the columns nothing ever
--      displays by name (suggested_driver_id, distribution_approved_by,
--      created_by, order_history.actor_id) this is a no-op for the UI —
--      order_history already only ever shows actor_role, never a joined
--      name. For order_messages.sender_id the chat UI already falls back
--      to a role label when the sender relation is null (see order-chat.tsx),
--      so a deleted sender's old messages just show "مندوب"/"مصنع"/... etc
--      instead of a name, exactly like a message from an unknown sender
--      would today.

-- ---------- 1) snapshot columns + stamping trigger ----------

alter table public.orders add column if not exists assigned_driver_name text;
alter table public.orders add column if not exists assigned_factory_name text;

update public.orders o
set assigned_driver_name = p.full_name
from public.profiles p
where o.assigned_driver_id = p.id and o.assigned_driver_name is null;

update public.orders o
set assigned_factory_name = p.full_name
from public.profiles p
where o.assigned_factory_id = p.id and o.assigned_factory_name is null;

-- Stamps the name whenever assigned_driver_id/assigned_factory_id is set
-- to an actual profile. Deliberately never *clears* the name (not even
-- when the id goes null) — that's what makes the name survive both a
-- plain unassign and, later, the profile itself being deleted out from
-- under it (ON DELETE SET NULL below fires an UPDATE with the new id NULL,
-- which this trigger also sees and correctly ignores).
create or replace function public.stamp_order_assignee_names()
returns trigger
language plpgsql
as $$
begin
  if new.assigned_driver_id is not null
     and (tg_op = 'INSERT' or new.assigned_driver_id is distinct from old.assigned_driver_id) then
    select full_name into new.assigned_driver_name from public.profiles where id = new.assigned_driver_id;
  end if;

  if new.assigned_factory_id is not null
     and (tg_op = 'INSERT' or new.assigned_factory_id is distinct from old.assigned_factory_id) then
    select full_name into new.assigned_factory_name from public.profiles where id = new.assigned_factory_id;
  end if;

  return new;
end;
$$;

drop trigger if exists stamp_order_assignee_names on public.orders;
create trigger stamp_order_assignee_names
  before insert or update on public.orders
  for each row execute function public.stamp_order_assignee_names();

-- ---------- 2) profiles(id) FKs: NO ACTION -> SET NULL ----------

alter table public.orders drop constraint orders_assigned_driver_id_fkey;
alter table public.orders add constraint orders_assigned_driver_id_fkey
  foreign key (assigned_driver_id) references public.profiles (id) on delete set null;

alter table public.orders drop constraint orders_suggested_driver_id_fkey;
alter table public.orders add constraint orders_suggested_driver_id_fkey
  foreign key (suggested_driver_id) references public.profiles (id) on delete set null;

alter table public.orders drop constraint orders_distribution_approved_by_fkey;
alter table public.orders add constraint orders_distribution_approved_by_fkey
  foreign key (distribution_approved_by) references public.profiles (id) on delete set null;

alter table public.orders drop constraint orders_created_by_fkey;
alter table public.orders add constraint orders_created_by_fkey
  foreign key (created_by) references public.profiles (id) on delete set null;

alter table public.orders drop constraint orders_assigned_factory_id_fkey;
alter table public.orders add constraint orders_assigned_factory_id_fkey
  foreign key (assigned_factory_id) references public.profiles (id) on delete set null;

alter table public.order_history drop constraint order_history_actor_id_fkey;
alter table public.order_history add constraint order_history_actor_id_fkey
  foreign key (actor_id) references public.profiles (id) on delete set null;

-- sender_id was "not null" — a deleted sender has to be able to go null,
-- so the column itself has to allow it before the constraint can.
alter table public.order_messages alter column sender_id drop not null;
alter table public.order_messages drop constraint order_messages_sender_id_fkey;
alter table public.order_messages add constraint order_messages_sender_id_fkey
  foreign key (sender_id) references public.profiles (id) on delete set null;

alter table public.order_messages drop constraint order_messages_driver_id_fkey;
alter table public.order_messages add constraint order_messages_driver_id_fkey
  foreign key (driver_id) references public.profiles (id) on delete set null;

-- ---------- 3) factory_orders_view: stop reading the driver's name via a
--    live join to profiles ----------
--
-- Same bug as everywhere else: `p.full_name as assigned_driver_name` reads
-- the *current* profiles row every time the view is queried, so a factory
-- looking at its own permanent order history (0022) would see a deleted
-- driver's name vanish. Point it at the new snapshot column on orders
-- instead — same column name, same position, so CREATE OR REPLACE is fine
-- (see 0023's note: only legal when the SELECT list doesn't change shape).
-- The driver join is dropped entirely since nothing else in this view used
-- it; the factory join stays, for assigned_factory_address (there is no
-- persistent snapshot of a factory's address — losing it once the factory
-- account is deleted is fine, since there both is nowhere left to send a
-- driver and the factory's *name* still shows via o.assigned_factory_name).

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
  o.assigned_driver_name,
  o.assigned_factory_id,
  o.assigned_factory_name,
  f.address as assigned_factory_address,
  o.collected_at,
  o.handed_to_factory_at,
  o.factory_received_at,
  o.factory_ready_at,
  o.driver_pickup_at,
  o.delivered_at,
  o.created_at
from public.orders o
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
