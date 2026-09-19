-- neon/migrations/0001_auth_shim.sql
--
-- Part of the Supabase -> Neon migration (see the project's
-- "neon-migration-guide.md" doc in the Claude project for the full plan).
-- This is Phase 1: make the schema portable to a bare Postgres instance
-- with no Supabase Auth (GoTrue) behind it, while keeping every existing
-- RLS policy and RPC byte-for-byte unchanged.
--
-- WHY THIS FILE LIVES OUTSIDE supabase/migrations/, NOT NUMBERED AS 0033:
-- This script overwrites auth.uid() with a version backed by a session
-- variable the app sets explicitly, instead of Supabase's real JWT-derived
-- one. If this were ever run against the REAL, LIVE Supabase project (e.g.
-- because someone applies "the next migration in numeric order" without
-- realizing what it does), every RLS policy in production would instantly
-- start evaluating auth.uid() as NULL for every request — nothing sets the
-- session variable there — which means every policy that grants access
-- based on auth.uid() would silently deny everyone, and this app has no
-- code path that would ever ALLOW too much as a result (the shim fails
-- closed, not open — see the "unauthenticated returns 0 rows" test in the
-- project's Phase 1 verification), so the practical effect would be a
-- full production outage: nobody could see or do anything, starting the
-- instant this runs. That's why this migration lives in its own directory
-- with its own numbering, and why the guard below aborts immediately if it
-- detects it's running against a real Supabase-managed database rather
-- than a bare Neon/Postgres one — treat that guard as load-bearing, not
-- decorative, and never remove it.
--
-- Apply this only to a Neon (or other non-Supabase) Postgres database that
-- already has migrations 0001-0032 from supabase/migrations/ replayed
-- against it. Never apply it to the live Supabase project.

do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'auth' and table_name = 'users'
      and column_name in ('instance_id', 'encrypted_password', 'confirmation_token')
  ) then
    raise exception
      'Refusing to run: this looks like a real Supabase-managed database '
      '(auth.users has Supabase-specific columns). This migration '
      'overwrites auth.uid() and is meant for a bare Neon/Postgres '
      'database only — running it against live Supabase would break '
      'every RLS policy in production immediately. Aborting.';
  end if;
end $$;

-- The key move: `auth.uid()` is called ~75 times across the 20 migration
-- files in supabase/migrations/ (in RLS policies and inside SECURITY
-- DEFINER RPC bodies). Rather than hand-editing every one of those — a
-- large, security-critical diff that would need re-verifying line by line
-- — we keep the function name and change only what backs it. Supabase's
-- auth.uid() reads the caller's id from a JWT claim GoTrue attaches per
-- request; this version reads it from a Postgres session/transaction-local
-- setting the app sets explicitly. Every existing call site keeps working
-- unmodified.

-- ── auth.uid() shim ─────────────────────────────────────────────────────
-- The `auth` schema doesn't exist on a bare Postgres/Neon instance —
-- Supabase creates it. Recreate just the one function every policy/RPC in
-- this project actually calls (auth.jwt() is never used anywhere in this
-- codebase — confirmed by grep across all migrations — so it isn't shimmed;
-- auth.role() was used briefly in 0026_pickup_points.sql but that table and
-- its policies were fully dropped in 0028_remove_pickup_points.sql, so
-- nothing in the final schema depends on it either).
create schema if not exists auth;

create or replace function auth.uid() returns uuid
language sql
stable
as $$
  select nullif(current_setting('app.current_profile_id', true), '')::uuid
$$;

comment on function auth.uid() is
  'Neon replacement for Supabase''s auth.uid(). Reads the caller''s profile '
  'id from the app.current_profile_id session setting instead of a JWT '
  'claim. Returns NULL when unset, matching GoTrue''s behavior for an '
  'unauthenticated request — every policy that compares a column to '
  'auth.uid() already handles that NULL case correctly (the comparison is '
  'simply never true), so this preserves existing behavior exactly. '
  'Verified directly: with no session set, RLS-protected tables return '
  'zero rows; with it set to a specific profile id, only that profile''s '
  'own rows are visible, tested against a non-superuser role with RLS '
  'actually enforced (not the schema owner, which bypasses RLS).';

