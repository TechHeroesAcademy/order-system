-- ============================================================================
-- NEON SETUP — PART 6 OF 6
--
-- PASTE THIS WHOLE FILE INTO NEON'S SQL EDITOR AND RUN IT.
-- Run the parts in order. Wait for each to finish before starting the next.
-- Each part is safe to re-run: every statement is idempotent.
--
-- The Neon-specific part: replaces auth.uid(), removes the PostgREST roles,
-- and adds the password and login machinery that replaces GoTrue.
--
-- GENERATED — do not edit. Edit the source files listed below and re-run
-- scripts/build-neon-bundle.mjs, so Supabase and Neon cannot drift apart.
--
-- Contains, in order:
--    1. neon/migrations/0001_auth_shim.sql
--    2. neon/migrations/0002_local_auth.sql
-- ============================================================================

-- The chain installs pgcrypto/pg_trgm into the extensions schema (as Supabase
-- does) and several functions resolve against it. Declared per part rather
-- than relied on from the database default, so pasting a part into a fresh
-- editor session always works.
set search_path = public, extensions;



-- ========== neon/migrations/0001_auth_shim.sql ========================

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
-- already has 0000_prelude.sql applied and then EVERY migration in
-- supabase/migrations/ replayed against it (0001-0050 at the time of
-- writing -- stated as "every" rather than a fixed range on purpose: a
-- hardcoded number goes stale the next time a migration is added, and
-- silently under-applies the schema). Never apply it to the live Supabase
-- project.

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

-- Strip every privilege the PostgREST roles were granted by the chain, and
-- only if they exist at all: a bare `revoke ... from anon` against a
-- database without them fails outright and takes the rest of this file
-- with it.
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on schema public from %I', r);
      execute format('revoke all on all tables in schema public from %I', r);
      execute format('revoke all on all functions in schema public from %I', r);
      execute format('revoke all on all sequences in schema public from %I', r);
    end if;
  end loop;
end $$;

-- ── why `authenticated` SURVIVES, stripped bare ─────────────────────────
--
-- 20 of the 23 policies in this schema are written `to public`, so they
-- apply to whatever role connects. Four are not: factories_select,
-- manager_factories_select, push_subscriptions_select_own and
-- push_subscriptions_delete_own are scoped `to authenticated`, which was
-- invisible until the whole chain was replayed and queried as app_user.
--
-- A policy scoped to a role the connecting role is not a member of simply
-- does not apply, and with RLS on and no applicable policy the answer is
-- zero rows — no error, nothing in a log. The failure that was heading for
-- production: after cutover the team page lists no factories, order
-- creation cannot pick one (and a factory is mandatory), and the push
-- setup card shows no registered devices. It would have looked exactly
-- like the data had not copied across.
--
-- So `authenticated` is kept as a NOLOGIN role holding no privileges of its
-- own — everything it had was revoked above — and app_user is made a
-- member purely so those four policies apply to it. Nothing can
-- authenticate as it: no password is set for it here or anywhere.
--
-- The alternative was rewriting those four policies to `to public`. This is
-- better: supabase/migrations/ stays the single source of truth for both
-- databases, and a policy written `to authenticated` next month — the
-- normal thing to write against Supabase — keeps working here without
-- anyone remembering this.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
end $$;

-- `anon` and `service_role` get no such treatment. No policy is scoped to
-- anon, and the only things ever granted to it were public_create_order and
-- track_order; service_role was PostgREST's RLS bypass and is replaced by
-- the SECURITY DEFINER lookups described below. Dropped rather than left
-- lying around, so nothing can be granted back to them by accident.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    drop owned by anon;
    drop role anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    drop owned by service_role;
    drop role service_role;
  end if;
end $$;

grant usage on schema public to app_user;

grant select, update on public.profiles to app_user;
grant select, insert, update, delete on public.regions to app_user;
grant select, insert, update, delete on public.driver_regions to app_user;
grant select, insert, update on public.orders to app_user;
grant select on public.order_history to app_user;
grant select, insert, update on public.order_messages to app_user;
grant select, update on public.notifications to app_user;

