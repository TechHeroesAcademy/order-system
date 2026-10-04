-- reset_all_data.sql — empty the system and start over
--
-- Deletes every account and every piece of operational data, leaving the
-- schema, the functions, the policies and the push configuration intact. The
-- result is the state a freshly deployed system is in before anyone has
-- signed up: /setup becomes available again and the first owner is created
-- there.
--
-- THIS IS NOT PART OF THE MIGRATION CHAIN. It lives in supabase/maintenance/
-- precisely so that nobody running "the next migration in numeric order"
-- ever runs it by accident.
--
-- WHAT IT DELETES
--   every login            auth.users -> profiles (cascade), and with them
--                          GoTrue's identities, sessions and refresh tokens
--   every order            orders, and its history, chat, and the two code
--                          tables
--   everything per-person  notifications, push devices, driver areas,
--                          manager-factory assignments
--   the typed lists        regions, factories
--   order numbering        reset, so the next order is ORD-00001 again
--
-- WHAT IT KEEPS
--   app_settings           the push endpoint URL and webhook secret. These
--                          are configuration, not data: wiping them would
--                          silently switch push off until they were typed
--                          back in, and the secret has to match the Vercel
--                          env var exactly. There is a commented line at the
--                          bottom if you really do want them gone.
--   the schema             tables, 67 SECURITY DEFINER functions, 23 RLS
--                          policies, triggers, indexes — all untouched.
--
-- IRREVERSIBLE. There is no undo and no trash. If there is anything in the
-- database you would miss, take a backup first (Supabase dashboard →
-- Database → Backups, or `pg_dump`) and confirm it downloaded before running
-- this.
--
--
-- HOW TO RUN IT
--
--   1. Change `false` to `true` on the line marked ARM THE SCRIPT below.
--   2. Paste the whole file into the Supabase SQL editor and run it.
--   3. Read the Messages / Notices tab: it prints what it deleted and
--      confirms the database is empty.
--
-- Until step 1 it does nothing at all.
--
--
-- WHY THE WHOLE THING IS ONE do $$ ... $$ BLOCK
--
-- Because the obvious way to write this is unsafe, and the unsafe version
-- was caught in testing rather than in production. The first draft looked
-- like this:
--
--   do $$ begin if not armed then raise exception '...'; end if; end $$;
--   begin;
--     delete from ...;
--   commit;
--
-- In the Supabase SQL editor that is fine — the editor sends the file as one
-- multi-statement request, which Postgres wraps in an implicit transaction,
-- so the exception aborts everything. But run the same file through
-- `psql -f` WITHOUT `-v ON_ERROR_STOP=1` and psql prints the error and then
-- carries straight on to the next statement. Measured: it printed
-- "ERROR: Not armed" and then deleted all three accounts and both orders
-- anyway. A guard that announces it is refusing and then does the thing is
-- worse than no guard, because the operator reads the refusal and believes
-- it.
--
-- A single plpgsql block has no such path. It is one statement to every
-- client, it either runs to completion or rolls back entirely, and an
-- exception anywhere in it — the guard, a foreign key nobody knew about, the
-- final check — leaves the database exactly as it was. No client setting can
-- change that.

do $$
declare
  -- ──────────────────────────────────────────────────────────────────────
  v_armed boolean := false;  -- <<<<<< ARM THE SCRIPT: change to true
  -- ──────────────────────────────────────────────────────────────────────

  v_users bigint; v_profiles bigint; v_orders bigint; v_hist bigint;
  v_msgs bigint; v_notif bigint; v_regions bigint; v_factories bigint;
  v_subs bigint; v_dr bigint; v_mf bigint; v_left bigint;