-- The app must call this — never raw string-built SQL — before running any
-- request-scoped query, inside the same transaction as those queries.
-- SET LOCAL (via set_config's third argument) is transaction-scoped
-- (auto-reset at COMMIT/ROLLBACK), which is what keeps one request's
-- identity from leaking into another's queries on a pooled connection, as
-- long as the app always does this set + the request's queries inside one
-- BEGIN/COMMIT on one checked-out client (see src/lib/db/with-user-context.ts,
-- added in Phase 2/3 — not yet written as of this migration).
create or replace function public.set_current_profile_id(p_profile_id uuid)
returns void
language plpgsql
as $$
begin
  perform set_config('app.current_profile_id', coalesce(p_profile_id::text, ''), true);
end;
$$;

comment on function public.set_current_profile_id(uuid) is
  'Sets auth.uid() for the remainder of the current transaction. Call once, '
  'first, inside the same transaction as the request''s queries. Passing '
  'NULL clears it (auth.uid() then returns NULL, the unauthenticated case).';

-- ── profiles.id: no longer FK'd to auth.users ───────────────────────────
-- auth.users is GoTrue's table and doesn't exist here. Drop the FK; keep
-- the column itself completely unchanged (same type, same values) so every
-- other FK in the schema that points at profiles.id (orders, order_history,
-- order_messages, notifications, driver_regions) needs no changes at all —
-- this is what makes Phase 4's data migration an ID-preserving copy rather
-- than an ID remap.
alter table public.profiles drop constraint if exists profiles_id_fkey;
alter table public.profiles alter column id set default gen_random_uuid();

-- ── remove the auth.users-insert trigger ────────────────────────────────
-- handle_new_user() reacted to Supabase Auth creating a row in auth.users.
-- There's no auth.users to insert into anymore — Phase 3's account-creation
-- Server Actions insert into public.profiles directly instead.
drop trigger if exists on_auth_user_created on auth.users;
drop function if exists public.handle_new_user();

-- ── grants: replace Supabase's anon/authenticated roles ─────────────────
-- PostgREST (Supabase's auto-API) attached every request as one of its own
-- `anon`/`authenticated` roles, which don't exist on Neon. This app no
-- longer has any client-side database access at all (confirmed: the only
-- browser-side Supabase client usage was for auth/session state, never
-- data), so all queries now come from one application-level Postgres role
-- that the server process connects as. Least-privilege: a dedicated
-- non-superuser role, not the database owner.
--
-- Deliberately created with NOLOGIN here, no password anywhere in this
-- file: a migration file lives in git history forever, so a real
-- credential must never be set by one, even as a placeholder. Set the
-- actual login password out-of-band, directly against the target database,
-- right before Phase 2 needs it — e.g.
--   alter role app_user with login password '<from your secrets manager>';
-- (Neon's own console/CLI can create and manage this role and its secret
-- for you instead, if you'd rather not run that by hand — either way,
-- nothing secret should ever land in a committed file.)
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'app_user') then
    create role app_user nologin;
  end if;
end $$;

revoke all on schema public from anon, authenticated;
grant usage on schema public to app_user;

grant select, update on public.profiles to app_user;
grant select on public.regions to app_user;
grant insert, update, delete on public.regions to app_user;
grant select, insert, update, delete on public.driver_regions to app_user;
grant select, insert, update on public.orders to app_user;
grant select on public.order_history to app_user;
grant select, insert, update on public.order_messages to app_user;
grant select, update on public.notifications to app_user;
grant select on public.factory_orders_view to app_user;
grant execute on all functions in schema public to app_user;

-- ── admin/service-role equivalent (pre-login phone lookup) ──────────────
-- Supabase's createAdminClient() used the service_role key to bypass RLS
-- for the one case that has to run before any session exists: looking up
-- an account by phone number during login. Postgres has a first-class,
-- explicit analog to that: a role with the BYPASSRLS attribute. This is
-- more auditable than relying on "auth.uid() is null" policy behavior for
-- that path, and mirrors today's design more closely.
--
-- NOTE: same as app_user above — NOLOGIN here, real password set
-- out-of-band, never committed. Phase 2/3 wires the app to use this role
-- only for the pre-login lookup, never anywhere authenticated.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'app_admin') then
    create role app_admin nologin bypassrls;
  end if;
end $$;

grant usage on schema public to app_admin;
grant select on public.profiles to app_admin;