-- The tables migrations 0033-0050 added. Without these the app comes up
-- after cutover and fails with "permission denied for table factories" on
-- the first page that lists a factory — which is the team page, the order
-- page and order creation. Measured against the live catalog rather than
-- guessed: these are exactly the tables app code reads directly
-- (src/lib/data/factories.ts, src/lib/data/staff.ts, and the push dispatch
-- route) and that this file did not previously cover.
grant select, insert, update, delete on public.factories to app_user;
grant select on public.manager_factories to app_user;
grant select, insert, update, delete on public.push_subscriptions to app_user;

-- Deliberately NOT granted, and this is the security property rather than
-- an omission: order_delivery_codes, order_pickup_codes, app_settings and
-- push_outbox have row level security on with zero policies, so even a
-- correct session reaches them only through a SECURITY DEFINER function
-- that decides what to reveal. Verified as app_user with an authenticated
-- identity set: a direct select on any of them raises 42501.
--
-- factory_orders_view, which an earlier version of this file granted, was
-- dropped in migration 0038 when factories stopped being accounts. The
-- grant aborted this entire file against any schema past 0038 — found by
-- replaying the real chain rather than by reading it.

grant execute on all functions in schema public to app_user;

-- Membership, not privilege: see the note above. This is what makes the
-- four `to authenticated` policies apply to the role the app connects as.
grant authenticated to app_user;

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
-- NOTE ON BYPASSRLS AND NEON: Neon's owner role is a member of
-- neon_superuser, which holds BYPASSRLS, but Postgres role attributes are
-- not inherited through membership, and from PG16 a CREATEROLE role may
-- only grant BYPASSRLS if it holds that attribute itself. So this CREATE
-- may be refused on Neon. Check before relying on it:
--
--   select rolcreaterole, rolbypassrls from pg_roles
--    where rolname = current_user;
--
-- It does not matter much either way, because the design below does not
-- need it: the pre-login lookups go through a SECURITY DEFINER function
-- owned by the tables' owner, which already sees past RLS for the duration
-- of the call and reveals only what it returns. That is strictly less
-- privilege than a role that bypasses RLS on everything, so prefer it even
-- where BYPASSRLS is available. app_admin is kept as a narrow fallback.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'app_admin') then
    begin
      create role app_admin nologin bypassrls;
    exception when insufficient_privilege or feature_not_supported then
      create role app_admin nologin;
      raise notice
        'app_admin created WITHOUT bypassrls (this database would not grant '
        'it). Use SECURITY DEFINER lookup functions for the pre-login path; '
        'see the migration guide.';
    end;
  end if;
end $$;

grant usage on schema public to app_admin;
grant select on public.profiles to app_admin;


-- ========== neon/migrations/0002_local_auth.sql =======================

-- neon/migrations/0002_local_auth.sql
--
-- Apply AFTER 0001_auth_shim.sql, on a bare Neon/Postgres database only.
--
-- Accounts and passwords, now that GoTrue is gone. 0001 removed the FK to
-- auth.users and the trigger that created a profile when GoTrue created a
-- user; this adds the thing that replaces them.
--
-- THE SECURITY DECISIONS HERE, AND WHY
--
-- 1. Hashes live in their own table with RLS on and ZERO policies, not in
--    profiles. profiles is readable by every staff member — profiles_select_staff
--    exists so the team page works — so a password_hash column on it would be
--    readable by any moderator, and by any driver for their own row. A table
--    with RLS and no policies is reachable only through a SECURITY DEFINER
--    function that decides what to return, which is the same pattern
--    order_delivery_codes and app_settings already use in this schema.
--
-- 2. The hash never leaves the database. bcrypt runs inside Postgres via
--    pgcrypto's crypt(), so the application compares nothing and stores
--    nothing: it sends a phone number and a password over TLS and gets back
--    a status. A compromised application process cannot walk away with a
--    password-hash dump, because it never had one. (The plaintext crosses
--    the wire to Postgres, which is the same trust boundary as sending it
--    to GoTrue was.)
--
-- 3. Login is throttled. GoTrue did its own rate limiting, and nothing
--    would have replaced it — leaving a 6-character password behind an
--    endpoint that could be hammered. Failures are counted per account and
--    the account locks, with a longer lock the more it is hammered.
--
-- 4. Nothing here raises on a bad password. A plpgsql exception rolls the
--    transaction back, which would roll back the failed-attempt counter
--    with it and make the throttle useless — the attacker's own wrong
--    guesses would erase the evidence of them. So these functions return a
--    status row instead, and the increment commits.
--
-- 5. An unknown phone number and a wrong password return the identical
--    status. The caller cannot tell them apart, so this endpoint does not
--    answer "is this number one of your staff".

