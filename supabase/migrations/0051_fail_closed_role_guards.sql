-- 0051_fail_closed_role_guards.sql
--
-- Two holes in the authorization helpers that every other check in this
-- schema is built on. Both are closed here, in three function bodies,
-- rather than in the 49 places that call them.
--
-- APPLY THIS TO SUPABASE AS WELL AS NEON. It is a security fix, not a
-- migration artifact, and it changes nothing for a legitimate signed-in
-- user.
--
--
-- HOLE 1: `if not is_owner_or_moderator() then raise` DOES NOT RAISE FOR AN
-- UNAUTHENTICATED CALLER
--
-- is_owner_or_moderator() is `current_user_role() in ('owner','moderator')`.
-- With no session, auth.uid() is NULL, the subselect returns no row,
-- current_user_role() is NULL, and `NULL in (...)` is NULL — not false.
-- Then `not NULL` is NULL, and a plpgsql `if` on NULL takes neither branch.
-- The guard is skipped and the function body runs.
--
-- Measured on a replayed copy of this schema, as a non-superuser with no
-- identity set: orders_by_source_report(), dashboard_stats() and —
-- worst — get_order_delivery_codes() all ran and returned. That last one
-- hands out the codes a driver must quote to collect and to deliver.
--
-- 30 guards call is_owner_or_moderator() and 19 call is_owner(). All 49 had
-- this shape.
--
-- On Supabase this is currently masked: these functions are granted to
-- `authenticated` only, so an anonymous PostgREST request arrives as `anon`
-- and cannot execute them at all. The mask is real but it is one stray
-- grant away from failing, and it is the only thing standing there — the
-- function's own check contributes nothing. On a single-application-role
-- database (the Neon setup, where every request connects as app_user) the
-- mask does not exist and the hole is wide open.
--
-- The fix is to make the two boolean helpers return false rather than NULL.
-- Every one of the 49 guards then behaves as it was plainly written to.
--
--
-- HOLE 2: A DEACTIVATED ACCOUNT KEEPS FULL DATABASE AUTHORITY
--
-- current_user_role() reads the role with no regard for is_active, so
-- is_owner() stays true for a manager who has been switched off. The
-- application redirects them at the proxy, which is why this has never been
-- visible, but the database — the layer that is supposed to be the real
-- boundary — still answers yes.
--
-- That gap widens under a stateless session cookie, where deactivation
-- takes effect at the next cookie refresh rather than the next request. A
-- deactivated manager holding a live cookie would keep approving
-- distribution and reading delivery codes until it expired.
--
-- is_active is now part of the answer. A deactivated account resolves to
-- NULL — no role at all — which, with hole 1 closed, means every guard
-- refuses it.

-- ── the caller's role, only while their account is live ─────────────────

create or replace function public.current_user_role()
returns public.user_role
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles
   where id = auth.uid()
     -- Deactivating an account now removes its authority at the database,
     -- not only in the UI. Functions that need to distinguish "no such
     -- profile" from "switched off" read profiles directly and already do
     -- (see driver_create_field_order, which checks both explicitly).
     and is_active;
$$;

-- ── the two booleans every guard in the schema negates ──────────────────
--
-- coalesce is the whole fix. `select … in (…)` over zero rows is NULL, and
-- a NULL here is what let 49 guards fall open. These must answer false, not
-- "unknown", because every caller treats them as a yes/no decision.

create or replace function public.is_owner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.current_user_role() = 'owner', false);
$$;

create or replace function public.is_owner_or_moderator()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.current_user_role() in ('owner', 'moderator'), false);
$$;

-- Grants are unchanged from 0002; restated because CREATE OR REPLACE on a
-- function keeps its ACL, and being explicit here means this file can be
-- read on its own without having to go and check.
revoke all on function public.current_user_role() from public;
revoke all on function public.is_owner() from public;
revoke all on function public.is_owner_or_moderator() from public;

do $$
begin
  -- Supabase's PostgREST roles. Skipped on a database that does not have
  -- them, so this one file applies to both.
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.current_user_role() to authenticated';
    execute 'grant execute on function public.is_owner() to authenticated';
    execute 'grant execute on function public.is_owner_or_moderator() to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'app_user') then
    execute 'grant execute on function public.current_user_role() to app_user';
    execute 'grant execute on function public.is_owner() to app_user';
    execute 'grant execute on function public.is_owner_or_moderator() to app_user';
  end if;
end $$;

-- ── prove it, here, at apply time ───────────────────────────────────────
--
-- Not a test file somewhere else: this asserts the fix took, in the
-- transaction that applies it, against the database it is being applied to.
-- If a future edit reintroduces a NULL, this migration refuses to apply.
do $$
declare
  v_role_before public.user_role;
begin
  -- auth.uid() is NULL in this session: a migration runs with no app
  -- identity, which is exactly the unauthenticated case.
  select public.current_user_role() into v_role_before;

  if v_role_before is not null then
    raise exception
      'Expected current_user_role() to be NULL with no session, got %. '
      'This migration cannot verify itself — stopping.', v_role_before;
  end if;

  if public.is_owner() is not false then
    raise exception 'is_owner() must be false with no session, got %', public.is_owner();
  end if;
  if public.is_owner_or_moderator() is not false then
    raise exception 'is_owner_or_moderator() must be false with no session, got %',
      public.is_owner_or_moderator();
  end if;

  -- The actual thing that was broken: the guard shape used 49 times.
  if not public.is_owner_or_moderator() then
    raise notice 'verified: the `if not is_owner_or_moderator()` guard now fires with no session';
  else
    raise exception
      'The guard still does not fire with no session. All 49 authorization '
      'checks in this schema remain open. Refusing to apply.';
  end if;
end $$;
