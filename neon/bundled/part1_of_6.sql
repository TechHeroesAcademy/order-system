-- ============================================================================
-- NEON SETUP — PART 1 OF 6
--
-- PASTE THIS WHOLE FILE INTO NEON'S SQL EDITOR AND RUN IT.
-- Run the parts in order. Wait for each to finish before starting the next.
-- Each part is safe to re-run: every statement is idempotent.
--
-- Start here. Creates the roles, schemas and tables the chain expects.
--
-- GENERATED — do not edit. Edit the source files listed below and re-run
-- scripts/build-neon-bundle.mjs, so Supabase and Neon cannot drift apart.
--
-- Contains, in order:
--    1. neon/migrations/0000_prelude.sql
--    2. supabase/migrations/0001_extensions_and_enums.sql
--    3. supabase/migrations/0002_profiles.sql
--    4. supabase/migrations/0003_regions_and_driver_regions.sql
--    5. supabase/migrations/0004_orders.sql
--    6. supabase/migrations/0005_order_history.sql
--    7. supabase/migrations/0006_notifications.sql
--    8. supabase/migrations/0007_order_creation.sql
--    9. supabase/migrations/0008_rls_policies.sql
--   10. supabase/migrations/0009_workflow_rpcs.sql
--   11. supabase/migrations/0010_reporting_and_views.sql
--   12. supabase/migrations/0011_table_grants.sql
--   13. supabase/migrations/0012_seed_egypt_regions.sql
--   14. supabase/migrations/0013_driver_reassignment_and_login.sql
--   15. supabase/migrations/0014_driver_approval_fix_and_factory_assignment.sql
--   16. supabase/migrations/0015_factory_location_and_handoff_tracking.sql
--   17. supabase/migrations/0016_mandatory_assignment_delivery_code_and_geo.sql
--   18. supabase/migrations/0017_track_order_setof_return.sql
--   19. supabase/migrations/0018_factory_reassignment_delivery_codes_and_chat.sql
-- ============================================================================

-- The chain installs pgcrypto/pg_trgm into the extensions schema (as Supabase
-- does) and several functions resolve against it. Declared per part rather
-- than relied on from the database default, so pasting a part into a fresh
-- editor session always works.
set search_path = public, extensions;



-- ========== neon/migrations/0000_prelude.sql ==========================