create extension if not exists pgcrypto with schema extensions;

-- ── one canonical form for a phone number ───────────────────────────────
--
-- A phone number is the login here, so "the same number written two ways"
-- has to mean one account. Digits-only is not enough: +20 100 111 2222 and
-- 01001112222 are the same Egyptian mobile and reduce to 201001112222 and
-- 01001112222, which do not match. Caught by typing the international form
-- during testing — it returned bad_credentials for the correct password.
--
-- Deliberately NOT the last-8-digits rule the order-matching uses. That rule
-- is right for "have we served this customer before", where a false match
-- costs a wrong hint. It is wrong for a login, where a false match costs an
-- account: two numbers in different countries can share eight digits.
-- Dropping a recognised Egyptian country code is exact, not fuzzy.
create or replace function public.canonical_phone(p_phone text)
returns text
language plpgsql
immutable
as $$
declare
  v text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  -- 00 20 ... — international prefix dialled out
  if left(v, 4) = '0020' and length(v) >= 12 then
    v := substr(v, 5);
  -- 20 ... — the +20 form with the plus stripped. Length-guarded: an
  -- 11-digit local number could never start with 20 (they start 01), but a
  -- 12-digit one starting 20 is the country code.
  elsif left(v, 2) = '20' and length(v) = 12 then
    v := substr(v, 3);
  end if;

  -- Back to the local form everyone writes and reads.
  if length(v) > 0 and left(v, 1) <> '0' then
    v := '0' || v;
  end if;

  return v;
end;
$$;

revoke all on function public.canonical_phone(text) from public;
grant execute on function public.canonical_phone(text) to app_user;

-- Two accounts can no longer hold the same number in different notations.
-- The functions below also check for a taken phone, but a check inside a
-- function races against a second request doing the same check; a unique
-- index does not.
create unique index if not exists profiles_canonical_phone_key
  on public.profiles (public.canonical_phone(phone))
  where phone is not null;

-- ── where hashes live ───────────────────────────────────────────────────

