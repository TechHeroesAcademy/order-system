-- ============================================================================
-- NEON SETUP — PART 3 OF 6
--
-- PASTE THIS WHOLE FILE INTO NEON'S SQL EDITOR AND RUN IT.
-- Run the parts in order. Wait for each to finish before starting the next.
-- Each part is safe to re-run: every statement is idempotent.
--
-- Requires the previous part to have finished.
--
-- GENERATED — do not edit. Edit the source files listed below and re-run
-- scripts/build-neon-bundle.mjs, so Supabase and Neon cannot drift apart.
--
-- Contains, in order:
--    1. supabase/migrations/0032_delete_worker.sql
--    2. supabase/migrations/0033_factories_table.sql
--    3. supabase/migrations/0034_driver_runs_factory_steps_and_chat_lockdown.sql
--    4. supabase/migrations/0035_bulk_distribution.sql
--    5. supabase/migrations/0036_driver_removal_reassignment.sql
--    6. supabase/migrations/0037_edit_driver_details.sql
--    7. supabase/migrations/0038_retire_factory_role.sql
--    8. supabase/migrations/0039_report_performance.sql
--    9. supabase/migrations/0040_push_subscriptions_and_manager_factories.sql
--   10. neon/migrations/0041_push_dispatch_trigger.neon.sql
--   11. supabase/migrations/0042_push_settings_table.sql
--   12. supabase/migrations/0043_moderator_notifications_delivered_only.sql
-- ============================================================================

-- The chain installs pgcrypto/pg_trgm into the extensions schema (as Supabase
-- does) and several functions resolve against it. Declared per part rather
-- than relied on from the database default, so pasting a part into a fresh
-- editor session always works.
set search_path = public, extensions;



-- ========== supabase/migrations/0032_delete_worker.sql ================

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


-- ========== supabase/migrations/0033_factories_table.sql ==============

-- 0033_factories_table.sql
--
-- Factories stop being login accounts and become what they actually are:
-- places an order is routed to. Until now a factory was a `profiles` row with
-- role='factory', which meant the company's two workshops were modelled as
-- staff members with passwords, sessions and a dashboard.
--
-- This migration is deliberately ZERO behaviour change: it creates the new
-- table, copies the existing factories into it **preserving their UUIDs**, and
-- repoints everything that reads factory data. Factory accounts keep working
-- exactly as before — they are retired in a later migration, after the app
-- build that stops using them is live.
--
-- Why preserve the UUIDs: orders.assigned_factory_id already holds those ids
-- across every order ever created. Keeping them means the foreign key can be
-- repointed with zero data remapping, no window where the column dangles, and
-- no risk of silently reattaching an order to the wrong factory.
--
-- Ordering inside this file matters and it is all one transaction (the Supabase
-- SQL editor wraps a submitted script in one, and DDL is transactional in
-- Postgres): create → copy → assert no orphans → swap the constraint → repoint
-- the readers. Either all of it lands or none of it does.

-- ── the table ───────────────────────────────────────────────────────────
create table if not exists public.factories (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text,
  address text,
  lat double precision,
  lng double precision,
  maps_url text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.factories is
  'Workshops an order is routed to. Replaces the old profiles.role=''factory'' '
  'accounts — a factory is a place, not a user, and has no login.';

drop trigger if exists set_factories_updated_at on public.factories;
create trigger set_factories_updated_at
  before update on public.factories
  for each row execute function public.set_updated_at();

-- ── copy the existing factories, ids and all ────────────────────────────
-- Selected by union rather than by role alone: if any order references an id
-- that is no longer role='factory' (data drift, a role edited by hand), a
-- role-only copy would miss it and the constraint swap below would fail
-- halfway. The union guarantees every referenced id gets a row.
--
-- phone, is_active and created_at come along too — phone is the only way to
-- ring the workshop, and dropping it here would lose it for good.
insert into public.factories (id, name, phone, address, lat, lng, maps_url, is_active, created_at)
select p.id, p.full_name, p.phone, p.address, p.lat, p.lng, p.maps_url, p.is_active, p.created_at
from public.profiles p
where p.role = 'factory'
   or p.id in (select o.assigned_factory_id from public.orders o where o.assigned_factory_id is not null)
on conflict (id) do nothing;

-- ── prove there is nothing to lose before touching the constraint ───────
do $$
declare
  v_orphans integer;
begin
  select count(*) into v_orphans
  from public.orders o
  where o.assigned_factory_id is not null
    and not exists (select 1 from public.factories f where f.id = o.assigned_factory_id);

  if v_orphans > 0 then
    raise exception
      'ABORT: % order(s) point at a factory id with no matching factories row. '
      'Nothing has been changed. Investigate before re-running.', v_orphans;
  end if;
end $$;

-- ── repoint the foreign key ─────────────────────────────────────────────
-- ON DELETE RESTRICT, not SET NULL. 0032 used SET NULL only because deleting
-- an auth user cascaded into profiles and would otherwise have blocked
-- deleting any worker. That reason is gone: a factory is no longer an auth
-- user. Keeping SET NULL would mean one stray `delete from factories`
-- silently detaches every historical order from its factory, recoverable only
-- by fuzzy-matching the snapshot name. RESTRICT makes that impossible;
-- deactivating (is_active = false) is the real "retire a factory" operation.
alter table public.orders drop constraint if exists orders_assigned_factory_id_fkey;
alter table public.orders add constraint orders_assigned_factory_id_fkey
  foreign key (assigned_factory_id) references public.factories (id) on delete restrict;

-- ── access ──────────────────────────────────────────────────────────────
-- Every signed-in role may read factories: drivers need the address and map
-- pin of the workshop they're driving to, and staff need the list to route
-- orders. This replaces the narrow per-order policy on profiles
-- (profiles_select_factory_for_assigned_driver, 0015) which existed because
-- profiles rows carry personal data for *people*. A factories row is the
-- company's own workshop address — there is nothing here to scope per order,
-- and dropping the correlated subquery makes every profiles read cheaper.
-- Writes are not granted at all: they go through the SECURITY DEFINER RPCs
-- below, which carry the authorization checks.
alter table public.factories enable row level security;

drop policy if exists factories_select on public.factories;
create policy factories_select on public.factories
  for select to authenticated using (true);

grant select on public.factories to authenticated;

-- ── repoint: the snapshot-name trigger ──────────────────────────────────
-- This one is the quiet data-loss risk. The 0032 version reads
--   select full_name into new.assigned_factory_name from public.profiles ...
-- and in plpgsql a SELECT ... INTO that matches zero rows sets the target to
-- NULL. So the moment the factory profile rows go away, the next update that
-- touches assigned_factory_id would blank the very snapshot column 0032 added
-- to preserve the name. Reading from factories fixes the source; the coalesce
-- makes it structurally impossible to blank an existing name even if the row
-- is missing for any other reason.
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
    select coalesce(f.name, new.assigned_factory_name) into new.assigned_factory_name
    from public.factories f where f.id = new.assigned_factory_id;
  end if;

  return new;
end;
$$;

-- ── repoint: order creation ─────────────────────────────────────────────
-- Factory selection is mandatory at creation, and this function validates the
-- chosen factory against profiles. If it isn't repointed before the factory
-- profiles are removed, order creation stops working outright. Body is
-- otherwise byte-for-byte the 0025 version.
create or replace function public.create_order_internal(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_name text,
  p_pieces_count integer,
  p_piece_details text,
  p_color text,
  p_work_required text,
  p_customer_notes text,
  p_source order_source,
  p_created_by uuid,
  p_factory_id uuid default null,
  p_driver_id uuid default null,
  p_customer_maps_url text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := public.generate_delivery_code();
  v_pickup_code text := public.generate_delivery_code();
  v_region_id uuid;
  v_order public.orders;
  v_result public.new_order_result;
  v_factory public.factories;
  v_driver public.profiles;
  v_new_status public.order_status;
  v_maps_url text := nullif(trim(coalesce(p_customer_maps_url, '')), '');
  v_auto_driver_id uuid;
  v_auto_driver_name text;
begin
  if length(trim(p_customer_name)) = 0 then
    raise exception 'اسم العميل مطلوب' using errcode = '22023';
  end if;
  if length(trim(p_customer_phone)) < 8 then
    raise exception 'رقم هاتف العميل غير صالح' using errcode = '22023';
  end if;
  if p_pieces_count is null or p_pieces_count < 1 then
    raise exception 'عدد القطع يجب أن يكون 1 على الأقل' using errcode = '22023';
  end if;

  -- Mandatory + resolved to a canonical region row here — after the basic
  -- field checks above, so an invalid name never gets created as a
  -- side effect of a request that was going to fail anyway.
  v_region_id := public.find_or_create_region(p_region_name);

  if p_factory_id is not null then
    select * into v_factory from public.factories where id = p_factory_id;
    if v_factory is null or not v_factory.is_active then
      raise exception 'المصنع المحدد غير صالح' using errcode = '22023';
    end if;
  end if;

  if p_driver_id is not null then
    select * into v_driver from public.profiles where id = p_driver_id;
    if v_driver is null or v_driver.role <> 'driver' or not v_driver.is_active then
      raise exception 'المندوب المحدد غير صالح' using errcode = '22023';
    end if;
  end if;

  insert into public.orders (
    customer_name, customer_phone, customer_address, customer_maps_url, region_id,
    pieces_count, piece_details, color, work_required, customer_notes,
    source, created_by, delivery_code_hash, pickup_code_hash, assigned_factory_id
  ) values (
    trim(p_customer_name), trim(p_customer_phone), trim(p_customer_address), v_maps_url, v_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    p_source, p_created_by, crypt(v_code, gen_salt('bf')), crypt(v_pickup_code, gen_salt('bf')), p_factory_id
  )
  returning * into v_order;

  insert into public.order_delivery_codes (order_id, code) values (v_order.id, v_code);
  insert into public.order_pickup_codes (order_id, code) values (v_order.id, v_pickup_code);

  perform public.log_order_event(v_order.id, 'created', null, 'new',
    'تم إنشاء الأوردر عبر ' || case when p_source = 'website' then 'الموقع' else 'Messenger' end);

  if p_driver_id is not null then
    v_new_status := case when v_order.status = 'new' then 'assigned' else v_order.status end;

    update public.orders
      set assigned_driver_id = p_driver_id,
          distribution_approved_at = now(),
          distribution_approved_by = p_created_by,
          status = v_new_status
      where id = v_order.id;

    v_order.status := v_new_status;

    perform public.log_order_event(v_order.id, 'driver_reassigned', 'new', v_new_status,
      'تم تعيين مندوب عند إنشاء الأوردر: ' || v_driver.full_name);

    perform public.notify_user(p_driver_id, v_order.id, 'order_assigned',
      'تم إسناد أوردر إليك ' || v_order.order_number, 'العميل: ' || v_order.customer_name);
  else
    -- Same fair, region-based suggestion as 0024 — only the input changed,
    -- not the matching itself: v_region_id is the same canonical id
    -- pick_fair_driver_for_region() always matched on before this.
    v_auto_driver_id := public.pick_fair_driver_for_region(v_region_id);
    if v_auto_driver_id is not null then
      update public.orders
        set assigned_driver_id = v_auto_driver_id,
            suggested_driver_id = v_auto_driver_id
        where id = v_order.id;

      select full_name into v_auto_driver_name from public.profiles where id = v_auto_driver_id;
      perform public.log_order_event(v_order.id, 'distribution_set', 'new', 'new',
        'تم اقتراح مندوب تلقائيًا حسب المنطقة: ' || v_auto_driver_name || ' (بانتظار اعتماد المدير)');
    end if;
  end if;

  perform public.notify_role('owner', v_order.id, 'new_order', 'أوردر جديد ' || v_order.order_number,
    'تم استلام أوردر جديد من ' || v_order.customer_name);

  v_result.order_id := v_order.id;
  v_result.order_number := v_order.order_number;
  v_result.delivery_code := v_code;
  v_result.pickup_code := v_pickup_code;
  return v_result;
end;
$$;

-- ── repoint: factory reassignment ───────────────────────────────────────
-- Two changes from the 0024 version: the factory is validated against
-- factories instead of profiles, and the notify_user() aimed at the factory
-- account is dropped. That second one is not cosmetic — notifications.user_id
-- has a foreign key to profiles, so once assigned_factory_id stops being a
-- profiles id, that call would raise a foreign-key violation and take the
-- whole reassignment down with it.
create or replace function public.reassign_order_factory(p_order_id uuid, p_new_factory_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_new_factory public.factories;
  v_old_factory_name text;
begin
  if not public.is_owner() then
    raise exception 'تغيير المصنع من صلاحية المدير فقط' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status in ('delivered', 'cancelled', 'refused') then
    raise exception 'لا يمكن تغيير المصنع لأوردر منتهٍ';
  end if;

  select * into v_new_factory from public.factories where id = p_new_factory_id;
  if v_new_factory is null or not v_new_factory.is_active then
    raise exception 'المصنع المحدد غير صالح';
  end if;
  if v_order.assigned_factory_id = p_new_factory_id then
    raise exception 'هذا المصنع مخصص للأوردر بالفعل';
  end if;

  if v_order.assigned_factory_id is not null then
    select name into v_old_factory_name from public.factories where id = v_order.assigned_factory_id;
  end if;

  update public.orders set assigned_factory_id = p_new_factory_id where id = p_order_id;

  perform public.log_order_event(p_order_id, 'factory_reassigned', v_order.status, v_order.status,
    case when v_old_factory_name is not null
      then 'تم تغيير المصنع من ' || v_old_factory_name || ' إلى ' || v_new_factory.name
      else 'تم تحديد المصنع: ' || v_new_factory.name
    end);

  if v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'factory_reassigned',
      'تم تغيير المصنع الخاص بالأوردر ' || v_order.order_number,
      'المصنع الجديد: ' || v_new_factory.name);
  end if;

  perform public.notify_staff(p_order_id, 'factory_reassigned',
    'تم تغيير مصنع الأوردر ' || v_order.order_number, null, auth.uid());
end;
$$;

-- ── factory CRUD ────────────────────────────────────────────────────────
-- Authorization deliberately mirrors what the equivalent staff-account
-- actions allow today, so nobody silently gains or loses an ability in this
-- migration: creating and deleting were owner-only (createStaffAccountAction,
-- deleteStaffAccountAction), editing details and toggling active were
-- owner-or-moderator (updateStaffLocationAction, setStaffActiveAction).

create or replace function public.create_factory(
  p_name text,
  p_phone text default null,
  p_address text default null,
  p_lat double precision default null,
  p_lng double precision default null,
  p_maps_url text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not public.is_owner() then
    raise exception 'إضافة مصنع من صلاحية المدير فقط' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_name, ''))) < 2 then
    raise exception 'اسم المصنع مطلوب' using errcode = '22023';
  end if;

  insert into public.factories (name, phone, address, lat, lng, maps_url)
  values (trim(p_name), nullif(trim(coalesce(p_phone, '')), ''), p_address, p_lat, p_lng, p_maps_url)
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.update_factory(
  p_factory_id uuid,
  p_name text,
  p_phone text default null,
  p_address text default null,
  p_lat double precision default null,
  p_lng double precision default null,
  p_maps_url text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_name, ''))) < 2 then
    raise exception 'اسم المصنع مطلوب' using errcode = '22023';
  end if;
  if not exists (select 1 from public.factories where id = p_factory_id) then
    raise exception 'المصنع غير موجود';
  end if;

  update public.factories
     set name = trim(p_name),
         phone = nullif(trim(coalesce(p_phone, '')), ''),
         address = p_address,
         lat = p_lat,
         lng = p_lng,
         maps_url = p_maps_url
   where id = p_factory_id;
