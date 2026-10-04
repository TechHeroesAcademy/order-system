-- verify_role_guards.sql — check that the authorization guards fail closed
--
-- Read-only. Deletes nothing, changes nothing, creates one temporary profile
-- inside a transaction it always rolls back. Safe to run on production, and
-- worth running there: this is where the bug was.
--
-- Paste into the Supabase SQL editor and run, or `psql -f` it against Neon.
-- Read the Messages / Notices tab. Every line should start with PASS.
--
--
-- WHAT IT IS CHECKING
--
-- 49 authorization checks in this schema have the shape
--
--     if not public.is_owner_or_moderator() then
--       raise exception 'غير مصرح' using errcode = '42501';
--     end if;
--
-- (30 of them) or the is_owner() equivalent (19). Each one is one line of
-- plpgsql and looks obviously correct. It was not: with no session,
-- auth.uid() is NULL, current_user_role() returned NULL, `NULL in (...)` is
-- NULL, `not NULL` is NULL, and a plpgsql `if` on NULL takes NEITHER branch.
-- The raise was skipped and the body ran.
--
-- Migration 0051 fixes it in the two helpers, which fixes all 49 at once —
-- so the thing to test is the helpers, not 49 call sites. A fiftieth guard
-- written tomorrow in the same shape is correct by construction.
--
-- It also checks the second half of 0051: that a DEACTIVATED account has no
-- role at the database. Before that change, switching a manager off removed
-- them from the UI but left is_owner() answering true for them.

do $$
declare
  v_role public.user_role;
  v_pass int := 0;
  v_fail int := 0;
begin
  raise notice '';
  raise notice '=== authorization guards: do they fail closed? ===';
  raise notice '';

  -- ── 1. no session at all ───────────────────────────────────────────────
  --
  -- A migration or SQL-editor session has no app identity, so auth.uid() is
  -- already NULL here. That is precisely the unauthenticated case.

  select public.current_user_role() into v_role;
  if v_role is null then
    raise notice 'PASS  current_user_role() is NULL with no session';
    v_pass := v_pass + 1;
  else
    raise warning 'FAIL  current_user_role() returned % with no session — expected NULL', v_role;
    v_fail := v_fail + 1;
  end if;

  -- The actual bug. `is false` rather than `= false` on purpose: a NULL
  -- would make `= false` itself NULL and this check would silently skip,
  -- which is the very mistake being tested for.
  if public.is_owner() is false then
    raise notice 'PASS  is_owner() is false (not NULL) with no session';
    v_pass := v_pass + 1;
  else
    raise warning 'FAIL  is_owner() returned % with no session — if it is NULL, all 19 is_owner() guards are open', public.is_owner();
    v_fail := v_fail + 1;
  end if;

  if public.is_owner_or_moderator() is false then
    raise notice 'PASS  is_owner_or_moderator() is false (not NULL) with no session';
    v_pass := v_pass + 1;
  else
    raise warning 'FAIL  is_owner_or_moderator() returned % — if NULL, all 30 guards using it are open', public.is_owner_or_moderator();
    v_fail := v_fail + 1;
  end if;

  -- The guard shape itself, exactly as the 49 call sites write it.
  if not public.is_owner_or_moderator() then
    raise notice 'PASS  the `if not is_owner_or_moderator()` guard fires with no session';
    v_pass := v_pass + 1;
  else
    raise warning 'FAIL  the guard did NOT fire with no session — all 49 authorization checks are bypassable';
    v_fail := v_fail + 1;
  end if;

  if not public.is_owner() then
    raise notice 'PASS  the `if not is_owner()` guard fires with no session';
    v_pass := v_pass + 1;
  else
    raise warning 'FAIL  the is_owner() guard did NOT fire with no session';
    v_fail := v_fail + 1;
  end if;

  raise notice '';
  raise notice '--- end to end: do real functions actually refuse? ---';

  -- Three real functions, chosen because they are the ones that mattered
  -- when this was measured. get_order_delivery_codes is the serious one: it
  -- returns the codes a driver quotes to collect from a customer and to
  -- prove delivery.
  begin
    perform * from public.dashboard_stats();
    raise warning 'FAIL  dashboard_stats() ran with no session';
    v_fail := v_fail + 1;
  exception when insufficient_privilege then
    raise notice 'PASS  dashboard_stats() refused';
    v_pass := v_pass + 1;
  end;

  begin
    perform * from public.orders_by_source_report();
    raise warning 'FAIL  orders_by_source_report() ran with no session';
    v_fail := v_fail + 1;
  exception when insufficient_privilege then
    raise notice 'PASS  orders_by_source_report() refused';
    v_pass := v_pass + 1;
  end;

  begin
    perform * from public.get_order_delivery_codes(array[]::uuid[]);
    raise warning 'FAIL  get_order_delivery_codes() ran with no session — THIS ONE HANDS OUT DELIVERY CODES';
    v_fail := v_fail + 1;
  exception when insufficient_privilege then
    raise notice 'PASS  get_order_delivery_codes() refused';
    v_pass := v_pass + 1;
  end;

  raise notice '';
  raise notice '--- summary: % passed, % failed ---', v_pass, v_fail;
  if v_fail > 0 then
    raise exception
      '% check(s) failed. Apply supabase/migrations/0051_fail_closed_role_guards.sql.', v_fail;
  end if;
  raise notice '';
end $$;

-- ── the deactivated-account half, which needs a profile to test with ────
--
-- Wrapped in a transaction that always rolls back, so the temporary owner it
-- creates never exists as far as the system is concerned. Separate from the
-- block above because it has to write.

begin;

do $$
declare
  v_id uuid := '00000000-dead-0000-0000-000000000001';
  v_has_authority boolean;
begin
  raise notice '=== does a DEACTIVATED account still have authority? ===';
  raise notice '';

  -- profiles.id references auth.users on Supabase, so insert the shell row
  -- there too when that table exists. On Neon the FK is gone (the shim drops
  -- it) and this is skipped.
  if to_regclass('auth.users') is not null then
    begin
      execute format('insert into auth.users (id) values (%L)', v_id);
    exception when others then
      raise notice 'SKIP  could not create a temporary auth.users row (%): '
                   'run this part on Neon, or ignore', sqlerrm;
      return;
    end;
  end if;

  insert into public.profiles (id, full_name, phone, role, is_active)
  values (v_id, 'حساب اختبار مؤقت', '09999999999', 'owner', true);

  -- Active owner: should have authority.
  perform set_config('request.jwt.claim.sub', v_id::text, true);
  perform set_config('app.current_profile_id', v_id::text, true);
  v_has_authority := public.is_owner();

  if v_has_authority then
    raise notice 'PASS  an ACTIVE owner has authority (the control case)';
  else
    raise warning 'FAIL  an active owner has NO authority — something is wrong beyond this fix';
  end if;

  -- Same account, switched off.
  update public.profiles set is_active = false where id = v_id;
  v_has_authority := public.is_owner();

  if v_has_authority is false then
    raise notice 'PASS  a DEACTIVATED owner has no authority at the database';
  else
    raise warning
      'FAIL  a deactivated owner still reports is_owner() = % — they keep '
      'approving distribution and reading delivery codes for as long as '
      'their session lives. Apply migration 0051.', v_has_authority;
  end if;

  raise notice '';
end $$;

-- Always. Nothing above is meant to survive.
rollback;