create table if not exists public.user_credentials (
  profile_id uuid primary key references public.profiles (id) on delete cascade,
  -- Null until the worker sets their own password at first login. A manager
  -- never types or sees a password: they create the account, and the worker
  -- chooses the password themselves. There is no point in the lifecycle at
  -- which a plaintext password exists anywhere but the login form.
  password_hash text,
  failed_attempts integer not null default 0,
  locked_until timestamptz,
  last_login_at timestamptz,
  password_changed_at timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.user_credentials enable row level security;

-- No policies, by design. With RLS on and no policy, every ordinary session
-- gets zero rows and every write is refused — including the owner's. The
-- only way in is the SECURITY DEFINER functions below.
revoke all on table public.user_credentials from public;

comment on table public.user_credentials is
  'Password hashes and login throttling state. RLS on with zero policies: '
  'unreachable except through the auth_* SECURITY DEFINER functions. Kept '
  'out of profiles because profiles is readable by all staff.';

-- ── the throttle ────────────────────────────────────────────────────────

create or replace function public.auth_lockout_for(p_attempts integer)
returns interval
language sql
immutable
as $$
  -- Nothing for the first four — people mistype their own password, and
  -- locking them out of their own work on a typo is its own outage. Then it
  -- escalates sharply, because by the tenth wrong guess in a row this is no
  -- longer someone who forgot.
  select case
    when p_attempts >= 20 then interval '24 hours'
    when p_attempts >= 10 then interval '1 hour'
    when p_attempts >= 5  then interval '5 minutes'
    else interval '0'
  end;
$$;

-- ── step 1 of login: does this number need to choose a password ──────────
--
-- The two-step phone login needs to know whether to show "enter your
-- password" or "choose a password". That is a real product requirement, and
-- it is also the one place this system admits that a phone number belongs to
-- a staff account.
--
-- Kept, with the tradeoff stated rather than hidden: someone who already has
-- a staff member's mobile number can confirm they work here. They cannot
-- learn the name, the role, or anything else, and they still cannot get in.
-- Closing it entirely would mean dropping the two-step flow and asking every
-- worker to know in advance whether they have a password yet, which trades a
-- small disclosure for a support call every time someone joins.
create or replace function public.auth_begin_login(p_phone text)
returns table (needs_password_setup boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text := public.canonical_phone(p_phone);
begin
  if length(v_phone) < 8 then
    return; -- not a phone number; nothing to say about it
  end if;

  return query
    select c.password_hash is null
      from public.profiles p
      left join public.user_credentials c on c.profile_id = p.id
     where public.canonical_phone(p.phone) = v_phone
       and p.is_active
     limit 1;
end;
$$;

-- ── step 2a: first login, the worker chooses their password ─────────────

create or replace function public.auth_set_initial_password(
  p_phone text,
  p_password text
)
returns table (status text, profile_id uuid, role public.user_role, full_name text)
language plpgsql
security definer
set search_path = public
as $$
-- RETURNS TABLE turns every output column into a plpgsql variable, so
-- `profile_id` here means two things: this function's output column and
-- user_credentials' primary key. Postgres refuses the statement at RUN time
-- rather than at CREATE time, so it looks fine until someone actually logs
-- in for the first time — which is how it was found. This directive tells
-- plpgsql that inside SQL statements a name that matches a column IS the
-- column, which is what every statement in this body means.
#variable_conflict use_column
declare
  v_phone text := public.canonical_phone(p_phone);
  v_p record;
begin
  -- Length is re-checked here and not only in the form. This function is
  -- the boundary; a caller that skipped validation must not be able to set
  -- a one-character password.
  if length(coalesce(p_password, '')) < 6 then
    return query select 'weak_password'::text, null::uuid, null::public.user_role, null::text;
    return;
  end if;

  select p.id, p.role, p.full_name, c.password_hash
    into v_p
    from public.profiles p
    left join public.user_credentials c on c.profile_id = p.id
   where public.canonical_phone(p.phone) = v_phone
     and p.is_active
   limit 1;

  if v_p.id is null then
    return query select 'not_found'::text, null::uuid, null::public.user_role, null::text;
    return;
  end if;

  -- Already chosen. Without this check, anyone holding a staff member's
  -- phone number could overwrite their password and take the account —
  -- which would make this the most dangerous function in the system rather
  -- than the most ordinary one.
  if v_p.password_hash is not null then
    return query select 'already_set'::text, null::uuid, null::public.user_role, null::text;
    return;
  end if;

  -- Cost 10, matching what GoTrue used, so a hash made before the migration
  -- and one made after cost the same to verify. Raising it is a one-line
  -- change here and costs database CPU on every login.
  insert into public.user_credentials (profile_id, password_hash, password_changed_at, last_login_at)
  values (v_p.id, extensions.crypt(p_password, extensions.gen_salt('bf', 10)), now(), now())
  on conflict (profile_id) do update
    set password_hash = excluded.password_hash,
        password_changed_at = now(),
        last_login_at = now(),
        failed_attempts = 0,
        locked_until = null,
        updated_at = now();

  update public.profiles set password_set = true where id = v_p.id;

  return query select 'ok'::text, v_p.id, v_p.role, v_p.full_name;
end;
$$;

-- ── step 2b: returning login ────────────────────────────────────────────

create or replace function public.auth_verify_login(
  p_phone text,
  p_password text
)
returns table (
  status text,
  profile_id uuid,
  role public.user_role,
  full_name text,
  retry_after_seconds integer
)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_phone text := public.canonical_phone(p_phone);
  v_p record;
  v_lock interval;
begin
  select p.id, p.role, p.full_name, p.is_active,
         c.password_hash, c.failed_attempts, c.locked_until
    into v_p
    from public.profiles p
    left join public.user_credentials c on c.profile_id = p.id
   where public.canonical_phone(p.phone) = v_phone
   limit 1;

  -- An unknown number, a deactivated account and an account with no
  -- password yet are told apart only where the caller needs to act
  -- differently. An unknown number and a wrong password are deliberately
  -- the same answer.
  if v_p.id is null then
    return query select 'bad_credentials'::text, null::uuid, null::public.user_role, null::text, null::integer;
    return;
  end if;
  if not v_p.is_active then
    return query select 'inactive'::text, null::uuid, null::public.user_role, null::text, null::integer;
    return;
  end if;
  if v_p.password_hash is null then
    return query select 'needs_setup'::text, null::uuid, null::public.user_role, null::text, null::integer;
    return;
  end if;

  -- Locked. Checked before the hash is computed, so a locked account costs
  -- an attacker a cheap query rather than making us do bcrypt work for them.
  if v_p.locked_until is not null and v_p.locked_until > now() then
    return query select 'locked'::text, null::uuid, null::public.user_role, null::text,
                        ceil(extract(epoch from (v_p.locked_until - now())))::integer;
    return;
  end if;

  -- crypt() re-hashes the supplied password with the salt embedded in the
  -- stored hash and compares. Constant-time inside pgcrypto, and the hash
  -- itself never leaves this function.
  if v_p.password_hash = extensions.crypt(coalesce(p_password, ''), v_p.password_hash) then
    -- Aliased: this function's RETURNS TABLE declares an OUT variable
    -- named profile_id, which makes a bare `where profile_id = ...` here
    -- ambiguous and fails at runtime, not at creation time. Caught by
    -- actually logging in during testing rather than by reading it.
    update public.user_credentials c
       set failed_attempts = 0, locked_until = null, last_login_at = now(), updated_at = now()
     where c.profile_id = v_p.id;
    return query select 'ok'::text, v_p.id, v_p.role, v_p.full_name, null::integer;
    return;
  end if;

  -- Wrong password. The counter is incremented and RETURNED, not raised —
  -- see note 4 in the header. A raise here would roll this update back and
  -- the throttle would never fire.
  v_lock := public.auth_lockout_for(v_p.failed_attempts + 1);
  update public.user_credentials c
     set failed_attempts = c.failed_attempts + 1,
         locked_until = case when v_lock > interval '0' then now() + v_lock else c.locked_until end,
         updated_at = now()
   where c.profile_id = v_p.id;

  if v_lock > interval '0' then
    return query select 'locked'::text, null::uuid, null::public.user_role, null::text,
                        ceil(extract(epoch from v_lock))::integer;
  else
    return query select 'bad_credentials'::text, null::uuid, null::public.user_role, null::text, null::integer;
  end if;
end;
$$;

-- ── the first owner ─────────────────────────────────────────────────────
--
-- Runs with no session at all — there is nobody to authorise it, which is
-- the whole point of a bootstrap. The guard is the state of the database
-- rather than the caller's role: it works exactly once, while no owner
-- exists, and refuses forever after.
--
-- The `for update` on the existence check is what makes "exactly once" true
-- under two simultaneous requests rather than usually true.
create or replace function public.bootstrap_owner(
  p_full_name text,
  p_phone text,
  p_password text
)
returns table (status text, profile_id uuid)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_phone text := public.canonical_phone(p_phone);
  v_id uuid;
begin
  if length(coalesce(p_password, '')) < 6 then
    return query select 'weak_password'::text, null::uuid; return;
  end if;
  if length(trim(coalesce(p_full_name, ''))) < 2 then
    return query select 'invalid_name'::text, null::uuid; return;
  end if;
  if length(v_phone) < 8 then
    return query select 'invalid_phone'::text, null::uuid; return;
  end if;

  -- Serialises two concurrent bootstraps: the second waits, then sees the
  -- first owner and refuses.
  perform 1 from public.profiles where role = 'owner' for update;
  if exists (select 1 from public.profiles where role = 'owner') then
    return query select 'already_set_up'::text, null::uuid; return;
  end if;

  if exists (
    select 1 from public.profiles
     where public.canonical_phone(phone) = v_phone
  ) then
    return query select 'phone_taken'::text, null::uuid; return;
  end if;

  insert into public.profiles (full_name, phone, role, is_active, password_set)
  values (trim(p_full_name), v_phone, 'owner', true, true)
  returning id into v_id;

  insert into public.user_credentials (profile_id, password_hash, password_changed_at, last_login_at)
  values (v_id, extensions.crypt(p_password, extensions.gen_salt('bf', 10)), now(), now());

  return query select 'ok'::text, v_id;
end;
$$;

-- ── staff accounts ──────────────────────────────────────────────────────
--
-- Replaces the createUser call the application used to make against GoTrue
-- with the service-role key. Same shape, one difference worth stating: no
-- password is created. The credentials row is inserted with a null hash, so
-- the worker chooses their own at first login through
-- auth_set_initial_password. There is no temporary password to leak, to
-- send over WhatsApp, or to forget to change.
create or replace function public.create_staff_account(
  p_full_name text,
  p_phone text,
  p_role public.user_role,
  p_region_names text[] default '{}'
)
returns table (status text, profile_id uuid)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_phone text := public.canonical_phone(p_phone);
  v_id uuid;
  v_region_id uuid;
  v_name text;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  -- 'factory' stopped being an account in migration 0033. The enum value
  -- survives for historical order_history rows; nothing may create one.
  if p_role not in ('owner', 'moderator', 'driver') then
    return query select 'invalid_role'::text, null::uuid; return;
  end if;
  if length(trim(coalesce(p_full_name, ''))) < 2 then
    return query select 'invalid_name'::text, null::uuid; return;
  end if;
  if length(v_phone) < 8 then
    return query select 'invalid_phone'::text, null::uuid; return;
  end if;

  if exists (
    select 1 from public.profiles
     where public.canonical_phone(phone) = v_phone
  ) then
    return query select 'phone_taken'::text, null::uuid; return;
  end if;

  insert into public.profiles (full_name, phone, role, is_active, password_set)
  values (trim(p_full_name), v_phone, p_role, true, false)
  returning id into v_id;

  -- No hash: the worker sets it themselves at first login.
  insert into public.user_credentials (profile_id) values (v_id);

  -- Typed area names resolved through the same find_or_create_region() every
  -- other entry point uses (migration 0025), so a name typed here and the
  -- same name typed on an order resolve to one canonical row.
  if p_role = 'driver' and p_region_names is not null then
    foreach v_name in array p_region_names loop
      if length(trim(coalesce(v_name, ''))) >= 2 then
        v_region_id := public.find_or_create_region(v_name);
        insert into public.driver_regions (driver_id, region_id)
        values (v_id, v_region_id)
        on conflict do nothing;
      end if;
    end loop;
  end if;

  return query select 'ok'::text, v_id;
end;
$$;

-- ── password reset, by a manager ─────────────────────────────────────────
--
-- Clears the hash rather than setting a new one, which puts the account back
-- into the same state a brand-new one is in: the worker chooses a password at
-- their next login. A manager never knows a worker's password, before or
-- after a reset.
--
-- Also clears the lockout, so this doubles as "unlock this account".
create or replace function public.auth_reset_password(p_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if p_profile_id is null then
    raise exception 'حساب غير معروف' using errcode = '22023';
  end if;

  insert into public.user_credentials (profile_id, password_hash, failed_attempts, locked_until, updated_at)
  values (p_profile_id, null, 0, null, now())
  on conflict (profile_id) do update
    set password_hash = null, failed_attempts = 0, locked_until = null, updated_at = now();

  update public.profiles set password_set = false where id = p_profile_id;
end;
$$;

-- ── deleting an account ─────────────────────────────────────────────────
--
-- The last step of the removal sequence the application already follows:
-- deactivate, reassign the driver's live orders, then delete. Only the
-- delete needed a new home — it used to be GoTrue's deleteUser.
--
-- Credentials cascade from profiles. The order-side foreign keys are ON
-- DELETE SET NULL (migration 0032), and the snapshot name columns mean the
-- orders this person touched still read correctly afterwards.
create or replace function public.delete_staff_profile(p_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role public.user_role;
begin
  if not public.is_owner() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select role into v_role from public.profiles where id = p_profile_id;
  if v_role is null then
    raise exception 'حساب غير معروف' using errcode = '22023';
  end if;

  -- Refuses to leave the system with no way in. Without this, deleting the
  -- last owner is a lockout that only a database console can undo.
  if v_role = 'owner' and (
    select count(*) from public.profiles where role = 'owner' and is_active
  ) <= 1 then
    raise exception 'لا يمكن حذف المدير الوحيد في النظام' using errcode = 'P0001';
  end if;

  if p_profile_id = auth.uid() then
    raise exception 'لا يمكنك حذف حسابك بنفسك' using errcode = 'P0001';
  end if;

  delete from public.profiles where id = p_profile_id;
end;
$$;

-- ── grants ──────────────────────────────────────────────────────────────
--
-- The three pre-login functions are the only ones an unauthenticated
-- request can reach, and each one is narrow: ask whether a number needs a
-- password, set one if it has none, or exchange a password for an identity.
-- None of them returns anything about an account it did not authenticate.
--
-- This is what replaces Supabase's service-role key. There is no role here
-- that bypasses RLS on everything; there are five functions that each see
-- past it for one specific purpose and return one specific shape.

revoke all on function public.auth_begin_login(text) from public;
revoke all on function public.auth_set_initial_password(text, text) from public;
revoke all on function public.auth_verify_login(text, text) from public;
revoke all on function public.bootstrap_owner(text, text, text) from public;
revoke all on function public.create_staff_account(text, text, public.user_role, text[]) from public;
revoke all on function public.auth_reset_password(uuid) from public;
revoke all on function public.delete_staff_profile(uuid) from public;
revoke all on function public.auth_lockout_for(integer) from public;

grant execute on function public.auth_begin_login(text) to app_user;
grant execute on function public.auth_set_initial_password(text, text) to app_user;
grant execute on function public.auth_verify_login(text, text) to app_user;
grant execute on function public.bootstrap_owner(text, text, text) to app_user;
grant execute on function public.create_staff_account(text, text, public.user_role, text[]) to app_user;
grant execute on function public.auth_reset_password(uuid) to app_user;
grant execute on function public.delete_staff_profile(uuid) to app_user;

-- ── backfill, for a database that already has profiles ──────────────────
--
-- A fresh system has none and this does nothing. It matters only if accounts
-- were imported from Supabase: every profile gets a credentials row, with no
-- hash, so each person sets a password at their next login rather than being
-- locked out by a missing row.
insert into public.user_credentials (profile_id)
select p.id from public.profiles p
 where not exists (select 1 from public.user_credentials c where c.profile_id = p.id);

update public.profiles p
   set password_set = false
 where exists (
   select 1 from public.user_credentials c
    where c.profile_id = p.id and c.password_hash is null
 )
   and p.password_set;