end;
$$;

create or replace function public.set_factory_active(p_factory_id uuid, p_is_active boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  update public.factories set is_active = p_is_active where id = p_factory_id;
  if not found then
    raise exception 'المصنع غير موجود';
  end if;
end;
$$;

-- Deletion is a real delete, and the RESTRICT constraint means it only
-- succeeds for a factory no order has ever used. That is the intended
-- behaviour — a workshop with history is deactivated, never deleted — so the
-- foreign-key error is caught and turned into an instruction rather than a
-- raw Postgres message.
create or replace function public.delete_factory(p_factory_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner() then
    raise exception 'حذف مصنع من صلاحية المدير فقط' using errcode = '42501';
  end if;

  delete from public.factories where id = p_factory_id;
  if not found then
    raise exception 'المصنع غير موجود';
  end if;
exception
  when foreign_key_violation then
    raise exception 'لا يمكن حذف مصنع مرتبط بأوردرات. استخدم "تعطيل" بدلًا من الحذف.'
      using errcode = '23503';
end;
$$;

revoke all on function public.create_factory(text, text, text, double precision, double precision, text) from public, anon;
revoke all on function public.update_factory(uuid, text, text, text, double precision, double precision, text) from public, anon;
revoke all on function public.set_factory_active(uuid, boolean) from public, anon;
revoke all on function public.delete_factory(uuid) from public, anon;

grant execute on function public.create_factory(text, text, text, double precision, double precision, text) to authenticated;
grant execute on function public.update_factory(uuid, text, text, text, double precision, double precision, text) to authenticated;
grant execute on function public.set_factory_active(uuid, boolean) to authenticated;
grant execute on function public.delete_factory(uuid) to authenticated;


-- ========== supabase/migrations/0034_driver_runs_factory_steps_and_chat_lockdown.sql 

-- 0034_driver_runs_factory_steps_and_chat_lockdown.sql
--
-- Two changes, both prerequisites for retiring the factory accounts:
--
-- 1. The DRIVER now presses the factory steps. Waiting for a factory account
--    to confirm receipt and then mark the work finished was the bottleneck
--    this whole change exists to remove — the driver is standing at the
--    workshop, so the driver records what happened.
--
-- 2. Chat becomes driver <-> Manager only. The factory channel is closed,
--    and Moderators lose chat entirely (read and write).
--
-- Every function here keeps its exact signature and is replaced in place, so
-- this migration is correct for BOTH the currently-deployed build and the one
-- that follows it. That is what makes it safe to run this before deploying,
-- which is the required order — see the transitional note on the factory role
-- below.

-- ── the two factory steps, now driver-operated ──────────────────────────
-- Authorization changes shape here. The old check was role-only:
--   if public.current_user_role() not in ('factory','owner','moderator')
-- which never checked whether the order had anything to do with the caller —
-- any factory account could advance any order in the system. That gap is
-- fixed while we're in here: the row is now locked BEFORE the authorization
-- decision, because the decision needs the row.
--
-- The 'factory' term is TRANSITIONAL. It exists only so a factory account
-- still signed in on the current build keeps working between this migration
-- and the deploy that removes their screens. It is removed in the cleanup
-- migration once no profile carries that role.

create or replace function public.factory_confirm_receipt(p_order_id uuid)
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

  if not (
    coalesce(public.is_owner_or_moderator(), false)
    or (public.current_user_role() = 'driver' and v_order.assigned_driver_id = auth.uid())
    or public.current_user_role() = 'factory'  -- transitional, removed in cleanup
  ) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  if v_order.status <> 'collected' then raise exception 'الأوردر ليس بحالة تسمح بتأكيد الاستلام في المصنع'; end if;

  -- When the driver records this themselves they may never have pressed the
  -- separate "heading to the factory" button, which is what used to stamp
  -- handed_to_factory_at. Stamp it here if it's still empty so
  -- handed_to_factory_at <= factory_received_at always holds — the daily
  -- report's "entered factory" count and the customer tracking timeline both
  -- read those two together.
  update public.orders
     set status = 'at_factory',
         factory_received_at = now(),
         handed_to_factory_at = coalesce(handed_to_factory_at, now())
   where id = p_order_id;

  perform public.log_order_event(p_order_id, 'factory_confirmed_receipt', 'collected', 'at_factory',
    'تم تسليم الأوردر للمصنع');

  -- Don't notify the driver about their own press.
  if v_order.assigned_driver_id is not null and v_order.assigned_driver_id is distinct from auth.uid() then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'factory_received',
      'تم استلام الأوردر ' || v_order.order_number || ' في المصنع', null);
  end if;

  perform public.notify_staff(p_order_id, 'factory_received',
    'تم تسليم الأوردر ' || v_order.order_number || ' للمصنع', null, auth.uid());
end;
$$;

create or replace function public.factory_mark_ready(p_order_id uuid)
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

  if not (
    coalesce(public.is_owner_or_moderator(), false)
    or (public.current_user_role() = 'driver' and v_order.assigned_driver_id = auth.uid())
    or public.current_user_role() = 'factory'  -- transitional, removed in cleanup
  ) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  if v_order.status <> 'at_factory' then raise exception 'الأوردر ليس داخل المصنع حاليًا'; end if;

  update public.orders set status = 'ready', factory_ready_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'factory_marked_ready', 'at_factory', 'ready',
    'المصنع أنهى العمل والأوردر جاهز للاستلام');

  if v_order.assigned_driver_id is not null and v_order.assigned_driver_id is distinct from auth.uid() then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'ready_for_pickup',
      'أوردر ' || v_order.order_number || ' جاهز للتسليم', 'يمكنك استلامه من المصنع الآن');
  end if;

  perform public.notify_staff(p_order_id, 'ready_for_pickup',
    'الأوردر ' || v_order.order_number || ' جاهز للاستلام من المصنع', null, auth.uid());