begin
  if not v_armed then
    raise exception
      'Not armed — nothing has been deleted. This script removes every '
      'account and every order in this database, with no undo. Read the '
      'header, set v_armed := true on the marked line, and run it again.';
  end if;

  -- ── what is about to go ───────────────────────────────────────────────
  --
  -- Printed before anything is deleted, so the Messages tab is a record of
  -- what the database held at the moment you ran this. Worth a glance: if
  -- these numbers are larger than you expected, cancel now — the deletes
  -- below have not happened yet and the block can still be interrupted.

  select count(*) into v_users     from auth.users;
  select count(*) into v_profiles  from public.profiles;
  select count(*) into v_orders    from public.orders;
  select count(*) into v_hist      from public.order_history;
  select count(*) into v_msgs      from public.order_messages;
  select count(*) into v_notif     from public.notifications;
  select count(*) into v_regions   from public.regions;
  select count(*) into v_factories from public.factories;
  select count(*) into v_subs      from public.push_subscriptions;
  select count(*) into v_dr        from public.driver_regions;
  select count(*) into v_mf        from public.manager_factories;

  raise notice '';
  raise notice '=== about to delete ===';
  raise notice 'logins (auth.users)      %', v_users;
  raise notice 'profiles                 %', v_profiles;
  raise notice 'orders                   %', v_orders;
  raise notice 'order history entries    %', v_hist;
  raise notice 'chat messages            %', v_msgs;
  raise notice 'notifications            %', v_notif;
  raise notice 'regions                  %', v_regions;
  raise notice 'factories                %', v_factories;
  raise notice 'registered push devices  %', v_subs;
  raise notice 'driver area assignments  %', v_dr;
  raise notice 'manager factory links    %', v_mf;
  raise notice '';

  -- ── the deletions, in foreign-key order ───────────────────────────────
  --
  -- Children before parents, even where a cascade would have handled it.
  -- Two of these orderings are load-bearing rather than tidy:
  --
  --   orders before factories — orders.assigned_factory_id is ON DELETE
  --     RESTRICT (migration 0033 chose that over SET NULL so a stray delete
  --     could never silently detach a historical order from its factory).
  --     Deleting factories first raises foreign_key_violation.
  --
  --   orders before regions — orders.region_id has no ON DELETE clause,
  --     which means NO ACTION: the delete is refused, it does not cascade.

  delete from public.order_messages;
  delete from public.order_history;
  delete from public.order_delivery_codes;
  delete from public.order_pickup_codes;
  delete from public.notifications;
  delete from public.push_subscriptions;
  delete from public.manager_factories;
  delete from public.driver_regions;
  delete from public.orders;
  delete from public.factories;
  delete from public.regions;

  -- Accounts last. Deleting auth.users rather than profiles on purpose:
  -- profiles.id is `references auth.users(id) on delete cascade`, so this
  -- removes both. Deleting profiles alone would leave the GoTrue rows
  -- behind, and an auth user with no profile can still authenticate — they
  -- land on /login?error=account_inactive and stay stuck there, invisible
  -- from the team page, which reads profiles.
  --
  -- GoTrue's own children (auth.identities, auth.sessions,
  -- auth.refresh_tokens) cascade from auth.users, so live sessions die with
  -- the accounts and nobody is left holding a cookie that still works.
  -- Verified: 2 identities and 1 session went with 3 users.
  delete from auth.users;

  -- ── numbering ─────────────────────────────────────────────────────────
  --
  -- Without this the first order in the empty system carries on from
  -- wherever the old data stopped — ORD-00042 with nothing before it. The
  -- third argument `false` means "the next nextval() returns 1", not 2.
  perform setval('public.order_number_seq', 1, false);

  -- ── confirm, or undo everything ───────────────────────────────────────
  --
  -- If anything is still there, the raise rolls the entire block back. That
  -- is the case this is really for: a table or a foreign key added after
  -- this script was written, which would otherwise leave the database half
  -- emptied and the operator none the wiser.

  select (select count(*) from auth.users) + (select count(*) from public.profiles)
       + (select count(*) from public.orders) + (select count(*) from public.order_history)
       + (select count(*) from public.order_messages) + (select count(*) from public.notifications)
       + (select count(*) from public.regions) + (select count(*) from public.factories)
       + (select count(*) from public.push_subscriptions) + (select count(*) from public.driver_regions)
       + (select count(*) from public.manager_factories)
       + (select count(*) from public.order_delivery_codes)
       + (select count(*) from public.order_pickup_codes)
    into v_left;

  if v_left <> 0 then
    raise exception
      'Expected every account and order table to be empty and found % '
      'row(s) still there. Nothing has been deleted — this whole block has '
      'rolled back. This usually means a new table or foreign key was added '
      'after this script was written.', v_left;
  end if;

  raise notice '=== empty. rows left across every account and order table: 0 ===';
  raise notice 'next order number will be ORD-00001';
  raise notice 'push config kept: % row(s) in app_settings',
    (select count(*) from public.app_settings);
  raise notice '';
  raise notice 'Now: sign out (or clear this site''s cookies), then open /setup';
  raise notice 'to create the first owner. /setup only works while no owner';
  raise notice 'exists, so it is available again from this moment.';
  raise notice '';
end $$;

-- ── optional extras, left commented on purpose ──────────────────────────

-- The push endpoint and webhook secret. Only if you intend to re-enter them;
-- the secret must match PUSH_WEBHOOK_SECRET in Vercel exactly or push stops
-- working with no error anywhere.
-- delete from public.app_settings where key in ('push_endpoint_url', 'push_webhook_secret');

-- pg_net's response log. Pure diagnostics — it is what you read when a push
-- did not arrive — but it grows forever and nothing prunes it. Clearing it
-- alongside a reset is reasonable; it is separate because it is not data.
-- delete from net._http_response;
