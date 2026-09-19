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