end;
$$;

-- ── stop notifying the factory account ──────────────────────────────────
-- Not cosmetic: notifications.user_id has a foreign key to profiles, and
-- assigned_factory_id now points at factories. Leaving these calls in place
-- would make the driver's hand-off and pickup raise a foreign-key violation
-- the moment the factory profile rows are deleted — the driver would simply
-- be unable to record either step. Bodies are otherwise unchanged from 0019.

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
  perform public.notify_staff(p_order_id, 'driver_heading_to_factory',
    'المندوب في الطريق للمصنع — الأوردر ' || v_order.order_number, null, auth.uid());
end;
$$;

create or replace function public.driver_confirm_factory_pickup(p_order_id uuid)
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
  if v_order.status <> 'ready' then raise exception 'الأوردر ليس جاهزًا للاستلام من المصنع بعد'; end if;

  update public.orders set status = 'with_driver', driver_pickup_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'driver_picked_up_from_factory', 'ready', 'with_driver', 'استلم المندوب الأوردر من المصنع');
  perform public.notify_staff(p_order_id, 'driver_left_factory',
    'استلم المندوب الأوردر ' || v_order.order_number || ' من المصنع وغادر', null, auth.uid());
end;
$$;

-- ── chat: driver <-> Manager only ───────────────────────────────────────
-- The factory channel is closed to new messages (existing ones stay readable
-- by a Manager as history), and Moderators lose chat entirely.
--
-- Note the notification change at the bottom: driver messages used to go
-- through notify_staff, which notifies Managers AND Moderators, with the
-- message text as the notification body. Changing only the read policy would
-- have stopped Moderators opening the chat while still delivering them every
-- message verbatim in their notification bell.

create or replace function public.send_order_message(p_order_id uuid, p_channel text, p_body text)
returns public.order_messages
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_role user_role := public.current_user_role();
  v_body text := trim(coalesce(p_body, ''));
  v_channel text := coalesce(p_channel, 'driver');
  v_row public.order_messages;
begin
  if v_channel <> 'driver' then
    raise exception 'قناة الدردشة الوحيدة المتاحة هي دردشة المندوب' using errcode = '22023';
  end if;
  if length(v_body) = 0 then
    raise exception 'اكتب رسالة قبل الإرسال' using errcode = '22023';
  end if;
  if length(v_body) > 1000 then
    raise exception 'الرسالة طويلة جدًا — بحد أقصى 1000 حرف' using errcode = '22023';
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if v_order is null then
    raise exception 'الأوردر غير موجود';
  end if;

  if not (
    public.is_owner()
    or (v_role = 'driver' and v_order.assigned_driver_id = auth.uid())
  ) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  -- driver_id stamps which driver's stint this message belongs to — see
  -- can_read_order_channel (0029) for why that matters after a reassignment.
  insert into public.order_messages (order_id, channel, sender_id, sender_role, body, driver_id)
  values (p_order_id, v_channel, auth.uid(), v_role, v_body, v_order.assigned_driver_id)
  returning * into v_row;

  if v_role = 'driver' then
    -- notify_role('owner', ...) rather than notify_staff: the body carries
    -- the message text, and Moderators are no longer part of these
    -- conversations.
    perform public.notify_role('owner', p_order_id, 'chat_message',
      'رسالة جديدة من المندوب على الأوردر ' || v_order.order_number, v_body);
  elsif v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'chat_message',
      'رسالة جديدة على الأوردر ' || v_order.order_number, v_body);
  end if;

  return v_row;
end;
$$;

-- Read side. is_owner() replaces is_owner_or_moderator(); the
-- can_read_order_channel() branch is what still lets the assigned driver read
-- their own stint's messages.
drop policy if exists order_messages_select on public.order_messages;
create policy order_messages_select on public.order_messages
  for select using (
    public.is_owner()
    or public.can_read_order_channel(order_messages.order_id, order_messages.channel, auth.uid(), order_messages.driver_id)
  );


-- ========== supabase/migrations/0035_bulk_distribution.sql ============

-- 0035_bulk_distribution.sql
--
-- Approving distribution one order at a time, from inside each order's own
-- page, is the slowest thing a manager does. This adds set-based versions so
-- a whole area's worth of orders can be moved to a driver and approved in one
-- press, without changing what approving an order means.
--
-- Structure follows the create_order_internal pattern already used in
-- 0007/0014: the real work is extracted into an internal function, and both
-- the single-order RPC and the bulk RPC call it. That's what guarantees the
-- bulk path writes the same history event and sends the same notification as
-- the single path — there is no second copy of the logic to drift.

-- ── approve: the extracted body ─────────────────────────────────────────
-- Identical to the 0009 approve_distribution body with only the is_owner()
-- check lifted out to the callers. Internal: never granted to a client role.
create or replace function public.approve_distribution_one(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then
    raise exception 'الأوردر غير موجود';
  end if;
  if v_order.status <> 'new' then
    raise exception 'الأوردر ليس في حالة تسمح باعتماد التوزيع';
  end if;
  if v_order.assigned_driver_id is null then
    raise exception 'لا يوجد مندوب محدد لهذا الأوردر';
  end if;

  update public.orders
    set status = 'assigned',
        distribution_approved_at = now(),
        distribution_approved_by = auth.uid()
    where id = p_order_id;

  perform public.log_order_event(p_order_id, 'distribution_approved', 'new', 'assigned', 'تم اعتماد التوزيع وإرسال الأوردر للمندوب');
  perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'order_assigned',
    'أوردر جديد تم إسناده إليك ' || v_order.order_number,
    'العميل: ' || v_order.customer_name);
end;
$$;