-- neon/migrations/0000_prelude.sql
--
-- Run this FIRST, before any of supabase/migrations/, on a bare Neon (or
-- other non-Supabase) Postgres database. Then the whole chain in
-- supabase/migrations/ replays unmodified, and 0001_auth_shim.sql cleans up
-- after it.
--
-- WHY THIS FILE HAS TO EXIST
--
-- neon/README.md used to say "apply every migration in supabase/migrations/
-- exactly as-is — that whole chain is portable". Measured against the real
-- chain (0001–0050) on a bare Postgres 16, it is not, in four specific
-- ways. Every one of them is something Supabase provides that Neon does
-- not, and every one of them aborts the replay rather than degrading:
--
--   1. The roles `anon`, `authenticated` and `service_role`. These are
--      PostgREST's roles, created by Supabase. The chain issues 90 `grant
--      ... to authenticated` and 10 `to anon` statements; the first one
--      fails with `role "authenticated" does not exist`.
--   2. The `extensions` schema. Supabase installs pgcrypto/pg_trgm there
--      and puts it on the database's search_path, and several functions in
--      the chain are declared `set search_path = public, extensions`.
--   3. `auth.users`, plus `auth.uid()`. One foreign key points at it
--      (`profiles.profiles_id_fkey`) and one trigger fires on it
--      (`on_auth_user_created`). The shim removes both afterwards, but they
--      have to be creatable for the chain to replay at all.
--   4. `pg_net`. Not available on Neon at all — confirmed against Neon's
--      extension list, where pg_net, pgsodium and http are all absent.
--      Migration 0041 does `create extension pg_net` and aborts.
--
-- The approach throughout is the same one that made the auth.uid() shim
-- work: keep the call sites and change what backs them. Nothing in
-- supabase/migrations/ is edited, so the chain stays a single source of
-- truth for both databases and a future migration does not have to be
-- written twice.
--
-- SAFETY: this file is for a bare Neon/Postgres database only. It is
-- harmless-looking but it creates a fake `net.http_post`, so the guard
-- below refuses to run against a real Supabase database, exactly as
-- 0001_auth_shim.sql does.

do $$
begin
  if exists (
    select 1 from pg_extension where extname = 'pg_net'
  ) or exists (
    select 1 from information_schema.columns
    where table_schema = 'auth' and table_name = 'users'
      and column_name in ('instance_id', 'encrypted_password', 'confirmation_token')
  ) then
    raise exception
      'Refusing to run: this looks like a real Supabase-managed database '
      '(pg_net is installed, or auth.users has Supabase-specific columns). '
      'This file creates a stand-in net.http_post and PostgREST-shaped '
      'roles, and is meant for a bare Neon/Postgres database only. '
      'Aborting.';
  end if;
end $$;

-- ── 1. the schemas the chain writes into ────────────────────────────────

create schema if not exists extensions;
create schema if not exists auth;
create schema if not exists net;

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;

-- PostGIS installs into public and brings ~590 C functions, the
-- spatial_ref_sys table and two views with it. It is needed only by
-- migration 0044 (region boundaries), which nothing in the application
-- references any more — the maps are drawn client-side with Leaflet, and
-- the boundary columns and region_for_point() are dead. Leave this
-- commented out and 0044 will fail; see step 2 of the runbook, which drops
-- 0044's objects on Supabase BEFORE the migration so the question does not
-- arise. Uncomment only if you decide to keep boundaries.
-- create extension if not exists postgis;

-- Supabase puts `extensions` on the database search_path; several functions
-- in the chain inherit that assumption via `set search_path = public,
-- extensions`. Harmless to mirror, and it keeps those functions resolving
-- the same way they do today.
do $$
begin
  execute format(
    'alter database %I set search_path = public, extensions',
    current_database()
  );
end $$;

-- And for THIS session as well, which the line above does not cover: ALTER
-- DATABASE sets a default that new connections pick up, so a run that
-- applies the prelude and the rest of the chain in one session never sees
-- it. Migration 0004 then fails on
--
--   operator class "gin_trgm_ops" does not exist for access method "gin"
--
-- because gin_trgm_ops lives in the extensions schema and nothing has put
-- that schema on the path yet. That is exactly what happens when the whole
-- chain is pasted into a SQL editor, which is the normal way to set this up.
set search_path = public, extensions;

-- ── 2. PostgREST's roles, as placeholders only ──────────────────────────
--
-- Created NOLOGIN, with no password, purely so the chain's grants resolve.
-- 0001_auth_shim.sql revokes everything from them and drops them again, so
-- they do not survive into the running system. Nothing can authenticate as
-- them in the meantime: no password is ever set, here or anywhere.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin;
  end if;
end $$;

grant usage on schema public, extensions to anon, authenticated, service_role;

-- ── 3. auth.users, as a shell ───────────────────────────────────────────
--
-- Only the columns the chain actually touches. GoTrue's real table has
-- dozens more; none of them are referenced by anything in
-- supabase/migrations/, which was checked column by column. Deliberately
-- WITHOUT encrypted_password: no password hash is ever stored on Neon in
-- this table, so a half-finished migration cannot leave credentials in a
-- place nothing guards. Phase 4 imports hashes into profiles.password_hash
-- instead, under RLS.
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  phone text,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- The chain's own auth.uid(), reading a JWT claim the way PostgREST sets
-- it. Replaced by 0001_auth_shim.sql with the app.current_profile_id
-- version; it exists here only so the chain's policies and function bodies
-- compile while replaying.
create or replace function auth.uid() returns uuid
language sql stable
as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

create or replace function auth.role() returns text
language sql stable
as $$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), 'anon') $$;

create or replace function auth.email() returns text
language sql stable
as $$ select nullif(current_setting('request.jwt.claim.email', true), '') $$;

-- ── 4. pg_net, replaced by an outbox ────────────────────────────────────
--
-- Migrations 0041/0042 push notifications by having a database trigger POST
-- the notification's id to /api/push/dispatch, using pg_net's async HTTP
-- client. Neon has no pg_net and no row-change webhook: its Function
-- Triggers fire on a schedule or on object storage, not on an INSERT.
--
-- So the transport changes and the call site does not. net.http_post() here
-- has pg_net's exact named-parameter signature as 0041/0042 call it, and
-- instead of opening a socket it writes the request to a durable outbox
-- table. Something then drains that table — see the runbook; the
-- recommended shape is the app firing the dispatch itself right after the
-- RPC returns (immediate, no polling delay) with a scheduled sweep of this
-- table as the safety net for anything that missed.
--
-- This is strictly more reliable than what it replaces, which is worth
-- saying plainly: pg_net fires and forgets inside a trigger, so a push lost
-- to a cold start or a 500 was lost silently. A row in a table can be
-- retried.
create table if not exists public.push_outbox (
  id bigserial primary key,
  url text not null,
  body jsonb not null,
  headers jsonb not null default '{}'::jsonb,
  timeout_ms integer,
  created_at timestamptz not null default now(),
  delivered_at timestamptz,
  attempts integer not null default 0,
  last_error text
);

-- Only the undelivered rows are ever scanned, and they are the small
-- minority. A partial index keeps the sweep's cost proportional to the
-- backlog rather than to the history.
create index if not exists push_outbox_pending_idx
  on public.push_outbox (created_at)
  where delivered_at is null;

alter table public.push_outbox enable row level security;

-- No policies, so no ordinary session can read or write this table: the
-- rows carry the push webhook secret in their headers. Everything that
-- touches it goes through a SECURITY DEFINER function, the same pattern
-- app_settings and the two code tables already use.
revoke all on table public.push_outbox from public;
revoke all on sequence public.push_outbox_id_seq from public;

create or replace function net.http_post(
  url text,
  body jsonb default '{}'::jsonb,
  params jsonb default '{}'::jsonb,
  headers jsonb default '{}'::jsonb,
  timeout_milliseconds integer default 5000
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
begin
  insert into public.push_outbox (url, body, headers, timeout_ms)
  values (url, body, headers, timeout_milliseconds)
  returning id into v_id;
  return v_id;
end;
$$;

comment on function net.http_post(text, jsonb, jsonb, jsonb, integer) is
  'Stand-in for pg_net on a database that does not have it. Same named '
  'parameters as pg_net''s http_post so migrations 0041/0042 call it '
  'unmodified, but it queues the request in public.push_outbox instead of '
  'sending it. Something outside the database drains that table.';

revoke all on function net.http_post(text, jsonb, jsonb, jsonb, integer) from public;

-- pg_net records every response in net._http_response, and
-- /api/push/dispatch deliberately returns a diagnostic body so that table
-- can be read when push goes wrong (see the comment in route.ts). Keep a
-- table of the same name so that habit, and anything written against it,
-- still finds somewhere to look — now filled by the drainer rather than by
-- the extension.
create table if not exists net._http_response (
  id bigint primary key,
  status_code integer,
  content text,
  error_msg text,
  created timestamptz not null default now()
);

revoke all on table net._http_response from public;


-- ========== supabase/migrations/0001_extensions_and_enums.sql =========

-- 0001_extensions_and_enums.sql
-- Extensions and shared enum types for the order management system.

create extension if not exists pgcrypto;
create extension if not exists "uuid-ossp";
create extension if not exists pg_trgm;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'user_role') then
    create type user_role as enum ('owner', 'moderator', 'driver', 'factory');
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'order_status') then
    create type order_status as enum (
      'new',           -- created, not yet assigned/approved
      'assigned',       -- distribution approved by Owner, driver notified
      'collected',      -- driver collected the order from the customer
      'at_factory',     -- factory confirmed receipt from driver
      'ready',          -- factory finished and marked ready for pickup
      'with_driver',    -- same driver picked the order back up from the factory
      'delivered',      -- delivered to customer, delivery code validated, closed
      'refused',        -- customer refused to receive the order
      'cancelled'       -- cancelled by Owner/Moderator before completion
    );
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'order_source') then
    create type order_source as enum ('website', 'messenger');
  end if;
end $$;


-- ========== supabase/migrations/0002_profiles.sql =====================

-- 0002_profiles.sql
-- One profile row per auth.users row, carrying the role that drives RBAC everywhere else.

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null,
  phone text,
  role user_role not null default 'driver',
  region_id uuid, -- FK added in 0003 after regions exists
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is 'Application user profile + role, one per auth.users row.';

-- Keep updated_at current on every update.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists set_profiles_updated_at on public.profiles;
create trigger set_profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- Auto-create a profile whenever a new auth user is created.
-- Role/full_name/phone are read from the signup metadata (set by the inviting Owner
-- when creating the account, e.g. via supabase.auth.admin.createUser({ user_metadata })).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, phone, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.email, 'مستخدم جديد'),
    new.raw_user_meta_data ->> 'phone',
    coalesce((new.raw_user_meta_data ->> 'role')::user_role, 'driver')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Helper used throughout RLS policies and RPCs to read the caller's role cheaply.
create or replace function public.current_user_role()
returns user_role
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

create or replace function public.is_owner()
returns boolean language sql stable security definer set search_path = public as $$
  select public.current_user_role() = 'owner';
$$;

create or replace function public.is_owner_or_moderator()
returns boolean language sql stable security definer set search_path = public as $$
  select public.current_user_role() in ('owner', 'moderator');
$$;


-- ========== supabase/migrations/0003_regions_and_driver_regions.sql ===

-- 0003_regions_and_driver_regions.sql

create table if not exists public.regions (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  created_at timestamptz not null default now()
);

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'profiles_region_id_fkey'
  ) then
    alter table public.profiles
      add constraint profiles_region_id_fkey
      foreign key (region_id) references public.regions (id) on delete set null;
  end if;
end;
$$;

-- Which regions each driver covers (used by the auto-distribution suggestion).
create table if not exists public.driver_regions (
  driver_id uuid not null references public.profiles (id) on delete cascade,
  region_id uuid not null references public.regions (id) on delete cascade,
  primary key (driver_id, region_id)
);

create index if not exists driver_regions_region_idx on public.driver_regions (region_id);


-- ========== supabase/migrations/0004_orders.sql =======================

-- 0004_orders.sql
-- The core orders table. One row per order ("أوردر"), one order_number for its whole
-- lifecycle, matching the spec's "رقم واحد للأوردر" requirement.

create sequence if not exists public.order_number_seq start 1;

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique,
  source order_source not null default 'website',
  status order_status not null default 'new',

  -- customer & order details (as captured at creation time)
  customer_name text not null,
  customer_phone text not null,
  customer_address text not null,
  region_id uuid references public.regions (id),
  pieces_count integer not null default 1 check (pieces_count > 0),
  piece_details text,
  color text,
  work_required text,
  customer_notes text,

  -- distribution
  assigned_driver_id uuid references public.profiles (id),
  suggested_driver_id uuid references public.profiles (id),
  distribution_approved_at timestamptz,
  distribution_approved_by uuid references public.profiles (id),

  -- lifecycle timestamps
  collected_at timestamptz,
  factory_received_at timestamptz,
  factory_ready_at timestamptz,
  driver_pickup_at timestamptz,
  delivered_at timestamptz,
  refused_at timestamptz,
  refusal_reason text,
  cancelled_at timestamptz,
  cancel_reason text,

  -- delivery code: never store plaintext, only a bcrypt-style hash via pgcrypto.
  -- The plaintext is returned exactly once, at creation, to the caller who wrote it
  -- on the customer's paper receipt.
  delivery_code_hash text not null,
  delivery_code_last_attempt_at timestamptz,
  failed_code_attempts integer not null default 0,

  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists orders_status_idx on public.orders (status);
create index if not exists orders_region_idx on public.orders (region_id);
create index if not exists orders_driver_idx on public.orders (assigned_driver_id);
create index if not exists orders_created_at_idx on public.orders (created_at desc);
create index if not exists orders_customer_phone_idx on public.orders (customer_phone);
create index if not exists orders_search_idx on public.orders
  using gin (order_number gin_trgm_ops, customer_name gin_trgm_ops, customer_phone gin_trgm_ops);

drop trigger if exists set_orders_updated_at on public.orders;
create trigger set_orders_updated_at
  before update on public.orders
  for each row execute function public.set_updated_at();

-- Assign the human-facing order number (ORD-0001, ORD-0002, ...) on insert.
create or replace function public.set_order_number()
returns trigger
language plpgsql
as $$
begin
  if new.order_number is null or new.order_number = '' then
    new.order_number := 'ORD-' || lpad(nextval('public.order_number_seq')::text, 4, '0');
  end if;
  return new;
end;
$$;

drop trigger if exists set_orders_order_number on public.orders;
create trigger set_orders_order_number
  before insert on public.orders
  for each row execute function public.set_order_number();

-- An order counts as "delayed" if it has been open longer than the SLA and is not
-- in a terminal state yet. Kept as a function (not a stored generated column) so the
-- threshold can be tuned without a migration.
create or replace function public.order_sla_hours()
returns integer language sql immutable as $$ select 48 $$;

create or replace function public.is_order_delayed(o public.orders)
returns boolean
language sql
stable
as $$
  select o.status not in ('delivered', 'cancelled', 'refused')
    and o.created_at < now() - (public.order_sla_hours() || ' hours')::interval;
$$;


-- ========== supabase/migrations/0005_order_history.sql ================

-- 0005_order_history.sql
-- Full movement/audit log per order ("سجل حركة الأوردر"). Every status change and
-- notable action (distribution set, code attempt, refusal, ...) is appended here.

create table if not exists public.order_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  event_type text not null,
  from_status order_status,
  to_status order_status,
  actor_id uuid references public.profiles (id),
  actor_role user_role,
  note text,
  created_at timestamptz not null default now()
);

create index if not exists order_history_order_idx on public.order_history (order_id, created_at);

create or replace function public.log_order_event(
  p_order_id uuid,
  p_event_type text,
  p_from_status order_status,
  p_to_status order_status,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role user_role;
begin
  select role into v_actor_role from public.profiles where id = v_actor_id;

  insert into public.order_history (order_id, event_type, from_status, to_status, actor_id, actor_role, note)
  values (p_order_id, p_event_type, p_from_status, p_to_status, v_actor_id, v_actor_role, p_note);
end;
$$;


-- ========== supabase/migrations/0006_notifications.sql ================

-- 0006_notifications.sql
-- Simple, clear in-app notifications per role (matches the spec: "إشعارات بسيطة وواضحة").

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  order_id uuid references public.orders (id) on delete cascade,
  type text not null,
  title text not null,
  body text,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists notifications_user_idx on public.notifications (user_id, is_read, created_at desc);

create or replace function public.notify_user(
  p_user_id uuid,
  p_order_id uuid,
  p_type text,
  p_title text,
  p_body text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user_id is null then
    return;
  end if;

  insert into public.notifications (user_id, order_id, type, title, body)
  values (p_user_id, p_order_id, p_type, p_title, p_body);
end;
$$;

-- Notify every active user with a given role (used for Owner-facing events).
create or replace function public.notify_role(
  p_role user_role,
  p_order_id uuid,
  p_type text,
  p_title text,
  p_body text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user record;
begin
  for v_user in select id from public.profiles where role = p_role and is_active loop
    perform public.notify_user(v_user.id, p_order_id, p_type, p_title, p_body);
  end loop;
end;
$$;


-- ========== supabase/migrations/0007_order_creation.sql ===============

-- 0007_order_creation.sql
-- Order creation for both intake channels described in the spec:
--   1) "Website" — the customer creates the order themselves, no login required.
--   2) "Messenger" — the Moderator chats with the customer on Messenger and enters
--      the order on their behalf.
-- Both paths return the plaintext delivery code exactly once, to be written on the
-- customer's paper receipt. From then on only a hash is stored (see 0004_orders.sql).

create or replace function public.generate_delivery_code()
returns text
language sql
volatile
as $$
  select lpad((floor(random() * 9000) + 1000)::int::text, 4, '0');
$$;

drop type if exists public.new_order_result cascade;

create type public.new_order_result as (
  order_id uuid,
  order_number text,
  delivery_code text
);

create or replace function public.create_order_internal(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text,
  p_color text,
  p_work_required text,
  p_customer_notes text,
  p_source order_source,
  p_created_by uuid
)
returns public.new_order_result
language plpgsql
security definer
-- extensions is included because Supabase installs pgcrypto (crypt/gen_salt,
-- used below) into the "extensions" schema by default, not "public"; a plain
-- local Postgres install puts it in "public", which is why this gap wasn't
-- caught by local testing.
set search_path = public, extensions
as $$
declare
  v_code text := public.generate_delivery_code();
  v_order public.orders;
  v_result public.new_order_result;
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

  insert into public.orders (
    customer_name, customer_phone, customer_address, region_id,
    pieces_count, piece_details, color, work_required, customer_notes,
    source, created_by, delivery_code_hash
  ) values (
    trim(p_customer_name), trim(p_customer_phone), trim(p_customer_address), p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    p_source, p_created_by, crypt(v_code, gen_salt('bf'))
  )
  returning * into v_order;

  perform public.log_order_event(v_order.id, 'created', null, 'new',
    'تم إنشاء الأوردر عبر ' || case when p_source = 'website' then 'الموقع' else 'Messenger' end);

  perform public.notify_role('owner', v_order.id, 'new_order', 'أوردر جديد ' || v_order.order_number,
    'تم استلام أوردر جديد من ' || v_order.customer_name);

  v_result.order_id := v_order.id;
  v_result.order_number := v_order.order_number;
  v_result.delivery_code := v_code;
  return v_result;
end;
$$;

-- create_order_internal has no role/ownership check of its own — it trusts its
-- caller completely (including which order_source and created_by to record). It
-- must never be callable directly by anon/authenticated; only the two vetted
-- wrappers below (which run as this function's owner once inside their own
-- SECURITY DEFINER body) may reach it.
revoke all on function public.create_order_internal from public, anon, authenticated;

-- Public entry point: anyone (anonymous website visitor) can create an order for
-- themselves. SECURITY DEFINER bypasses RLS internally but the function itself only
-- ever inserts a single well-formed row — it does not expose any read access.
create or replace function public.public_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'website', null
  );
end;
$$;

revoke all on function public.public_create_order from public;
grant execute on function public.public_create_order to anon, authenticated;

-- Moderator/Owner entry point for Messenger-sourced orders.
create or replace function public.moderator_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح لك بإنشاء أوردر' using errcode = '42501';
  end if;

  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'messenger', auth.uid()
  );
end;
$$;

revoke all on function public.moderator_create_order from public;
grant execute on function public.moderator_create_order to authenticated;


-- ========== supabase/migrations/0008_rls_policies.sql =================

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

-- A Moderator may update (e.g. activate/deactivate) driver/factory accounts
-- only — never an Owner's or another Moderator's row. `using` gates on the
-- row's current role, `with check` gates on the row post-update, so this
-- also blocks a Moderator from changing someone's role to owner/moderator
-- (on top of the self-escalation trigger above, which covers self-updates).
drop policy if exists profiles_update_moderator on public.profiles;
create policy profiles_update_moderator on public.profiles
  for update using (public.current_user_role() = 'moderator' and role in ('driver', 'factory'))
  with check (public.current_user_role() = 'moderator' and role in ('driver', 'factory'));

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

-- Assigning a driver's coverage regions is an operational task, not a
-- sensitive one, so a Moderator gets the same access here as an Owner.
drop policy if exists driver_regions_write_moderator on public.driver_regions;
create policy driver_regions_write_moderator on public.driver_regions
  for all using (public.current_user_role() = 'moderator')
  with check (public.current_user_role() = 'moderator');

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


-- ========== supabase/migrations/0009_workflow_rpcs.sql ================

-- 0009_workflow_rpcs.sql
-- Every legal state transition in the order lifecycle, each as its own RPC:
--   new -> (distribution set, pending approval) -> assigned -> collected
--        -> at_factory -> ready -> with_driver -> delivered
-- with 'refused' and 'cancelled' as side-exits. Each function checks the caller's
-- role and the order's current status server-side, so the workflow cannot be
-- skipped or reordered from the client no matter what the UI sends.

-- ---------- distribution ----------

create or replace function public.suggest_drivers(p_order_id uuid)
returns table (
  driver_id uuid,
  full_name text,
  covers_region boolean,
  active_orders_count bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_region_id uuid;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select region_id into v_region_id from public.orders where id = p_order_id;

  return query
    select
      p.id,
      p.full_name,
      exists (
        select 1 from public.driver_regions dr
        where dr.driver_id = p.id and dr.region_id = v_region_id
      ) as covers_region,
      (
        select count(*) from public.orders o
        where o.assigned_driver_id = p.id
          and o.status not in ('delivered', 'cancelled', 'refused')
      ) as active_orders_count
    from public.profiles p
    where p.role = 'driver' and p.is_active
    order by covers_region desc, active_orders_count asc, p.full_name asc;
end;
$$;

create or replace function public.set_order_distribution(p_order_id uuid, p_driver_id uuid, p_is_suggestion boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status order_status;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

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

create or replace function public.clear_order_distribution(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status order_status;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select status into v_status from public.orders where id = p_order_id for update;
  if v_status <> 'new' then
    raise exception 'لا يمكن إلغاء توزيع أوردر تم اعتماده بالفعل';
  end if;

  update public.orders set assigned_driver_id = null where id = p_order_id;
  perform public.log_order_event(p_order_id, 'distribution_cleared', v_status, v_status, 'تم إلغاء التوزيع المقترح');
end;
$$;

create or replace function public.approve_distribution(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  if not public.is_owner() then
    raise exception 'اعتماد التوزيع من صلاحية Owner فقط' using errcode = '42501';
  end if;

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

-- ---------- driver actions ----------

create or replace function public.driver_mark_collected(p_order_id uuid)
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
  if v_order.status <> 'assigned' then raise exception 'الأوردر ليس بحالة تسمح بتسجيل الاستلام من العميل'; end if;

  update public.orders set status = 'collected', collected_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'collected_from_customer', 'assigned', 'collected', 'تم استلام الأوردر من العميل');
end;
$$;

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

  perform public.log_order_event(p_order_id, 'handed_to_factory', 'collected', 'collected', 'المندوب توجه بالأوردر إلى المصنع');
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
end;
$$;

create or replace function public.driver_deliver_to_customer(p_order_id uuid, p_code text)
returns boolean
language plpgsql
security definer
-- extensions included for crypt() below — see the note on create_order_internal
-- in 0007_order_creation.sql for why.
set search_path = public, extensions
as $$
declare
  v_order public.orders;
  v_ok boolean;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.assigned_driver_id <> auth.uid() then raise exception 'غير مصرح' using errcode = '42501'; end if;
  if v_order.status <> 'with_driver' then raise exception 'الأوردر ليس بحالة تسمح بالتسليم للعميل'; end if;

  v_ok := (crypt(coalesce(p_code, ''), v_order.delivery_code_hash) = v_order.delivery_code_hash);

  if v_ok then
    update public.orders set status = 'delivered', delivered_at = now() where id = p_order_id;
    perform public.log_order_event(p_order_id, 'delivered', 'with_driver', 'delivered', 'تم التسليم للعميل وتأكيد الكود بنجاح');
  else
    update public.orders
      set failed_code_attempts = failed_code_attempts + 1,
          delivery_code_last_attempt_at = now()
      where id = p_order_id;
    perform public.log_order_event(p_order_id, 'delivery_code_mismatch', 'with_driver', 'with_driver', 'محاولة تسليم بكود غير صحيح');
  end if;

  return v_ok;
end;
$$;

create or replace function public.driver_log_refusal(p_order_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  if length(trim(coalesce(p_reason, ''))) = 0 then
    raise exception 'يجب كتابة سبب رفض الاستلام';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.assigned_driver_id <> auth.uid() then raise exception 'غير مصرح' using errcode = '42501'; end if;
  if v_order.status <> 'with_driver' then raise exception 'الأوردر ليس بحالة تسمح بتسجيل رفض الاستلام'; end if;

  update public.orders
    set status = 'refused', refused_at = now(), refusal_reason = trim(p_reason)
    where id = p_order_id;

  perform public.log_order_event(p_order_id, 'refused', 'with_driver', 'refused', p_reason);
  perform public.notify_role('owner', p_order_id, 'order_refused', 'رفض استلام أوردر ' || v_order.order_number, p_reason);
end;
$$;

-- ---------- factory actions ----------

create or replace function public.factory_confirm_receipt(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  if public.current_user_role() not in ('factory', 'owner', 'moderator') then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status <> 'collected' then raise exception 'الأوردر ليس بحالة تسمح بتأكيد الاستلام في المصنع'; end if;

  update public.orders set status = 'at_factory', factory_received_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'factory_confirmed_receipt', 'collected', 'at_factory', 'المصنع أكد استلام الأوردر');
  perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'factory_received',
    'تم استلام الأوردر ' || v_order.order_number || ' في المصنع', null);
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
  if public.current_user_role() not in ('factory', 'owner', 'moderator') then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status <> 'at_factory' then raise exception 'الأوردر ليس داخل المصنع حاليًا'; end if;

  update public.orders set status = 'ready', factory_ready_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'factory_marked_ready', 'at_factory', 'ready', 'المصنع أنهى العمل والأوردر جاهز للتسليم');
  perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'ready_for_pickup',
    'أوردر ' || v_order.order_number || ' جاهز للتسليم', 'يمكنك استلامه من المصنع الآن');
end;
$$;

-- ---------- owner: cancel ----------

create or replace function public.owner_cancel_order(p_order_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status in ('delivered', 'cancelled') then
    raise exception 'لا يمكن إلغاء أوردر تم تسليمه أو ملغى بالفعل';
  end if;

  update public.orders set status = 'cancelled', cancelled_at = now(), cancel_reason = p_reason where id = p_order_id;
  perform public.log_order_event(p_order_id, 'cancelled', v_order.status, 'cancelled', p_reason);
end;
$$;

-- ---------- public customer tracking ----------

drop type if exists public.tracked_order cascade;

create type public.tracked_order as (
  order_number text,
  status order_status,
  pieces_count integer,
  created_at timestamptz,
  collected_at timestamptz,
  factory_received_at timestamptz,
  factory_ready_at timestamptz,
  driver_pickup_at timestamptz,
  delivered_at timestamptz,
  refused_at timestamptz,
  is_delayed boolean
);

create or replace function public.track_order(p_order_number text, p_phone text)
returns public.tracked_order
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_result public.tracked_order;
  v_digits_input text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  select * into v_order
  from public.orders o
  where upper(o.order_number) = upper(trim(coalesce(p_order_number, '')))
    and right(regexp_replace(o.customer_phone, '\D', '', 'g'), 8) = right(v_digits_input, 8)
  limit 1;

  if v_order is null then
    return null;
  end if;

  v_result.order_number := v_order.order_number;
  v_result.status := v_order.status;
  v_result.pieces_count := v_order.pieces_count;
  v_result.created_at := v_order.created_at;
  v_result.collected_at := v_order.collected_at;
  v_result.factory_received_at := v_order.factory_received_at;
  v_result.factory_ready_at := v_order.factory_ready_at;
  v_result.driver_pickup_at := v_order.driver_pickup_at;
  v_result.delivered_at := v_order.delivered_at;
  v_result.refused_at := v_order.refused_at;
  v_result.is_delayed := public.is_order_delayed(v_order);
  return v_result;
end;
$$;

revoke all on function public.track_order from public;
grant execute on function public.track_order to anon, authenticated;

-- ---------- lock down the rest to authenticated users only ----------
-- (Postgres grants EXECUTE to PUBLIC by default; every workflow RPC below does its
-- own role/ownership check internally, but we still remove anon access entirely
-- as defense in depth — an anonymous caller should never reach these at all.)
revoke all on function public.suggest_drivers(uuid) from public;
revoke all on function public.set_order_distribution(uuid, uuid, boolean) from public;
revoke all on function public.clear_order_distribution(uuid) from public;
revoke all on function public.approve_distribution(uuid) from public;
revoke all on function public.driver_mark_collected(uuid) from public;
revoke all on function public.driver_hand_to_factory(uuid) from public;
revoke all on function public.driver_confirm_factory_pickup(uuid) from public;
revoke all on function public.driver_deliver_to_customer(uuid, text) from public;
revoke all on function public.driver_log_refusal(uuid, text) from public;
revoke all on function public.factory_confirm_receipt(uuid) from public;
revoke all on function public.factory_mark_ready(uuid) from public;
revoke all on function public.owner_cancel_order(uuid, text) from public;

grant execute on function public.suggest_drivers(uuid) to authenticated;
grant execute on function public.set_order_distribution(uuid, uuid, boolean) to authenticated;
grant execute on function public.clear_order_distribution(uuid) to authenticated;
grant execute on function public.approve_distribution(uuid) to authenticated;
grant execute on function public.driver_mark_collected(uuid) to authenticated;
grant execute on function public.driver_hand_to_factory(uuid) to authenticated;
grant execute on function public.driver_confirm_factory_pickup(uuid) to authenticated;
grant execute on function public.driver_deliver_to_customer(uuid, text) to authenticated;
grant execute on function public.driver_log_refusal(uuid, text) to authenticated;
grant execute on function public.factory_confirm_receipt(uuid) to authenticated;
grant execute on function public.factory_mark_ready(uuid) to authenticated;
grant execute on function public.owner_cancel_order(uuid, text) to authenticated;


-- ========== supabase/migrations/0010_reporting_and_views.sql ==========

-- 0010_reporting_and_views.sql
-- Factory-safe view (no customer PII) + Owner reporting/analytics RPCs.

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
  o.collected_at,
  o.factory_received_at,
  o.factory_ready_at,
  o.created_at
from public.orders o
left join public.profiles p on p.id = o.assigned_driver_id
where o.status in ('collected', 'at_factory', 'ready')
  and public.current_user_role() in ('factory', 'owner', 'moderator');

-- (grant select on this view to authenticated is in 0011_table_grants.sql)

-- Owner dashboard summary cards.
create or replace function public.dashboard_stats()
returns table (
  total_orders bigint,
  new_orders bigint,
  assigned_orders bigint,
  collected_orders bigint,
  at_factory_orders bigint,
  ready_orders bigint,
  with_driver_orders bigint,
  delivered_orders bigint,
  refused_orders bigint,
  cancelled_orders bigint,
  delayed_orders bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    select
      count(*),
      count(*) filter (where status = 'new'),
      count(*) filter (where status = 'assigned'),
      count(*) filter (where status = 'collected'),
      count(*) filter (where status = 'at_factory'),
      count(*) filter (where status = 'ready'),
      count(*) filter (where status = 'with_driver'),
      count(*) filter (where status = 'delivered'),
      count(*) filter (where status = 'refused'),
      count(*) filter (where status = 'cancelled'),
      count(*) filter (where public.is_order_delayed(orders.*))
    from public.orders;
end;
$$;

-- Daily report for a given day (defaults to today).
-- Return type changed once during development (extra in-factory/ready/exited
-- columns were added) — CREATE OR REPLACE can't change a function's return
-- type, so this drops it first to stay safely re-runnable.
drop function if exists public.daily_report(date);

create function public.daily_report(p_day date default current_date)
returns table (
  new_orders bigint,
  collected_orders bigint,
  entered_factory bigint,
  in_factory_now bigint,
  ready_now bigint,
  exited_factory bigint,
  delivered_orders bigint,
  delayed_orders bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    select
      count(*) filter (where created_at::date = p_day),
      count(*) filter (where collected_at::date = p_day),
      count(*) filter (where factory_received_at::date = p_day),
      count(*) filter (where status = 'at_factory'),
      count(*) filter (where status = 'ready'),
      count(*) filter (where driver_pickup_at::date = p_day),
      count(*) filter (where delivered_at::date = p_day),
      count(*) filter (where public.is_order_delayed(orders.*))
    from public.orders;
end;
$$;

-- Monthly report for the month containing p_month (defaults to current
-- month), including a month-over-month comparison. Same drop-first note as
-- daily_report above.
drop function if exists public.monthly_report(date);

create function public.monthly_report(p_month date default current_date)
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
  v_prev_end date := v_start;
  v_total bigint;
  v_prev_total bigint;
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  select count(*) into v_total from public.orders where created_at >= v_start and created_at < v_end;
  select count(*) into v_prev_total from public.orders where created_at >= v_prev_start and created_at < v_prev_end;

  return query
    select
      v_total,
      coalesce((select sum(pieces_count) from public.orders where created_at >= v_start and created_at < v_end), 0),
      (select count(*) from public.orders where created_at >= v_start and created_at < v_end and status = 'delivered'),
      (select count(*) from public.orders where created_at >= v_start and created_at < v_end and public.is_order_delayed(orders.*)),
      (select round(avg(extract(epoch from (delivered_at - created_at)) / 3600.0), 1)
         from public.orders
         where created_at >= v_start and created_at < v_end and status = 'delivered'),
      (select round(
          100.0 * count(*) filter (where delivered_at <= created_at + (public.order_sla_hours() || ' hours')::interval)
          / nullif(count(*), 0),
          1
        )
        from public.orders
        where created_at >= v_start and created_at < v_end and status = 'delivered'),
      v_prev_total,
      (select count(*) from public.orders where created_at >= v_prev_start and created_at < v_prev_end and status = 'delivered'),
      case when v_prev_total = 0 then null else round(100.0 * (v_total - v_prev_total) / v_prev_total, 1) end;
end;
$$;

-- Per-driver performance.
-- Defined in 0013_driver_reassignment_and_login.sql instead of here: its
-- return type changed once already (an on_time_rate column was added), and
-- CREATE OR REPLACE can't change a function's return type — same
-- drop-and-recreate hazard as daily_report/monthly_report above, so it gets
-- the same fix, which is to have exactly one file define it. Defining it a
-- second time here (even identically) would recreate that hazard the next
-- time either file changes.

-- Currently delayed orders, with enough context for the Owner to act.
create or replace function public.delayed_orders_report()
returns table (
  id uuid,
  order_number text,
  customer_name text,
  region_name text,
  driver_name text,
  status order_status,
  created_at timestamptz,
  hours_open numeric
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    select
      o.id, o.order_number, o.customer_name, r.name, p.full_name, o.status, o.created_at,
      round(extract(epoch from (now() - o.created_at)) / 3600.0, 1)
    from public.orders o
    left join public.regions r on r.id = o.region_id
    left join public.profiles p on p.id = o.assigned_driver_id
    where public.is_order_delayed(o.*)
    order by o.created_at asc;
end;
$$;

-- Most-requested regions.
create or replace function public.top_regions_report()
returns table (region_name text, order_count bigint)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    select coalesce(r.name, 'غير محدد'), count(*)
    from public.orders o
    left join public.regions r on r.id = o.region_id
    group by r.name
    order by count(*) desc;
end;
$$;

-- driver_performance_report's own revoke/grant now live in 0013 alongside
-- its definition (see the comment above) — it doesn't exist yet at this
-- point on a fresh run, so granting on it here would fail.
revoke all on function public.dashboard_stats() from public;
revoke all on function public.daily_report(date) from public;
revoke all on function public.monthly_report(date) from public;
revoke all on function public.delayed_orders_report() from public;
revoke all on function public.top_regions_report() from public;

grant execute on function public.dashboard_stats() to authenticated;
grant execute on function public.daily_report(date) to authenticated;
grant execute on function public.monthly_report(date) to authenticated;
grant execute on function public.delayed_orders_report() to authenticated;
grant execute on function public.top_regions_report() to authenticated;


-- ========== supabase/migrations/0011_table_grants.sql =================

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


-- ========== supabase/migrations/0012_seed_egypt_regions.sql ===========

-- 0012_seed_egypt_regions.sql
-- Seeds Egypt's 27 governorates as regions, so the Owner/Moderator have a
-- real list to work with immediately instead of adding each city by hand.
-- "on conflict (name) do nothing" makes this safe to re-run, and it never
-- overwrites a region the Owner has since renamed or added manually.

insert into public.regions (name) values
  ('القاهرة'),
  ('الجيزة'),
  ('الإسكندرية'),
  ('الدقهلية'),
  ('البحر الأحمر'),
  ('البحيرة'),
  ('الفيوم'),
  ('الغربية'),
  ('الإسماعيلية'),
  ('المنوفية'),
  ('المنيا'),
  ('القليوبية'),
  ('الوادي الجديد'),
  ('السويس'),
  ('أسوان'),
  ('أسيوط'),
  ('بني سويف'),
  ('بورسعيد'),
  ('دمياط'),
  ('الشرقية'),
  ('جنوب سيناء'),
  ('كفر الشيخ'),
  ('مطروح'),
  ('الأقصر'),
  ('قنا'),
  ('شمال سيناء'),
  ('سوهاج')
on conflict (name) do nothing;


-- ========== supabase/migrations/0013_driver_reassignment_and_login.sql 

-- 0013_driver_reassignment_and_login.sql
-- Three things:
--   1) Let Owner/Moderator change an order's driver at any point in its
--      lifecycle (not just before distribution is approved) — the spec
--      explicitly asks for "نقل أوردر من مندوب إلى آخر" and the Owner asked
--      for it again directly ("add driver or change it whenever I want").
--   2) profiles.password_set + a unique index on phone, backing a phone
--      number + password login flow (staff sign in with their phone number,
--      creating a password themselves on first login instead of an Owner
--      sharing one or relying on email delivery).
--   3) driver_performance_report gains a per-driver on-time delivery rate —
--      the one field from spec section 21 ("تقارير أداء المندوبين") that was
--      still missing.

-- ---------- 1) reassign driver at any (non-terminal) status ----------

create or replace function public.reassign_order_driver(p_order_id uuid, p_new_driver_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_new_driver public.profiles;
  v_old_driver_name text;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status in ('delivered', 'cancelled', 'refused') then
    raise exception 'لا يمكن تغيير المندوب لأوردر منتهٍ';
  end if;

  select * into v_new_driver from public.profiles where id = p_new_driver_id;
  if v_new_driver is null or v_new_driver.role <> 'driver' or not v_new_driver.is_active then
    raise exception 'المندوب المحدد غير صالح';
  end if;
  if v_order.assigned_driver_id = p_new_driver_id then
    raise exception 'هذا المندوب مسؤول عن الأوردر بالفعل';
  end if;

  if v_order.assigned_driver_id is not null then
    select full_name into v_old_driver_name from public.profiles where id = v_order.assigned_driver_id;
  end if;

  update public.orders set assigned_driver_id = p_new_driver_id where id = p_order_id;

  perform public.log_order_event(p_order_id, 'driver_reassigned', v_order.status, v_order.status,
    case when v_old_driver_name is not null
      then 'تم تغيير المندوب من ' || v_old_driver_name || ' إلى ' || v_new_driver.full_name
      else 'تم تعيين مندوب: ' || v_new_driver.full_name
    end);

  if v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'reassigned_away',
      'تم نقل الأوردر ' || v_order.order_number || ' إلى مندوب آخر', null);
  end if;

  -- Only notify the new driver immediately if they can already see the order
  -- (i.e. distribution is past the pending-approval stage); before approval
  -- this mirrors set_order_distribution, which doesn't notify either.
  if v_order.status <> 'new' then
    perform public.notify_user(p_new_driver_id, p_order_id, 'order_assigned',
      'تم إسناد أوردر إليك ' || v_order.order_number, 'العميل: ' || v_order.customer_name);
  end if;
end;
$$;

revoke all on function public.reassign_order_driver from public;
grant execute on function public.reassign_order_driver to authenticated;

-- ---------- 2) phone-number login support ----------

alter table public.profiles add column if not exists password_set boolean not null default true;

comment on column public.profiles.password_set is
  'false right after an Owner/Moderator creates the account (or resets its password) — the worker must set their own password on next login before signing in.';

create unique index if not exists profiles_phone_unique_idx on public.profiles (phone) where phone is not null;

-- ---------- 3) driver_performance_report: add on-time delivery rate ----------

drop function if exists public.driver_performance_report();

create function public.driver_performance_report()
returns table (
  driver_id uuid,
  full_name text,
  total_orders bigint,
  completed_orders bigint,
  delayed_orders bigint,
  active_orders bigint,
  avg_completion_hours numeric,
  on_time_rate numeric,
  refusal_count bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    select
      p.id,
      p.full_name,
      count(o.id),
      count(o.id) filter (where o.status = 'delivered'),
      count(o.id) filter (where public.is_order_delayed(o.*)),
      count(o.id) filter (where o.status not in ('delivered', 'cancelled', 'refused')),
      round(avg(extract(epoch from (o.delivered_at - o.created_at)) / 3600.0) filter (where o.status = 'delivered'), 1),
      round(
        100.0 * count(o.id) filter (where o.status = 'delivered' and o.delivered_at <= o.created_at + (public.order_sla_hours() || ' hours')::interval)
        / nullif(count(o.id) filter (where o.status = 'delivered'), 0),
        1
      ),
      count(o.id) filter (where o.status = 'refused')
    from public.profiles p
    left join public.orders o on o.assigned_driver_id = p.id
    where p.role = 'driver'
    group by p.id, p.full_name
    order by p.full_name;
end;
$$;

revoke all on function public.driver_performance_report() from public;
grant execute on function public.driver_performance_report() to authenticated;


-- ========== supabase/migrations/0014_driver_approval_fix_and_factory_assignment.sql 

-- 0014_driver_approval_fix_and_factory_assignment.sql
-- Two fixes, both from the same round of bug reports:
--
--   1) "I assigned the driver and nothing appears on his page" — root cause
--      confirmed by direct reproduction: reassign_order_driver() (the RPC
--      behind the "تعيين مندوب" / ChangeDriverButton control) sets
--      assigned_driver_id but never sets distribution_approved_at. The
--      orders_select_driver RLS policy (0008) requires
--      distribution_approved_at IS NOT NULL before a driver can see ANY
--      order, even one directly assigned to them — so an order assigned
--      this way was permanently invisible to that driver, with no
--      self-service recovery (approve_distribution, the only other RPC that
--      sets that column, is Owner-only and only reachable from the
--      suggest -> approve flow, not this one). Fix: reassign_order_driver
--      now also stamps distribution_approved_at (if not already set) and
--      advances a still-'new' order to 'assigned', exactly like
--      approve_distribution does — direct assignment is just a shortcut
--      through the same two steps, so it should leave the order in the same
--      state. Also fixes a smaller side effect of the same gap: the newly
--      assigned driver was never notified when the order was still 'new'
--      (skipped on purpose because the order wasn't visible to them yet) —
--      now that it's always visible immediately, always notify.
--
--   2) "I need to assign the factory when create the order" — multiple
--      factory accounts are already a normal, supported staff role (see
--      team-manager.tsx's role options), so this adds the same kind of
--      per-order routing that already exists for drivers: an optional
--      assigned_factory_id on the order, settable at creation, which
--      narrows that order's visibility on the factory dashboard to the
--      chosen factory account (an order left unassigned stays visible to
--      every factory account, same as today).

-- ---------- 1) fix reassign_order_driver ----------

create or replace function public.reassign_order_driver(p_order_id uuid, p_new_driver_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_new_driver public.profiles;
  v_old_driver_name text;
  v_new_status public.order_status;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status in ('delivered', 'cancelled', 'refused') then
    raise exception 'لا يمكن تغيير المندوب لأوردر منتهٍ';
  end if;

  select * into v_new_driver from public.profiles where id = p_new_driver_id;
  if v_new_driver is null or v_new_driver.role <> 'driver' or not v_new_driver.is_active then
    raise exception 'المندوب المحدد غير صالح';
  end if;
  if v_order.assigned_driver_id = p_new_driver_id then
    raise exception 'هذا المندوب مسؤول عن الأوردر بالفعل';
  end if;

  if v_order.assigned_driver_id is not null then
    select full_name into v_old_driver_name from public.profiles where id = v_order.assigned_driver_id;
  end if;

  -- A direct assignment must make the order visible to the driver right
  -- away, so it always carries the same "approval" step that the
  -- suggest -> approve flow would otherwise require separately.
  v_new_status := case when v_order.status = 'new' then 'assigned' else v_order.status end;

  update public.orders
    set assigned_driver_id = p_new_driver_id,
        distribution_approved_at = coalesce(distribution_approved_at, now()),
        distribution_approved_by = coalesce(distribution_approved_by, auth.uid()),
        status = v_new_status
    where id = p_order_id;

  perform public.log_order_event(p_order_id, 'driver_reassigned', v_order.status, v_new_status,
    case when v_old_driver_name is not null
      then 'تم تغيير المندوب من ' || v_old_driver_name || ' إلى ' || v_new_driver.full_name
      else 'تم تعيين مندوب: ' || v_new_driver.full_name
    end);

  if v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'reassigned_away',
      'تم نقل الأوردر ' || v_order.order_number || ' إلى مندوب آخر', null);
  end if;

  -- Previously skipped for a brand-new order because it wasn't visible to
  -- the driver yet — now it always is, so always notify.
  perform public.notify_user(p_new_driver_id, p_order_id, 'order_assigned',
    'تم إسناد أوردر إليك ' || v_order.order_number, 'العميل: ' || v_order.customer_name);
end;
$$;

-- ---------- 2) factory assignment ----------

alter table public.orders add column if not exists assigned_factory_id uuid references public.profiles (id);
create index if not exists orders_factory_idx on public.orders (assigned_factory_id);

comment on column public.orders.assigned_factory_id is
  'Optional: which factory account this order is routed to, set at creation. NULL means unassigned — visible to every factory account, same as before this column existed.';

-- create_order_internal gains an optional p_factory_id. A new trailing
-- parameter changes the function's argument-type signature, and Postgres
-- treats a changed signature as a distinct function rather than something
-- CREATE OR REPLACE can update in place — it would silently leave the old
-- 9/11-arg versions in the catalog alongside the new ones (and then every
-- call site becomes ambiguous, "is not unique"). Drop the old signatures
-- first so each function has exactly one, current version.
drop function if exists public.create_order_internal(text, text, text, uuid, integer, text, text, text, text, order_source, uuid);
drop function if exists public.public_create_order(text, text, text, uuid, integer, text, text, text, text);
drop function if exists public.moderator_create_order(text, text, text, uuid, integer, text, text, text, text);

-- Validated the same way p_region_id's driver-equivalent would be (must be
-- an active factory account).
create or replace function public.create_order_internal(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text,
  p_color text,
  p_work_required text,
  p_customer_notes text,
  p_source order_source,
  p_created_by uuid,
  p_factory_id uuid default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := public.generate_delivery_code();
  v_order public.orders;
  v_result public.new_order_result;
  v_factory public.profiles;
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

  if p_factory_id is not null then
    select * into v_factory from public.profiles where id = p_factory_id;
    if v_factory is null or v_factory.role <> 'factory' or not v_factory.is_active then
      raise exception 'المصنع المحدد غير صالح' using errcode = '22023';
    end if;
  end if;

  insert into public.orders (
    customer_name, customer_phone, customer_address, region_id,
    pieces_count, piece_details, color, work_required, customer_notes,
    source, created_by, delivery_code_hash, assigned_factory_id
  ) values (
    trim(p_customer_name), trim(p_customer_phone), trim(p_customer_address), p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    p_source, p_created_by, crypt(v_code, gen_salt('bf')), p_factory_id
  )
  returning * into v_order;

  perform public.log_order_event(v_order.id, 'created', null, 'new',
    'تم إنشاء الأوردر عبر ' || case when p_source = 'website' then 'الموقع' else 'Messenger' end);

  perform public.notify_role('owner', v_order.id, 'new_order', 'أوردر جديد ' || v_order.order_number,
    'تم استلام أوردر جديد من ' || v_order.customer_name);

  v_result.order_id := v_order.id;
  v_result.order_number := v_order.order_number;
  v_result.delivery_code := v_code;
  return v_result;
end;
$$;

-- The DROP above removed the old function object along with whatever
-- privileges 0007 had granted on it — CREATE OR REPLACE only updates an
-- existing object's body, it doesn't restore grants on one it just
-- recreated after a drop. Re-apply the same lockdown 0007 originally set:
-- this function trusts its caller completely, so it must stay unreachable
-- except through the two vetted wrappers below.
revoke all on function public.create_order_internal from public, anon, authenticated;

create or replace function public.public_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null,
  p_factory_id uuid default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'website', null, p_factory_id
  );
end;
$$;

revoke all on function public.public_create_order from public;
grant execute on function public.public_create_order to anon, authenticated;

create or replace function public.moderator_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null,
  p_factory_id uuid default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح لك بإنشاء أوردر' using errcode = '42501';
  end if;

  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'messenger', auth.uid(), p_factory_id
  );
end;
$$;

revoke all on function public.moderator_create_order from public;
grant execute on function public.moderator_create_order to authenticated;

-- RLS: an order with a factory assigned is only visible to that factory
-- account (owner/moderator are unaffected — orders_select_staff already
-- gives them full access); an unassigned order stays visible to every
-- factory account, same as before this column existed.
drop policy if exists orders_select_factory on public.orders;
create policy orders_select_factory on public.orders
  for select using (
    public.current_user_role() = 'factory'
    and status in ('collected', 'at_factory', 'ready')
    and (assigned_factory_id is null or assigned_factory_id = auth.uid())
  );

drop policy if exists order_history_select_factory on public.order_history;
create policy order_history_select_factory on public.order_history
  for select using (
    public.current_user_role() = 'factory'
    and exists (
      select 1 from public.orders o
      where o.id = order_history.order_id
        and o.status in ('collected', 'at_factory', 'ready')
        and (o.assigned_factory_id is null or o.assigned_factory_id = auth.uid())
    )
  );

-- factory_orders_view has security_invoker = false and does its own
-- authorization in its WHERE clause instead of relying on the orders RLS
-- above (that's what every factory-role read actually goes through — see
-- listFactoryOrders/getFactoryOrderByNumber) — so the same per-factory
-- filter has to be applied here directly too, alongside the new columns
-- for display. Dropped and recreated rather than CREATE OR REPLACE because
-- the new columns land in the middle of the column list, and Postgres
-- refuses to change an existing view's column order/names in place.
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
  o.collected_at,
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


-- ========== supabase/migrations/0015_factory_location_and_handoff_tracking.sql 

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


-- ========== supabase/migrations/0016_mandatory_assignment_delivery_code_and_geo.sql 

-- 0016_mandatory_assignment_delivery_code_and_geo.sql
--
--   1) "driver and factory mandatory when a Moderator creates the order
--      (not Owner)" — the app layer (createModeratorOrderAction) is what
--      enforces "mandatory for Moderator, optional for Owner" (a role-based
--      UI rule doesn't belong in a shared DB function), but there was no
--      way to assign a driver AT creation time at all — driver assignment
--      only ever happened afterward, through the separate suggest/approve
--      distribution flow or the direct "change driver" control. This adds
--      an optional p_driver_id to create_order_internal/moderator_create_order,
--      mirroring exactly what reassign_order_driver's direct-assignment path
--      already does (assign + pre-approve + notify) so a driver picked at
--      creation is immediately visible to that driver, same as any other
--      direct assignment.
--
--   2) "the delivery code should appear anytime, not only the first time" —
--      by original design the plaintext code is never stored, only a bcrypt
--      hash (delivery_code_hash), specifically so nobody with read access to
--      the app or database could look it up and fake a delivery confirmation
--      — the code's entire value as proof-of-delivery is that only the
--      customer's paper receipt has it. Storing it in plaintext on `orders`
--      itself would leak it through every `select("*")` in the app,
--      including the driver's own order page — which would defeat the
--      point (a driver could "confirm delivery" without the customer ever
--      reading them the code). Instead: the plaintext lives in a new table
--      with RLS enabled and zero policies (default-deny for every direct
--      client request), reachable only through a SECURITY DEFINER RPC that
--      checks is_owner_or_moderator() itself — so Owner/Moderator can look
--      it up whenever they need to (e.g. to remind a customer who lost
--      their receipt), and a driver or factory account still can never see
--      it, same as before.
--
--   3) "factory maps link with lat/lon, Leaflet" — profiles.address (0015)
--      was free text only, good enough for a Google Maps *search* link but
--      not precise, and not something a map component can plot a pin from.
--      Adds nullable lat/lng columns (only meaningful for role='factory',
--      same as address) so the frontend can show an exact-location Maps
--      link and a real Leaflet map/pin instead of a text search.

-- ---------- 1) driver assignment at order creation ----------

drop function if exists public.create_order_internal(text, text, text, uuid, integer, text, text, text, text, order_source, uuid, uuid);
drop function if exists public.moderator_create_order(text, text, text, uuid, integer, text, text, text, text, uuid);

create or replace function public.create_order_internal(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text,
  p_color text,
  p_work_required text,
  p_customer_notes text,
  p_source order_source,
  p_created_by uuid,
  p_factory_id uuid default null,
  p_driver_id uuid default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := public.generate_delivery_code();
  v_order public.orders;
  v_result public.new_order_result;
  v_factory public.profiles;
  v_driver public.profiles;
  v_new_status public.order_status;
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

  if p_factory_id is not null then
    select * into v_factory from public.profiles where id = p_factory_id;
    if v_factory is null or v_factory.role <> 'factory' or not v_factory.is_active then
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
    customer_name, customer_phone, customer_address, region_id,
    pieces_count, piece_details, color, work_required, customer_notes,
    source, created_by, delivery_code_hash, assigned_factory_id
  ) values (
    trim(p_customer_name), trim(p_customer_phone), trim(p_customer_address), p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    p_source, p_created_by, crypt(v_code, gen_salt('bf')), p_factory_id
  )
  returning * into v_order;

  insert into public.order_delivery_codes (order_id, code) values (v_order.id, v_code);

  perform public.log_order_event(v_order.id, 'created', null, 'new',
    'تم إنشاء الأوردر عبر ' || case when p_source = 'website' then 'الموقع' else 'Messenger' end);

  -- Same shortcut reassign_order_driver's direct-assignment path takes: a
  -- driver picked right at creation is assigned AND pre-approved in one
  -- step, so the order is immediately visible to them (see 0014) instead of
  -- waiting on a separate suggest/approve pass.
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
  end if;

  perform public.notify_role('owner', v_order.id, 'new_order', 'أوردر جديد ' || v_order.order_number,
    'تم استلام أوردر جديد من ' || v_order.customer_name);

  v_result.order_id := v_order.id;
  v_result.order_number := v_order.order_number;
  v_result.delivery_code := v_code;
  return v_result;
end;
$$;

revoke all on function public.create_order_internal from public, anon, authenticated;

-- public_create_order's signature/body is untouched — it already defaults
-- p_factory_id and now simply also defaults the new p_driver_id (via
-- create_order_internal's own default) to null; anonymous website orders
-- were retired to a redirect-to-login anyway (see src/app/order/new), so
-- there's no path that would ever want to pass one.

create or replace function public.moderator_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null,
  p_factory_id uuid default null,
  p_driver_id uuid default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح لك بإنشاء أوردر' using errcode = '42501';
  end if;

  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'messenger', auth.uid(), p_factory_id, p_driver_id
  );
end;
$$;

revoke all on function public.moderator_create_order from public;
grant execute on function public.moderator_create_order to authenticated;

-- ---------- 2) delivery code, viewable on demand (Owner/Moderator only) ----------

create table if not exists public.order_delivery_codes (
  order_id uuid primary key references public.orders (id) on delete cascade,
  code text not null,
  created_at timestamptz not null default now()
);

comment on table public.order_delivery_codes is
  'Plaintext delivery codes, kept separately from orders (which is read via
   select("*") all over the app, including by drivers) so the code stays
   reachable only through get_order_delivery_code() below. RLS is enabled
   with no policies at all: every direct client request is denied by
   default, by design — the only legitimate path in is that function.';

alter table public.order_delivery_codes enable row level security;
revoke all on public.order_delivery_codes from public, anon, authenticated;

create or replace function public.get_order_delivery_code(p_order_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  -- null for any order created before this migration shipped — it was
  -- never captured in plaintext for those, only hashed (see 0004/0007).
  select code into v_code from public.order_delivery_codes where order_id = p_order_id;
  return v_code;
end;
$$;

revoke all on function public.get_order_delivery_code from public;
grant execute on function public.get_order_delivery_code to authenticated;

-- ---------- 3) factory geo-coordinates ----------

alter table public.profiles add column if not exists lat double precision;
alter table public.profiles add column if not exists lng double precision;

comment on column public.profiles.lat is 'Only meaningful for role=''factory'' — set alongside address, powers the precise Maps link and the Leaflet map/pin. Null means no pin yet (falls back to a text-address Maps search).';
comment on column public.profiles.lng is 'See profiles.lat.';

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, phone, role, address, lat, lng)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.email, 'مستخدم جديد'),
    new.raw_user_meta_data ->> 'phone',
    coalesce((new.raw_user_meta_data ->> 'role')::user_role, 'driver'),
    new.raw_user_meta_data ->> 'address',
    nullif(new.raw_user_meta_data ->> 'lat', '')::double precision,
    nullif(new.raw_user_meta_data ->> 'lng', '')::double precision
  )
  on conflict (id) do nothing;
  return new;
end;
$$;


-- ========== supabase/migrations/0017_track_order_setof_return.sql =====

-- 0017_track_order_setof_and_manager_label.sql
--
-- "order tracking is very bad" — track_order() already required both the
-- order number AND the phone to match (verified again below), and the
-- frontend already has a distinct "لا يوجد أوردر بهذه البيانات" state for
-- no-match. But track_order returns a single composite row (not SETOF),
-- and a composite-returning function that returns SQL NULL is a known thin
-- spot for PostgREST/supabase-js: depending on version it can come back as
-- a genuine JSON `null` (handled fine) or as an object with every field
-- null (NOT handled — the frontend would treat that as "order found" and
-- render a blank/broken result instead of the no-match message). Local SQL
-- testing against Postgres directly — how this was verified before — can't
-- catch that, because it never goes through PostgREST's serialization at
-- all. Switching to `setof` is the standard, unambiguous fix for "zero or
-- one row" RPCs under PostgREST: no match is always a plain empty array,
-- a match is always a one-element array, never a shape that could be
-- mistaken for a found order. src/lib/actions/orders.ts's trackOrderAction
-- is updated to match (data[0] ?? null instead of data ?? null).

drop function if exists public.track_order(text, text);

create or replace function public.track_order(p_order_number text, p_phone text)
returns setof public.tracked_order
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_result public.tracked_order;
  v_digits_input text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  -- Both the order number AND the phone's last 8 digits must match the same
  -- row — this was already an AND, not an OR; unchanged here.
  select * into v_order
  from public.orders o
  where upper(o.order_number) = upper(trim(coalesce(p_order_number, '')))
    and right(regexp_replace(o.customer_phone, '\D', '', 'g'), 8) = right(v_digits_input, 8)
  limit 1;

  if v_order is null then
    return; -- zero rows — an unambiguous "not found" over the wire
  end if;

  v_result.order_number := v_order.order_number;
  v_result.status := v_order.status;
  v_result.pieces_count := v_order.pieces_count;
  v_result.created_at := v_order.created_at;
  v_result.collected_at := v_order.collected_at;
  v_result.factory_received_at := v_order.factory_received_at;
  v_result.factory_ready_at := v_order.factory_ready_at;
  v_result.driver_pickup_at := v_order.driver_pickup_at;
  v_result.delivered_at := v_order.delivered_at;
  v_result.refused_at := v_order.refused_at;
  v_result.is_delayed := public.is_order_delayed(v_order);
  return next v_result;
end;
$$;

revoke all on function public.track_order from public;
grant execute on function public.track_order to anon, authenticated;


-- ========== supabase/migrations/0018_factory_reassignment_delivery_codes_and_chat.sql 

-- 0018_factory_reassignment_delivery_codes_and_chat.sql
--
-- Three independent additions, all requested together:
--
--   1) reassign_order_factory() — the factory routed to an order was only
--      ever settable once, at creation (0014/0016). Owner/Moderator can now
--      change it at any point before the order closes, mirroring
--      reassign_order_driver() exactly (same validation shape, same
--      "already assigned" guard, same terminal-status guard). The assigned
--      driver is notified so they know the pickup/drop-off location changed
--      — the location itself needs no separate propagation: every place
--      that shows it (driver order page, owner/moderator order detail) reads
--      assigned_factory_id fresh on each request, so a driver who reloads
--      always sees the new factory the moment this commits.
--
--   2) get_order_delivery_codes() — a batch counterpart to
--      get_order_delivery_code() (0016) so the orders list can show every
--      row's code without firing one RPC per row. Same authorization
--      (Owner/Moderator only), same underlying table.
--
--   3) Per-order chat between the assigned driver and Owner/Moderator —
--      order_messages table + send_order_message() RPC. Reads go straight
--      through RLS (same pattern as notifications/orders/order_history);
--      writes are forced through the RPC so sender_id/sender_role can never
--      be spoofed by a client, and so the other side gets notified the same
--      way every other cross-role event already does (notify_user/notify_role).
--      Factory accounts are deliberately not part of this — the request was
--      specifically "drivers and MODs and Manager and vice versa".

-- ---------- 1) factory reassignment ----------

create or replace function public.reassign_order_factory(p_order_id uuid, p_new_factory_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_new_factory public.profiles;
  v_old_factory_name text;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status in ('delivered', 'cancelled', 'refused') then
    raise exception 'لا يمكن تغيير المصنع لأوردر منتهٍ';
  end if;

  select * into v_new_factory from public.profiles where id = p_new_factory_id;
  if v_new_factory is null or v_new_factory.role <> 'factory' or not v_new_factory.is_active then
    raise exception 'المصنع المحدد غير صالح';
  end if;
  if v_order.assigned_factory_id = p_new_factory_id then
    raise exception 'هذا المصنع مخصص للأوردر بالفعل';
  end if;

  if v_order.assigned_factory_id is not null then
    select full_name into v_old_factory_name from public.profiles where id = v_order.assigned_factory_id;
  end if;

  update public.orders set assigned_factory_id = p_new_factory_id where id = p_order_id;

  perform public.log_order_event(p_order_id, 'factory_reassigned', v_order.status, v_order.status,
    case when v_old_factory_name is not null
      then 'تم تغيير المصنع من ' || v_old_factory_name || ' إلى ' || v_new_factory.full_name
      else 'تم تحديد المصنع: ' || v_new_factory.full_name
    end);

  -- The driver's own screen reads assigned_factory_id fresh every time, so
  -- nothing else needs updating for them to see the new location — this is
  -- purely to make sure they notice the change happened at all.
  if v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'factory_reassigned',
      'تم تغيير المصنع الخاص بالأوردر ' || v_order.order_number,
      'المصنع الجديد: ' || v_new_factory.full_name);
  end if;

  -- Let the newly assigned factory know an order was routed to them, same
  -- as they'd see it appear on their dashboard — only meaningful once the
  -- order has actually reached the factory-handling stage.
  if v_order.status in ('collected', 'at_factory', 'ready') then
    perform public.notify_user(p_new_factory_id, p_order_id, 'order_assigned',
      'تم تخصيص أوردر لمصنعكم ' || v_order.order_number, null);
  end if;
end;
$$;

revoke all on function public.reassign_order_factory from public;
grant execute on function public.reassign_order_factory to authenticated;

-- ---------- 2) batch delivery-code lookup ----------

create or replace function public.get_order_delivery_codes(p_order_ids uuid[])
returns table (order_id uuid, code text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  return query
    select c.order_id, c.code
    from public.order_delivery_codes c
    where c.order_id = any (p_order_ids);
end;
$$;

revoke all on function public.get_order_delivery_codes from public;
grant execute on function public.get_order_delivery_codes to authenticated;

-- ---------- 3) per-order chat ----------

create table if not exists public.order_messages (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  sender_id uuid not null references public.profiles (id),
  sender_role user_role not null,
  body text not null,
  created_at timestamptz not null default now()
);

create index if not exists order_messages_order_idx on public.order_messages (order_id, created_at);

alter table public.order_messages enable row level security;
revoke all on public.order_messages from public, anon, authenticated;

-- Reads go straight through RLS, same as orders/order_history/notifications
-- — no RPC needed for this side, just the standard "am I allowed to see
-- this order" check plus the driver's own narrower case.
create policy order_messages_select on public.order_messages
  for select using (
    public.is_owner_or_moderator()
    or exists (
      select 1 from public.orders o
      where o.id = order_messages.order_id
        and o.assigned_driver_id = auth.uid()
    )
  );

grant select on public.order_messages to authenticated;

-- Writes always go through this RPC — sender_id/sender_role come from the
-- verified session, never from client input, and the other side is always
-- notified the same way every other cross-role event already is.
create or replace function public.send_order_message(p_order_id uuid, p_body text)
returns public.order_messages
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_role user_role := public.current_user_role();
  v_body text := trim(coalesce(p_body, ''));
  v_row public.order_messages;
begin
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
    public.is_owner_or_moderator()
    or (v_role = 'driver' and v_order.assigned_driver_id = auth.uid())
  ) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  insert into public.order_messages (order_id, sender_id, sender_role, body)
  values (p_order_id, auth.uid(), v_role, v_body)
  returning * into v_row;

  if v_role = 'driver' then
    perform public.notify_role('owner', p_order_id, 'chat_message',
      'رسالة جديدة على الأوردر ' || v_order.order_number, v_body);
    perform public.notify_role('moderator', p_order_id, 'chat_message',
      'رسالة جديدة على الأوردر ' || v_order.order_number, v_body);
  elsif v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'chat_message',
      'رسالة جديدة على الأوردر ' || v_order.order_number, v_body);
  end if;

  return v_row;
end;
$$;

revoke all on function public.send_order_message from public;
grant execute on function public.send_order_message to authenticated;