create or replace function public.approve_distribution(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner() then
    raise exception 'اعتماد التوزيع من صلاحية المدير فقط' using errcode = '42501';
  end if;
  perform public.approve_distribution_one(p_order_id);
end;
$$;

-- ── approve: the bulk version ───────────────────────────────────────────
-- Returns a row per requested order rather than failing the whole call, so
-- one order that someone else already approved (or that has no driver yet)
-- doesn't throw away the other nineteen.
--
-- The begin/exception block around each order is what makes that work: a
-- plpgsql block with an EXCEPTION clause opens an implicit subtransaction, so
-- a failure rolls back only that order's update, history row and
-- notification, and the loop carries on.
--
-- ORDER BY is load-bearing, not tidiness. A bulk call holds row locks for
-- every order it touches until it commits, so two managers approving
-- overlapping selections in different on-screen orders would deadlock. Taking
-- the locks in a deterministic order means one simply waits for the other.
create or replace function public.approve_distribution_bulk(p_order_ids uuid[])
returns table (order_id uuid, order_number text, succeeded boolean, error text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not public.is_owner() then
    raise exception 'اعتماد التوزيع من صلاحية المدير فقط' using errcode = '42501';
  end if;
  if coalesce(array_length(p_order_ids, 1), 0) = 0 then
    return;
  end if;
  -- Bounded so one press can't hold hundreds of row locks on a live system.
  if array_length(p_order_ids, 1) > 200 then
    raise exception 'لا يمكن اعتماد أكثر من 200 أوردر في المرة الواحدة' using errcode = '22023';
  end if;

  for v_id in select distinct u from unnest(p_order_ids) u order by 1 loop
    order_id := v_id;
    select o.order_number into order_number from public.orders o where o.id = v_id;

    begin
      perform public.approve_distribution_one(v_id);
      succeeded := true;
      error := null;
    exception when others then
      succeeded := false;
      error := sqlerrm;
    end;

    return next;
  end loop;
end;
$$;

-- ── assign a driver: the same split ─────────────────────────────────────
-- Used by the bulk screen's "move the selected orders to this driver" before
-- approving. set_order_distribution (rather than reassign_order_driver) is
-- the right primitive here: the screen only ever shows orders still waiting
-- for approval, and this leaves them waiting.
create or replace function public.set_order_distribution_one(
  p_order_id uuid,
  p_driver_id uuid,
  p_is_suggestion boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status order_status;
begin
  select status into v_status from public.orders where id = p_order_id for update;
  if v_status is null then
    raise exception 'الأوردر غير موجود';
  end if;
  if v_status <> 'new' then
    raise exception 'لا يمكن تعديل توزيع أوردر تم اعتماده بالفعل';
  end if;

  update public.orders
    set assigned_driver_id = p_driver_id,
        suggested_driver_id = case when p_is_suggestion then p_driver_id else suggested_driver_id end
    where id = p_order_id;

  perform public.log_order_event(p_order_id, 'distribution_set', v_status, v_status,
    'تم تحديد مندوب للتوزيع (بانتظار الاعتماد)');
end;
$$;

create or replace function public.set_order_distribution(p_order_id uuid, p_driver_id uuid, p_is_suggestion boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner() then
    raise exception 'تحديد المندوب من صلاحية المدير فقط' using errcode = '42501';
  end if;
  perform public.set_order_distribution_one(p_order_id, p_driver_id, p_is_suggestion);
end;
$$;

create or replace function public.set_order_distribution_bulk(p_order_ids uuid[], p_driver_id uuid)
returns table (order_id uuid, order_number text, succeeded boolean, error text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_driver public.profiles;
begin
  if not public.is_owner() then
    raise exception 'تحديد المندوب من صلاحية المدير فقط' using errcode = '42501';
  end if;
  if coalesce(array_length(p_order_ids, 1), 0) = 0 then
    return;
  end if;
  if array_length(p_order_ids, 1) > 200 then
    raise exception 'لا يمكن تعديل أكثر من 200 أوردر في المرة الواحدة' using errcode = '22023';
  end if;

  -- Validated once, before touching anything: a bad driver id is a mistake
  -- about the whole selection, not a per-order outcome.
  select * into v_driver from public.profiles where id = p_driver_id;
  if v_driver is null or v_driver.role <> 'driver' or not v_driver.is_active then
    raise exception 'المندوب المحدد غير صالح' using errcode = '22023';
  end if;

  for v_id in select distinct u from unnest(p_order_ids) u order by 1 loop
    order_id := v_id;
    select o.order_number into order_number from public.orders o where o.id = v_id;

    begin
      perform public.set_order_distribution_one(v_id, p_driver_id, false);
      succeeded := true;
      error := null;
    exception when others then
      succeeded := false;
      error := sqlerrm;
    end;

    return next;
  end loop;
end;
$$;

-- ── grants ──────────────────────────────────────────────────────────────
-- The _one functions carry no authorization of their own, so they must never
-- be callable directly by a client — only through the wrappers above.
revoke all on function public.approve_distribution_one(uuid) from public, anon, authenticated;
revoke all on function public.set_order_distribution_one(uuid, uuid, boolean) from public, anon, authenticated;

revoke all on function public.approve_distribution_bulk(uuid[]) from public, anon;
revoke all on function public.set_order_distribution_bulk(uuid[], uuid) from public, anon;
grant execute on function public.approve_distribution_bulk(uuid[]) to authenticated;
grant execute on function public.set_order_distribution_bulk(uuid[], uuid) to authenticated;

-- ── "needs a driver" flag ───────────────────────────────────────────────
-- The board shows every order with no driver that isn't finished, which is a
-- derived predicate and needs no column. These two exist for the part that
-- can't be derived: WHY an order is sitting there, and how urgent it is.
--
-- An order at 'new' with no driver is routine backlog — nobody covers that
-- area yet, or a manager cleared the suggestion. An order at 'assigned' or
-- later with no driver is an orphan mid-delivery, which is impossible today
-- and only becomes reachable once removing a driver can strand their work
-- (the next migration). The flag is what tells those apart and carries the
-- reason into the notification.
--
-- Columns land here, one migration ahead of the code that sets them, so the
-- board can ship complete rather than with a half-built queue.
alter table public.orders add column if not exists needs_allocation_at timestamptz;
alter table public.orders add column if not exists needs_allocation_reason text;

create index if not exists orders_needs_allocation_idx
  on public.orders (needs_allocation_at) where needs_allocation_at is not null;

comment on column public.orders.needs_allocation_at is
  'Set when an order was left without a driver by something other than normal '
  'backlog (today: the assigned driver being removed with no one covering the '
  'area). Cleared automatically by stamp_order_assignee_names the moment a '
  'driver is assigned or the order reaches a terminal status.';

-- Clearing lives in the existing BEFORE INSERT OR UPDATE trigger rather than
-- in each RPC that can assign a driver. There are five such paths
-- (set_order_distribution, reassign_order_driver, approve_distribution,
-- create_order_internal, and a manual owner UPDATE); a flag that has to be
-- cleared by hand in each would eventually be forgotten in one, and a stale
-- "needs a driver" banner on an order that has one is worse than no banner.
-- Same signature as the 0033 version, so the trigger itself is untouched.
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
    select coalesce(f.name, new.assigned_factory_name) into new.assigned_factory_name
    from public.factories f where f.id = new.assigned_factory_id;
  end if;

  if new.assigned_driver_id is not null and (tg_op = 'INSERT' or old.assigned_driver_id is null) then
    new.needs_allocation_at := null;
    new.needs_allocation_reason := null;
  end if;

  if new.status in ('delivered', 'cancelled', 'refused') then
    new.needs_allocation_at := null;
    new.needs_allocation_reason := null;
  end if;

  return new;
end;
$$;


-- ========== supabase/migrations/0036_driver_removal_reassignment.sql ==

-- 0036_driver_removal_reassignment.sql
--
-- Removing a driver used to silently strand their work. The foreign keys are
-- ON DELETE SET NULL, so every order they were carrying simply lost its
-- driver — no status change, no reassignment, no notification, nothing on any
-- screen to say it had happened. An order mid-delivery would just sit there
-- belonging to nobody.
--
-- Now their active orders move to another driver covering the same area, and
-- anything nobody covers is flagged and reported so a manager can place it.

-- ── successor picker ────────────────────────────────────────────────────
-- Same ranking as pick_fair_driver_for_region (0024) — fewest active orders,
-- then name — with the departing driver excluded.
--
-- A new name rather than a defaulted extra parameter on the existing
-- function: CREATE OR REPLACE with a changed argument list creates a second
-- overload instead of replacing, which this codebase has already been caught
-- by twice (0014's create_order_internal, and the note in 0029 about
-- can_read_order_channel).
create or replace function public.pick_fair_driver_for_region_excluding(
  p_region_id uuid,
  p_exclude_driver_id uuid
)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select p.id
  from public.profiles p
  where p.role = 'driver'
    and p.is_active
    and p_region_id is not null
    and (p_exclude_driver_id is null or p.id <> p_exclude_driver_id)
    and exists (
      select 1 from public.driver_regions dr
      where dr.driver_id = p.id and dr.region_id = p_region_id
    )
  order by (
    select count(*) from public.orders o
    where o.assigned_driver_id = p.id
      and o.status not in ('delivered', 'cancelled', 'refused')
  ) asc, p.full_name asc
  limit 1;
$$;

-- ── move a departing driver's work ──────────────────────────────────────
-- Returns a row per order it touched so the caller can tell the manager what
-- actually happened, synchronously, instead of leaving them to discover it.
create or replace function public.reassign_orders_from_driver(p_driver_id uuid)
returns table (
  order_id uuid,
  order_number text,
  order_status public.order_status,
  new_driver_id uuid,
  new_driver_name text,
  outcome text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_driver public.profiles;
  v_fallback_regions uuid[];
  v_order record;
  v_successor uuid;
  v_region uuid;
  v_unallocated_ids uuid[] := array[]::uuid[];
  v_unallocated_numbers text[] := array[]::text[];
  v_idx integer;
begin
  if not public.is_owner() then
    raise exception 'حذف المندوب من صلاحية المدير فقط' using errcode = '42501';
  end if;

  select * into v_driver from public.profiles where id = p_driver_id;
  if v_driver is null then raise exception 'المندوب غير موجود'; end if;
  if v_driver.role <> 'driver' then raise exception 'هذا الحساب ليس مندوبًا'; end if;

  -- FIRST, before anything else touches this driver: snapshot the areas they
  -- cover. driver_regions is ON DELETE CASCADE, so the moment the profile row
  -- goes those rows are gone and there is no way to recover what this driver
  -- covered. It's also the only sensible basis for placing an order whose own
  -- region_id is null (nullable since 0004).
  v_fallback_regions := array(
    select dr.region_id from public.driver_regions dr where dr.driver_id = p_driver_id
  );

  for v_order in
    select o.id, o.order_number, o.status, o.region_id
    from public.orders o
    where o.assigned_driver_id = p_driver_id
      and o.status not in ('delivered', 'cancelled', 'refused')
    order by o.id
    for update
  loop
    -- The order's own area first, then anywhere the departing driver covered.
    v_successor := public.pick_fair_driver_for_region_excluding(v_order.region_id, p_driver_id);

    if v_successor is null then
      foreach v_region in array coalesce(v_fallback_regions, array[]::uuid[]) loop
        v_successor := public.pick_fair_driver_for_region_excluding(v_region, p_driver_id);
        exit when v_successor is not null;
      end loop;
    end if;

    order_id := v_order.id;
    order_number := v_order.order_number;
    order_status := v_order.status;

    if v_successor is null then
      update public.orders
         set assigned_driver_id = null,
             needs_allocation_at = now(),
             needs_allocation_reason = 'تم حذف المندوب ولا يوجد مندوب بديل يغطي المنطقة'
       where id = v_order.id;

      perform public.log_order_event(v_order.id, 'driver_unassigned', v_order.status, v_order.status,
        'تم حذف المندوب ولا يوجد بديل يغطي المنطقة — الأوردر بحاجة لتعيين مندوب');

      v_unallocated_ids := v_unallocated_ids || v_order.id;
      v_unallocated_numbers := v_unallocated_numbers || v_order.order_number;
      new_driver_id := null;
      new_driver_name := null;
      outcome := 'unallocated';

    elsif v_order.status = 'new' then
      -- Still waiting for approval, so the driver was only ever a suggestion
      -- and the order was never visible to them (orders_select_driver
      -- requires distribution_approved_at). Re-suggest and leave it pending:
      -- promoting it here would hand an order to a driver no manager ever
      -- confirmed, which is exactly what the approval step exists to prevent.
      update public.orders
         set assigned_driver_id = v_successor,
             suggested_driver_id = v_successor
       where id = v_order.id;

      perform public.log_order_event(v_order.id, 'distribution_set', v_order.status, v_order.status,
        'تم اقتراح مندوب بديل بعد حذف المندوب السابق (بانتظار اعتماد المدير)');

      new_driver_id := v_successor;
      select full_name into new_driver_name from public.profiles where id = v_successor;
      outcome := 'resuggested';

    else
      -- Already approved and in motion: hand it over as a real reassignment,
      -- leaving status and the original approval timestamp untouched.
      update public.orders set assigned_driver_id = v_successor where id = v_order.id;

      select full_name into new_driver_name from public.profiles where id = v_successor;

      perform public.log_order_event(v_order.id, 'driver_reassigned', v_order.status, v_order.status,
        'تم نقل الأوردر إلى ' || coalesce(new_driver_name, 'مندوب آخر') || ' بعد حذف المندوب السابق');

      perform public.notify_user(v_successor, v_order.id, 'order_assigned',
        'تم نقل أوردر إليك ' || v_order.order_number,
        'بعد حذف المندوب السابق');

      new_driver_id := v_successor;
      outcome := 'reassigned';
    end if;

    return next;
  end loop;

  -- Tell the other managers about anything left unplaced. Deliberately
  -- driven by the ids collected in the loop above rather than by re-querying
  -- for flagged orders: orders flagged by an earlier removal and still
  -- unplaced would otherwise be re-announced every time any driver is
  -- deleted, training everyone to ignore the alert.
  --
  -- Per order so the notification opens the right one — unless there are a
  -- lot, in which case one summary is more use than forty separate alerts
  -- (notifications.order_id is nullable and the bell already handles that).
  --
  -- notify_staff excludes the actor, which is right here: the manager doing
  -- the deletion is told synchronously by the action's own summary.
  if array_length(v_unallocated_ids, 1) between 1 and 10 then
    for v_idx in 1 .. array_length(v_unallocated_ids, 1) loop
      perform public.notify_staff(v_unallocated_ids[v_idx], 'needs_allocation',
        'الأوردر ' || v_unallocated_numbers[v_idx] || ' يحتاج تعيين مندوب',
        'تم حذف المندوب ولا يوجد بديل يغطي المنطقة', auth.uid());
    end loop;
  elsif coalesce(array_length(v_unallocated_ids, 1), 0) > 10 then
    perform public.notify_staff(null, 'needs_allocation',
      array_length(v_unallocated_ids, 1) || ' أوردر بحاجة لتعيين مندوب',
      'تم حذف مندوب ولا يوجد بديل يغطي مناطقه', auth.uid());
  end if;
end;
$$;

revoke all on function public.pick_fair_driver_for_region_excluding(uuid, uuid) from public, anon;
revoke all on function public.reassign_orders_from_driver(uuid) from public, anon;
grant execute on function public.reassign_orders_from_driver(uuid) to authenticated;


-- ========== supabase/migrations/0037_edit_driver_details.sql ==========

-- 0037_edit_driver_details.sql
--
-- A driver's name could not be corrected anywhere in the app — it was set
-- once at account creation and that was that, so a typo stayed on every order
-- they ever handled. This adds an edit path for it, and narrows who may edit
-- a driver's details to managers only.
--
-- Phone is deliberately NOT editable here. It is the login identity, so
-- changing it changes how someone signs in and needs the auth side kept in
-- step — out of scope for this change rather than half-done.

-- ── edit a worker's name ────────────────────────────────────────────────
-- The name is stamped onto orders at assignment time (migration 0032) so it
-- survives the account being deleted. That snapshot is what every order list
-- and report reads, so correcting the name without touching those rows would
-- fix it in one place and leave it wrong everywhere it's actually read.
-- Backfilling is therefore unconditional: a corrected name is corrected
-- everywhere, which is what "fix the name" means to the person asking.
create or replace function public.update_staff_profile(p_user_id uuid, p_full_name text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target public.profiles;
  v_name text := trim(coalesce(p_full_name, ''));
begin
  if not public.is_owner() then
    raise exception 'تعديل بيانات الموظفين من صلاحية المدير فقط' using errcode = '42501';
  end if;
  if length(v_name) < 2 then
    raise exception 'الاسم قصير جدًا' using errcode = '22023';
  end if;
  if length(v_name) > 120 then
    raise exception 'الاسم طويل جدًا' using errcode = '22023';
  end if;

  select * into v_target from public.profiles where id = p_user_id;
  if v_target is null then raise exception 'الحساب غير موجود'; end if;

  update public.profiles set full_name = v_name where id = p_user_id;

  -- Keep the order snapshots in step. Scoped to this person's own rows, and
  -- only where the name actually differs, so it writes nothing when a manager
  -- opens the dialog and saves without changing anything.
  update public.orders
     set assigned_driver_name = v_name
   where assigned_driver_id = p_user_id
     and assigned_driver_name is distinct from v_name;
end;
$$;

-- ── coverage editing becomes manager-only ───────────────────────────────
-- 0025 deliberately left this at Manager-or-Moderator while assignment and
-- account creation were narrowed to Manager in 0024. That split is being
-- closed on purpose: coverage decides which driver gets auto-suggested for an
-- area, so it is an assignment decision in everything but name, and it now
-- sits with the same role that approves assignments. Body is otherwise
-- unchanged from 0025.
create or replace function public.set_driver_regions_by_name(p_driver_id uuid, p_region_names text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
  v_id uuid;
  v_ids uuid[] := '{}';
begin
  if not public.is_owner() then
    raise exception 'تعديل مناطق المندوب من صلاحية المدير فقط' using errcode = '42501';
  end if;

  if not exists (select 1 from public.profiles where id = p_driver_id and role = 'driver') then
    raise exception 'هذا الحساب ليس مندوبًا';
  end if;

  foreach v_name in array coalesce(p_region_names, '{}'::text[])
  loop
    if length(trim(coalesce(v_name, ''))) > 0 then
      v_id := public.find_or_create_region(v_name);
      if not (v_id = any(v_ids)) then
        v_ids := array_append(v_ids, v_id);
      end if;
    end if;
  end loop;

  delete from public.driver_regions where driver_id = p_driver_id;

  if array_length(v_ids, 1) > 0 then
    insert into public.driver_regions (driver_id, region_id)
    select p_driver_id, x from unnest(v_ids) as x;
  end if;
end;
$$;

revoke all on function public.update_staff_profile(uuid, text) from public, anon;
grant execute on function public.update_staff_profile(uuid, text) to authenticated;


-- ========== supabase/migrations/0038_retire_factory_role.sql ==========

-- 0038_retire_factory_role.sql
--
-- The last step of removing factory accounts: drops everything that only
-- existed to serve them, and closes the transitional allowances the earlier
-- migrations carried so they'd be correct for both the old and new builds.
--
-- RUN THIS LAST, and only once all of the following are true:
--   1. migrations 0033-0037 have been applied
--   2. the app build without /factory is live
--   3. `delete from public.profiles where role = 'factory';` has been run
--
-- The guard below enforces (3) rather than trusting it: dropping the factory
-- RLS policies while a factory account still exists would leave that account
-- signed in with no policy governing what it can read.

do $$
declare
  v_remaining integer;
begin
  select count(*) into v_remaining from public.profiles where role = 'factory';
  if v_remaining > 0 then
    raise exception
      'ABORT: % factory account(s) still exist. Delete them first '
      '(delete from public.profiles where role = ''factory'';) and make sure the '
      'app build without /factory is live. Nothing has been changed.', v_remaining;
  end if;
end $$;

-- ── the factory dashboard's view ────────────────────────────────────────
-- Only ever read by the factory screens, which no longer exist.
drop view if exists public.factory_orders_view;

-- ── factory RLS policies ────────────────────────────────────────────────
-- No account can hold this role any more, so these can never match.
drop policy if exists orders_select_factory on public.orders;
drop policy if exists order_history_select_factory on public.order_history;

-- This one let an assigned driver read the factory's address off its profile
-- row. Drivers now read that from public.factories, which has its own policy
-- (migration 0033), so this is obsolete rather than merely dormant.
drop policy if exists profiles_select_factory_for_assigned_driver on public.profiles;

-- ── a Moderator's editable rows ─────────────────────────────────────────
-- Was role in ('driver','factory'); with factory accounts gone it is drivers.
drop policy if exists profiles_update_moderator on public.profiles;
create policy profiles_update_moderator on public.profiles
  for update using (public.current_user_role() = 'moderator' and role = 'driver')
  with check (public.current_user_role() = 'moderator' and role = 'driver');

-- ── close the transitional allowances ───────────────────────────────────
-- 0034 let a factory account keep pressing these so it wouldn't break between
-- that migration and the deploy that removed its screens. That window is
-- closed. Bodies are otherwise identical to 0034.
create or replace function public.factory_confirm_receipt(p_order_id uuid)
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

  if not (
    coalesce(public.is_owner_or_moderator(), false)
    or (public.current_user_role() = 'driver' and v_order.assigned_driver_id = auth.uid())
  ) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  if v_order.status <> 'collected' then raise exception 'الأوردر ليس بحالة تسمح بتأكيد الاستلام في المصنع'; end if;

  update public.orders
     set status = 'at_factory',
         factory_received_at = now(),
         handed_to_factory_at = coalesce(handed_to_factory_at, now())
   where id = p_order_id;

  perform public.log_order_event(p_order_id, 'factory_confirmed_receipt', 'collected', 'at_factory',
    'تم تسليم الأوردر للمصنع');

  if v_order.assigned_driver_id is not null and v_order.assigned_driver_id is distinct from auth.uid() then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'factory_received',
      'تم استلام الأوردر ' || v_order.order_number || ' في المصنع', null);
  end if;

  perform public.notify_staff(p_order_id, 'factory_received',
    'تم تسليم الأوردر ' || v_order.order_number || ' للمصنع', null, auth.uid());
end;
$$;

create or replace function public.factory_mark_ready(p_order_id uuid)
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

  if not (
    coalesce(public.is_owner_or_moderator(), false)
    or (public.current_user_role() = 'driver' and v_order.assigned_driver_id = auth.uid())
  ) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  if v_order.status <> 'at_factory' then raise exception 'الأوردر ليس داخل المصنع حاليًا'; end if;

  update public.orders set status = 'ready', factory_ready_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'factory_marked_ready', 'at_factory', 'ready',
    'المصنع أنهى العمل والأوردر جاهز للاستلام');

  if v_order.assigned_driver_id is not null and v_order.assigned_driver_id is distinct from auth.uid() then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'ready_for_pickup',
      'أوردر ' || v_order.order_number || ' جاهز للتسليم', 'يمكنك استلامه من المصنع الآن');
  end if;

  perform public.notify_staff(p_order_id, 'ready_for_pickup',
    'الأوردر ' || v_order.order_number || ' جاهز للاستلام من المصنع', null, auth.uid());
end;
$$;

-- The factory branch here can never be true again (nothing can be an
-- assigned_factory_id and a profile id at once now that factories are their
-- own table). Same signature, so this is a plain replace.
create or replace function public.can_read_order_channel(
  p_order_id uuid,
  p_channel text,
  p_user_id uuid,
  p_message_driver_id uuid default null
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.orders o
    where o.id = p_order_id
      and p_channel = 'driver'
      and o.assigned_driver_id = p_user_id
      and p_message_driver_id = p_user_id
  );
$$;

-- ── make the role unreachable for new accounts ──────────────────────────
-- Postgres has no ALTER TYPE ... DROP VALUE, and the value must stay anyway:
-- order_history.actor_role and order_messages.sender_role still hold it for
-- work done while factories were accounts, and those records have to keep
-- rendering. This constraint makes it impossible to create another one by
-- accident, which is the part that actually matters.
alter table public.profiles drop constraint if exists profiles_role_not_factory;
alter table public.profiles add constraint profiles_role_not_factory check (role <> 'factory');

comment on type public.user_role is
  'factory is retained for historical rows only (order_history.actor_role, '
  'order_messages.sender_role) — factories became a table of their own in '
  'migration 0033 and no profile may use this value; see the '
  'profiles_role_not_factory constraint.';


-- ========== supabase/migrations/0039_report_performance.sql ===========

-- 0039_report_performance.sql
--
-- Pure performance migration. No new columns, no new permissions, no
-- behavior change: monthly_report returns exactly the same row for the same
-- input as the version it replaces (verified by diffing both versions'
-- output over seven months of seeded data, including empty months so the
-- NULL branches were exercised). It is safe to apply before or after the
-- matching app deploy, because the app does not change at all.
--
-- Scope note: an earlier draft of this migration also replaced
-- is_order_delayed(o public.orders) with a scalar (status, created_at)
-- overload, on the theory that a composite-argument SQL function can't be
-- inlined and therefore blocks index use. That was measured against
-- Postgres 16 and is simply false — the planner inlines the row-typed form
-- too, producing a byte-identical plan (same Bitmap Index Scan, same
-- Recheck Cond with the function expanded away). The overload was dropped
-- from this migration rather than shipped on a rationale that doesn't hold.
-- What actually made "which orders are late" an index scan is the partial
-- index below, nothing else.

-- ── indexes ─────────────────────────────────────────────────────────────

-- Open (non-terminal) orders only. Delivered/cancelled/refused orders are
-- the ones that accumulate forever and can never be late, so keeping them
-- out means this index stays roughly the size of the active workload no
-- matter how long the business runs.
--
-- This is the one with the large measured effect. Benchmarked on a seeded
-- 60,400-order table with 220 still open, delayed_orders_report's predicate
-- went from a sequential scan reading all 60,400 rows to a bitmap index
-- scan reading 217 (18 heap blocks). The gap widens over time, because the
-- rows this index deliberately never stores are exactly the ones that
-- accumulate forever.
create index if not exists orders_open_created_at_idx
  on public.orders (created_at)
  where status not in ('delivered', 'cancelled', 'refused');

-- The driver app's list is "my orders, newest first". This index does
-- nothing on its own — measured, the planner reads the same 1,334 rows and
-- sorts them either way — and only pays off once the query is also bounded,
-- which is the matching app change (listMyDriverOrders gained a .limit()).
-- With both: 1,334 rows plus a top-N sort becomes an ordered index scan of
-- exactly the 100 rows asked for. Neither half is worth much alone, which
-- is why they ship together.
create index if not exists orders_driver_created_at_idx
  on public.orders (assigned_driver_id, created_at desc);

-- Same shape for the staff order list. Honest scope: this is the smallest
-- of the three. For a common status the planner already did well off
-- orders_created_at_idx (25 rows read, no help needed); this one earns its
-- place on *narrow* statuses, where it removes the sort, and on a status
-- filter combined with a date range.
create index if not exists orders_status_created_at_idx
  on public.orders (status, created_at desc);

-- The two single-column indexes are now redundant: an index on (a, b)
-- serves every lookup an index on (a) served, because a is the leading
-- column. Keeping both would mean every order INSERT and every lifecycle
-- UPDATE maintains four index entries where two will do — and orders are
-- updated several times each as they move through the workflow, so this is
-- write cost on the hottest path in the system.
drop index if exists public.orders_driver_idx;
drop index if exists public.orders_status_idx;

-- ── monthly_report: eight scans of `orders` collapsed into one ──────────
--
-- The previous version counted two totals into variables and then ran six
-- more independent subqueries inside the RETURN, every one of them walking
-- the same rows of `orders` over again to produce a single output row.
-- Measured on the seeded data: 23 scans of `orders` for one call, down to 2.
--
-- This version reads the two months once — as a single range the created_at
-- index can serve — and splits current from previous with FILTER clauses.
-- v_prev_end was always exactly v_start, so "created_at < v_start" inside
-- the scanned range is precisely the previous month; no row can fall in
-- both halves or in neither.
--
-- Return values are unchanged, including every NULL case: avg over no
-- delivered orders is still NULL, on_time_rate over no delivered orders is
-- still NULL via nullif, and orders_change_percent is still NULL when the
-- previous month was empty.
create or replace function public.monthly_report(p_month date default current_date)
returns table (
  total_orders bigint,
  total_pieces bigint,
  completed_orders bigint,
  delayed_orders bigint,
  avg_completion_hours numeric,
  on_time_rate numeric,
  prev_total_orders bigint,
  prev_completed_orders bigint,
  orders_change_percent numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_end date := (date_trunc('month', p_month) + interval '1 month')::date;
  v_prev_start date := (date_trunc('month', p_month) - interval '1 month')::date;
  v_sla interval := (public.order_sla_hours() || ' hours')::interval;
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    with agg as (
      select
        count(*) filter (where o.created_at >= v_start) as cur_total,
        coalesce(sum(o.pieces_count) filter (where o.created_at >= v_start), 0) as cur_pieces,
        count(*) filter (where o.created_at >= v_start and o.status = 'delivered') as cur_delivered,
        count(*) filter (
          where o.created_at >= v_start and public.is_order_delayed(o.*)
        ) as cur_delayed,
        round(
          avg(extract(epoch from (o.delivered_at - o.created_at)) / 3600.0)
            filter (where o.created_at >= v_start and o.status = 'delivered'),
          1
        ) as cur_avg_hours,
        count(*) filter (
          where o.created_at >= v_start
            and o.status = 'delivered'
            and o.delivered_at <= o.created_at + v_sla
        ) as cur_on_time,
        count(*) filter (where o.created_at < v_start) as prev_total,
        count(*) filter (where o.created_at < v_start and o.status = 'delivered') as prev_delivered
      from public.orders o
      where o.created_at >= v_prev_start
        and o.created_at < v_end
    )
    select
      agg.cur_total,
      agg.cur_pieces,
      agg.cur_delivered,
      agg.cur_delayed,
      agg.cur_avg_hours,
      round(100.0 * agg.cur_on_time / nullif(agg.cur_delivered, 0), 1),
      agg.prev_total,
      agg.prev_delivered,
      case
        when agg.prev_total = 0 then null
        else round(100.0 * (agg.cur_total - agg.prev_total) / agg.prev_total, 1)
      end
    from agg;
end;
$$;

-- CREATE OR REPLACE preserves existing grants, but these are re-stated so a
-- database freshly built from this chain ends up identical to an upgraded one.
revoke all on function public.monthly_report(date) from public;
grant execute on function public.monthly_report(date) to authenticated;


-- ========== supabase/migrations/0040_push_subscriptions_and_manager_factories.sql 

-- 0040_push_subscriptions_and_manager_factories.sql
--
-- Groundwork for phone push notifications. Two new tables, their RLS, and
-- the RPCs that write them. Nothing in this migration sends anything or
-- changes any existing behavior — the dispatch trigger is 0041, and the app
-- ignores both tables until it is deployed. Safe to apply at any time.
--
-- Push here is the browser's own Web Push (the W3C standard, VAPID keys),
-- not Firebase. On the web, Firebase Cloud Messaging is a wrapper around
-- this same API — same browsers, same permission prompt, same iOS
-- restriction — so going direct costs nothing in reach and keeps device
-- endpoints in this database rather than a third party's.

-- ── who a manager covers ────────────────────────────────────────────────
--
-- Until now nothing linked a person to a factory. Orders have
-- assigned_factory_id; managers had no factory of their own, and
-- notify_staff/notify_role fan out to every active manager unconditionally.
--
-- This table does NOT change that. Managers still see every order and still
-- get every in-app notification — that was a deliberate product decision
-- and it stands. This is narrower: it decides whose *phone* rings for a
-- chat message. The bell stays the complete record; the push is only for
-- work that is yours.
--
-- A manager may cover several factories, and a factory may be covered by
-- several managers, hence a join table rather than a column on profiles.
create table if not exists public.manager_factories (
  manager_id uuid not null references public.profiles (id) on delete cascade,
  factory_id uuid not null references public.factories (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (manager_id, factory_id)
);

-- The lookup this exists for runs in the other direction — "given this
-- order's factory, whose phone rings" — and the primary key's leading
-- column is manager_id, so it cannot serve that.
create index if not exists manager_factories_factory_idx
  on public.manager_factories (factory_id);

alter table public.manager_factories enable row level security;

-- Readable by any signed-in staff member: the Team page shows each
-- manager's coverage the same way it shows a driver's regions, and there is
-- nothing sensitive in "which workshop does this person watch".
drop policy if exists manager_factories_select on public.manager_factories;
create policy manager_factories_select on public.manager_factories
  for select to authenticated using (public.is_owner_or_moderator());

-- No insert/update/delete policy on purpose. Writes go through
-- set_manager_factories() below, which is security definer and carries the
-- owner-only check. A table with no write policy fails closed.

grant select on public.manager_factories to authenticated;

-- ── a device that agreed to be notified ─────────────────────────────────
--
-- One row per browser-on-one-device that has granted permission. A person
-- can have several (phone and laptop), and the same phone reinstalling the
-- app produces a new endpoint rather than reusing the old one, which is why
-- endpoint — not user_id — is the unique key.
--
-- p256dh and auth are the subscription's own encryption keys, handed over
-- by the browser. They are useless without the matching VAPID private key,
-- which lives in the server environment and never in this database.
create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  -- The push service URL the browser gave us. Unique because re-subscribing
  -- on the same device returns the same endpoint, and inserting a second
  -- row for it would mean sending every notification twice.
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  -- Purely for the "which of my devices is this?" list and for support
  -- questions ("it works on my phone but not the tablet").
  user_agent text,
  created_at timestamptz not null default now(),
  last_success_at timestamptz,
  -- Push services return 404/410 for an endpoint that is gone for good
  -- (app uninstalled, permission revoked). The dispatcher deletes those
  -- outright; this counts the soft failures, so a persistently broken
  -- endpoint can be spotted rather than retried forever.
  failure_count integer not null default 0
);

create index if not exists push_subscriptions_user_idx
  on public.push_subscriptions (user_id);

alter table public.push_subscriptions enable row level security;

-- Strictly your own devices. Nobody reads anyone else's endpoint through
-- the API — the dispatcher reads them server-side with the service role,
-- which is the only context that ever needs to see another person's.
drop policy if exists push_subscriptions_select_own on public.push_subscriptions;
create policy push_subscriptions_select_own on public.push_subscriptions
  for select to authenticated using (user_id = auth.uid());

drop policy if exists push_subscriptions_delete_own on public.push_subscriptions;
create policy push_subscriptions_delete_own on public.push_subscriptions
  for delete to authenticated using (user_id = auth.uid());

grant select, delete on public.push_subscriptions to authenticated;

-- ── register / forget a device ──────────────────────────────────────────
--
-- Inserts go through this rather than a policy so user_id is taken from
-- auth.uid() and cannot be supplied by the caller — no client can register
-- a device against someone else's account and start receiving their
-- notifications.
--
-- Re-registering the same endpoint updates it in place (the browser can
-- rotate the keys on an existing endpoint), and re-points it at the current
-- user: a shared device where one driver signs out and another signs in
-- must ring for whoever is actually signed in now, not the previous person.
create or replace function public.save_push_subscription(
  p_endpoint text,
  p_p256dh text,
  p_auth text,
  p_user_agent text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if coalesce(trim(p_endpoint), '') = ''
     or coalesce(trim(p_p256dh), '') = ''
     or coalesce(trim(p_auth), '') = '' then
    raise exception 'بيانات الاشتراك غير مكتملة' using errcode = '22023';
  end if;
  -- A push endpoint is a URL from the browser vendor's push service. Bound
  -- so a client can't park arbitrary amounts of data in this table.
  if length(p_endpoint) > 2000 or length(p_p256dh) > 500 or length(p_auth) > 500 then
    raise exception 'بيانات الاشتراك غير صالحة' using errcode = '22023';
  end if;

  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth, user_agent)
  values (v_uid, p_endpoint, p_p256dh, p_auth, left(p_user_agent, 400))
  on conflict (endpoint) do update
    set user_id = excluded.user_id,
        p256dh = excluded.p256dh,
        auth = excluded.auth,
        user_agent = excluded.user_agent,
        failure_count = 0;
end;
$$;

-- Turning notifications off. Scoped to the caller's own rows on top of the
-- delete policy — belt and braces, because this one is easy to get wrong
-- and the failure mode is silently unsubscribing someone else's phone.
create or replace function public.delete_push_subscription(p_endpoint text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  delete from public.push_subscriptions
   where endpoint = p_endpoint and user_id = v_uid;
end;
$$;

-- ── set a manager's factories ───────────────────────────────────────────
--
-- Owner-only, matching update_staff_profile and set_driver_regions_by_name
-- (0037): deciding who is accountable for a workshop is a management
-- decision, not a moderator one.
--
-- Replaces the whole set rather than adding one at a time, so the UI can
-- send what the checkboxes currently say without having to diff.
create or replace function public.set_manager_factories(
  p_manager_id uuid,
  p_factory_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target public.profiles;
  v_ids uuid[] := coalesce(p_factory_ids, '{}');
  v_unknown integer;
begin
  if not public.is_owner() then
    raise exception 'تعديل تغطية المديرين من صلاحية المدير فقط' using errcode = '42501';
  end if;

  select * into v_target from public.profiles where id = p_manager_id;
  if v_target is null then
    raise exception 'الحساب غير موجود';
  end if;
  -- Drivers are covered by regions, not factories. Allowing a driver row
  -- here would create coverage that nothing reads and that looks, in the
  -- database, exactly like a real assignment.
  if v_target.role not in ('owner', 'moderator') then
    raise exception 'التغطية بالمصانع للمديرين فقط';
  end if;

  -- Fail loudly on an id that isn't a factory rather than silently storing
  -- fewer rows than the caller asked for.
  --
  -- The alias here is load-bearing. Written as `unnest(v_ids) as id`, the
  -- `id` inside the subquery binds to factories.id — the inner scope wins —
  -- so the test reads `f.id = f.id`, is true for every row, and the check
  -- silently never fires. It was written that way first; the foreign key
  -- still refused the bad row, so the data stayed correct, but the caller
  -- got a raw constraint violation instead of this message. Naming the
  -- column t(fid) makes the reference unambiguous.
  select count(*) into v_unknown
    from unnest(v_ids) as t(fid)
   where not exists (select 1 from public.factories f where f.id = t.fid);
  if v_unknown > 0 then
    raise exception 'مصنع غير معروف ضمن المحدد';
  end if;

  delete from public.manager_factories
   where manager_id = p_manager_id
     and not (factory_id = any (v_ids));

  insert into public.manager_factories (manager_id, factory_id)
  select p_manager_id, t.fid from unnest(v_ids) as t(fid)
  on conflict do nothing;
end;
$$;

-- ── bookkeeping for devices that didn't answer ──────────────────────────
--
-- Called only by the dispatcher (service role), which is why there is no
-- grant to `authenticated`: nothing a browser does should be able to mark
-- anyone's device as failing. Kept as an RPC rather than a client-side loop
-- so a batch of failures is one round trip instead of one per device.
--
-- Endpoints the push service says are gone for good are deleted outright by
-- the dispatcher; this counts only the soft failures — offline, timed out,
-- push service having a bad day — so a device that is permanently broken can
-- be told apart from one whose owner is on the metro.
create or replace function public.increment_push_failures(p_ids uuid[])
returns void
language sql
security definer
set search_path = public
as $$
  update public.push_subscriptions
     set failure_count = failure_count + 1
   where id = any (coalesce(p_ids, '{}'));
$$;

revoke all on function public.increment_push_failures(uuid[]) from public;

revoke all on function public.save_push_subscription(text, text, text, text) from public;
revoke all on function public.delete_push_subscription(text) from public;
revoke all on function public.set_manager_factories(uuid, uuid[]) from public;

grant execute on function public.save_push_subscription(text, text, text, text) to authenticated;
grant execute on function public.delete_push_subscription(text) to authenticated;
grant execute on function public.set_manager_factories(uuid, uuid[]) to authenticated;


-- ========== neon/migrations/0041_push_dispatch_trigger.neon.sql =======

-- neon/migrations/0041_push_dispatch_trigger.neon.sql
--
-- A byte-for-byte copy of supabase/migrations/0041_push_dispatch_trigger.sql
-- with EXACTLY ONE line changed: the `create extension pg_net` at the top is
-- commented out. Nothing else differs — diff the two files and you should see
-- that one hunk and nothing more.
--
-- WHY A COPY RATHER THAN AN EDIT TO THE ORIGINAL
--
-- supabase/migrations/ stays the single source of truth for both databases,
-- so a migration written next month does not have to be written twice and
-- cannot drift between them. 0000_prelude.sql absorbs every other
-- Supabase-ism by providing a stand-in — the auth schema, the PostgREST
-- roles, and a net.http_post() with pg_net's exact signature that queues to
-- public.push_outbox instead of opening a socket. `create extension`,
-- though, cannot be faked: Postgres looks for a control file on the server's
-- filesystem, which a managed host does not let you put there, so the
-- statement fails with `extension "pg_net" is not available` no matter what
-- else exists. This one file is the whole cost of that.
--
-- Apply this INSTEAD OF the original, in the same position in the order.
-- Everything it defines that matters on Neon — should_push_notification()
-- and the trigger — is unchanged. The dispatch function defined further down
-- is the pg_net version, and it is replaced wholesale by migration 0042
-- immediately afterwards, which is why removing the extension changes no
-- behaviour: the only body that survives the chain reads its endpoint from
-- public.app_settings and calls net.http_post(), which on this database is
-- the outbox writer.

-- 0041_push_dispatch_trigger.sql
--
-- Turns an in-app notification into a phone notification.
--
-- Why a trigger on `notifications` rather than a call inside each RPC:
-- every notification in this system already funnels through notify_user(),
-- which is a plain insert into this one table. Hooking the table catches
-- every path at once — single approval, bulk approval, reassignment, and
-- the cascade when a driver is deleted — without touching any workflow RPC
-- and without a second copy of the fan-out rules that could drift from the
-- first. Adding push to a new event later means picking a type string, not
-- editing another function.
--
-- This migration is inert until configured. It reads the endpoint URL and
-- shared secret from database settings that are deliberately NOT in this
-- file (see the bottom) — with either missing, the trigger returns quietly
-- and the app behaves exactly as it does today. Applying it before the
-- deploy is safe.

-- pg_net gives Postgres an async HTTP client. The call queues a request and
-- returns immediately, so the notification insert never waits on the
-- network, and the queue is transactional — a rolled-back transaction takes
-- its queued push with it rather than announcing something that never
-- happened.
-- No `with schema` clause: pg_net is not relocatable — it always installs
-- into its own `net` schema, and naming a different one is an error rather
-- than a preference.
-- create extension if not exists pg_net;  -- see the header: not available on Neon;
-- 0000_prelude.sql provides net.http_post() with the same signature instead.

-- ── who should this one ring? ───────────────────────────────────────────
--
-- Kept as its own function rather than inlined into the trigger so the rule
-- can be read, tested, and changed on its own. Returns true if this
-- specific notification row should become a push.
create or replace function public.should_push_notification(n public.notifications)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role public.user_role;
  v_factory uuid;
begin
  select role into v_role from public.profiles
   where id = n.user_id and is_active;
  -- Deactivated, or the account is gone: nothing to ring.
  if v_role is null then return false; end if;

  -- An order landing in a driver's list is the one thing they must not miss
  -- — it is the whole reason they open the app. Always pushed, to the one
  -- driver it was addressed to.
  if n.type = 'order_assigned' then
    return true;
  end if;

  if n.type = 'chat_message' then
    -- The driver's side of the conversation. Pushing only the manager's
    -- side would make this half a feature: the manager's phone rings when
    -- the driver writes, and the driver never learns they were answered.
    if v_role = 'driver' then
      return true;
    end if;

    -- The manager's side, and the only place factory coverage is consulted
    -- anywhere in this system. Managers keep seeing every chat in the bell
    -- — that stays deliberately unscoped — but a phone only rings for a
    -- workshop that manager actually covers.
    --
    -- A manager with no factories assigned gets no chat pushes at all. That
    -- is the honest consequence of an empty assignment rather than a
    -- special case, and the Team page says so where the assignment is made.
    if v_role in ('owner', 'moderator') then
      if n.order_id is null then return false; end if;
      select assigned_factory_id into v_factory
        from public.orders where id = n.order_id;
      if v_factory is null then return false; end if;
      return exists (
        select 1 from public.manager_factories mf
         where mf.manager_id = n.user_id
           and mf.factory_id = v_factory
      );
    end if;

    return false;
  end if;

  -- Everything else — collected, delivered, refused, cancelled,
  -- needs_allocation and the rest — stays in-app only. They are a record to
  -- read when you next look, not a reason to buzz someone's pocket. Adding
  -- one is a matter of naming its type above.
  return false;
end;
$$;

-- ── the trigger ─────────────────────────────────────────────────────────
create or replace function public.dispatch_push_notification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text := nullif(current_setting('app.push_endpoint_url', true), '');
  v_secret text := nullif(current_setting('app.push_webhook_secret', true), '');
begin
  -- Not configured yet, or deliberately switched off by unsetting either
  -- value. No push, no error, no effect on the notification itself.
  if v_url is null or v_secret is null then
    return null;
  end if;

  if not public.should_push_notification(new) then
    return null;
  end if;

  -- Only the row id crosses the wire. The dispatcher reads the notification
  -- and the recipient's devices itself, so there is exactly one copy of the
  -- message text (the row already in this table) and the request body
  -- carries nothing worth intercepting on its own.
  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('notification_id', new.id),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-Push-Secret', v_secret
    ),
    timeout_milliseconds := 5000
  );

  return null;
exception when others then
  -- Push is best effort; the bell is the durable record. A broken endpoint,
  -- a missing extension, or a malformed setting must never stop an order
  -- being assigned or a message being sent — without this the whole
  -- workflow RPC would roll back on a networking problem.
  raise warning 'push dispatch skipped for notification %: %', new.id, sqlerrm;
  return null;
end;
$$;

drop trigger if exists dispatch_push_on_notification on public.notifications;
create trigger dispatch_push_on_notification
  after insert on public.notifications
  for each row execute function public.dispatch_push_notification();

revoke all on function public.should_push_notification(public.notifications) from public;
revoke all on function public.dispatch_push_notification() from public;

-- ── configuration, which is NOT in this file ────────────────────────────
--
-- Credentials do not belong in a git-tracked migration. Run these once, by
-- hand, against the live database, substituting your own values:
--
--   alter database postgres
--     set app.push_endpoint_url = 'https://<your-domain>/api/push/dispatch';
--   alter database postgres
--     set app.push_webhook_secret = '<the same value as PUSH_WEBHOOK_SECRET
--                                     in the app environment>';
--
-- They take effect on new connections, so give it a moment (or restart the
-- project) before testing. To switch push off entirely without reverting
-- anything:
--
--   alter database postgres reset app.push_webhook_secret;


-- ========== supabase/migrations/0042_push_settings_table.sql ==========

-- 0042_push_settings_table.sql
--
-- Fixes how 0041 stores its two configuration values.
--
-- 0041 read them from `current_setting('app.push_endpoint_url')`, to be set
-- once by hand with `alter database postgres set ...`. That does not work on
-- Supabase: setting a custom parameter at database level requires superuser,
-- and Supabase's `postgres` role is not one. The statement fails outright
-- with 42501, so the configuration step was impossible as written.
--
-- A table instead. It also travels: `alter database ... set` and Supabase
-- Vault are both tied to how a particular provider grants privileges,
-- whereas this is ordinary SQL that replays anywhere — which matters given
-- the Neon migration in `neon/`.

create table if not exists public.app_settings (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);

-- Belt and braces, in this order of strictness:
--
-- 1. No grants. PostgREST connects as `authenticator` and switches to
--    `anon`/`authenticated`; with no grant on this table, neither role can
--    reach it at all. This is the real boundary — not a policy that could be
--    loosened later by a broad `grant ... on all tables`.
-- 2. RLS on with no policy, so even if a grant were added by accident the
--    table still returns nothing and accepts nothing.
--
-- The trigger function reads it as its definer (the table owner), which is
-- not subject to RLS — deliberately not `force row level security`, since
-- that would lock the owner out too and break the very thing this exists for.
alter table public.app_settings enable row level security;

revoke all on public.app_settings from anon, authenticated;

comment on table public.app_settings is
  'Server-side configuration read only by security-definer functions. Never exposed to the API: no grants to anon/authenticated. Holds the push endpoint URL and webhook secret — see 0041/0042.';

-- ── the trigger, re-pointed at the table ────────────────────────────────
--
-- Identical to 0041 in every other respect: same filter, same payload, same
-- exception handling. Only the two lines that fetch the configuration change.
create or replace function public.dispatch_push_notification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_secret text;
begin
  select value into v_url from public.app_settings where key = 'push_endpoint_url';
  select value into v_secret from public.app_settings where key = 'push_webhook_secret';

  -- Not configured yet, or deliberately switched off by deleting either row.
  -- No push, no error, no effect on the notification itself.
  if coalesce(v_url, '') = '' or coalesce(v_secret, '') = '' then
    return null;
  end if;

  if not public.should_push_notification(new) then
    return null;
  end if;

  -- Only the row id crosses the wire. The dispatcher reads the notification
  -- and the recipient's devices itself, so there is exactly one copy of the
  -- message text (the row already in this table).
  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('notification_id', new.id),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-Push-Secret', v_secret
    ),
    timeout_milliseconds := 5000
  );

  return null;
exception when others then
  -- Push is best effort; the bell is the durable record. A broken endpoint,
  -- a missing extension, or a malformed setting must never stop an order
  -- being assigned or a message being sent.
  raise warning 'push dispatch skipped for notification %: %', new.id, sqlerrm;
  return null;
end;
$$;

revoke all on function public.dispatch_push_notification() from public;

-- ── configuration, which is NOT in this file ────────────────────────────
--
-- Credentials do not belong in a git-tracked migration. Run this once, by
-- hand, in the SQL editor, substituting your own values:
--
--   insert into public.app_settings (key, value) values
--     ('push_endpoint_url', 'https://<your-domain>/api/push/dispatch'),
--     ('push_webhook_secret', '<the same value as PUSH_WEBHOOK_SECRET in the
--                               app environment>')
--   on conflict (key) do update set value = excluded.value, updated_at = now();
--
-- Unlike the database-level parameter this replaces, it takes effect on the
-- very next notification — no waiting for connections to recycle.
--
-- To switch push off entirely without reverting anything:
--
--   delete from public.app_settings where key = 'push_webhook_secret';


-- ========== supabase/migrations/0043_moderator_notifications_delivered_only.sql 

-- 0043_moderator_notifications_delivered_only.sql
--
-- A Moderator's bell now carries one thing: an order was delivered.
--
-- Until now they received eleven types — collected, heading to factory, left
-- factory, factory received, ready for pickup, delivered, refused, cancelled,
-- driver reassigned, factory reassigned, and needs_allocation. All of it came
-- through notify_staff(), which fans out to every active owner and moderator
-- with no distinction between them, so this is one change rather than eleven
-- call sites edited.
--
-- Several of those were never actionable for a Moderator anyway:
-- needs_allocation asks someone to allocate an order, and allocation has been
-- Manager-only at the database level since 0035; driver_reassigned and
-- factory_reassigned report a decision only a Manager can make. They were
-- noise in the one place that is supposed to mean "something needs you".
--
-- Not affected: new_order and chat_message already went to owners only
-- (notify_role('owner')), and a Manager's bell is unchanged in every respect.

-- Which notification types reach a Moderator. A function rather than a
-- literal inside notify_staff so there is one obvious place to look, and one
-- line to change if another type ever earns a Moderator's attention.
create or replace function public.moderator_notification_types()
returns text[]
language sql
immutable
as $$ select array['order_delivered'] $$;

-- notify_staff, with the one added condition. Everything else — the active
-- check, the p_exclude that keeps the person who acted from being told about
-- their own action, the delegation to notify_user — is unchanged from 0019.
create or replace function public.notify_staff(
  p_order_id uuid,
  p_type text,
  p_title text,
  p_body text default null,
  p_exclude uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user record;
begin
  for v_user in
    select id from public.profiles
    where role in ('owner', 'moderator') and is_active
      and (p_exclude is null or id <> p_exclude)
      -- Managers get everything, as before. Moderators get only the types
      -- listed above. Written this way round on purpose: a new notification
      -- type added later reaches Managers automatically and Moderators only
      -- if someone deliberately adds it, which is the safer default for the
      -- role with the narrower job.
      and (role = 'owner' or p_type = any (public.moderator_notification_types()))
  loop
    perform public.notify_user(v_user.id, p_order_id, p_type, p_title, p_body);
  end loop;
end;
$$;

revoke all on function public.notify_staff(uuid, text, text, text, uuid) from public;
revoke all on function public.moderator_notification_types() from public;

-- ── the ones already sitting in their bells ─────────────────────────────
--
-- The change above stops new ones being written; it does nothing about what
-- is already there, and a Moderator opening the bell would still see months
-- of the types they are no longer meant to get.
--
-- Deleting is safe here specifically because notifications are not the
-- record. Every one of these events is written to order_history by
-- log_order_event() in the same transaction, and that is what the order
-- timeline and every report read. A notification is a nudge that something
-- happened; the history is the fact that it did. Nothing auditable is lost.
--
-- Scoped to moderators and to types that are no longer sent, so a Manager's
-- bell is untouched and a Moderator keeps every delivered notification they
-- already had.
delete from public.notifications n
 using public.profiles p
 where p.id = n.user_id
   and p.role = 'moderator'
   and not (n.type = any (public.moderator_notification_types()));
