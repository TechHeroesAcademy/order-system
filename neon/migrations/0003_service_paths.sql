-- neon/migrations/0003_service_paths.sql
--
-- Apply AFTER 0002_local_auth.sql, on a bare Neon/Postgres database only.
--
-- The last two things that worked only because Supabase's service-role key
-- bypassed row-level security on everything. With that key gone, both are
-- broken — and both break SILENTLY, which is why they get a migration of
-- their own rather than a footnote.
--
--
-- 1. PUSH NOTIFICATIONS WOULD NEVER SEND AGAIN
--
-- /api/push/dispatch is called by the database, not a browser, so it carries
-- no session. It then reads one person's notification, that person's profile,
-- and that person's registered devices — a deliberate cross-user read, and
-- the only one in the system. Under Supabase the service-role key made that
-- work by ignoring RLS.
--
-- Now the route runs with no identity at all, and the policies it meets are:
--
--   notifications_select_own        user_id = auth.uid()
--   push_subscriptions_select_own   user_id = auth.uid()
--   profiles_select_staff           is_owner_or_moderator()
--
-- With auth.uid() NULL, every one of those returns zero rows. No error. The
-- route would answer {"ok":true,"sent":0,"reason":"not found"} forever and
-- nothing would ever reach a phone — the exact failure mode that is hardest
-- to notice, because the in-app bell keeps working perfectly.
--
-- Replaced with one SECURITY DEFINER function that returns exactly what is
-- needed to send one push, for one notification id the caller already has.
-- Narrower than the service-role key it replaces by a wide margin: that key
-- could read every row in the database.
--
--
-- 2. /setup WOULD OFFER THE BOOTSTRAP FORM FOREVER
--
-- ownerExists() counts profiles with role 'owner', before anyone is signed
-- in. profiles_select_staff needs a role, so with no identity the count is
-- always 0 and the page always renders the "create the first owner" form —
-- even on a system that has been running for months.
--
-- Not a security hole: bootstrap_owner() takes a row lock on that same check
-- and refuses with 'already_set_up', so the form submits and fails. But a
-- login page that invites every visitor to create an owner account is not
-- something to leave standing.

-- ── everything needed to send one push, in one call ──────────────────────

create or replace function public.push_dispatch_payload(p_notification_id uuid)
returns table (
  notification_id uuid,
  order_id uuid,
  notification_type text,
  title text,
  body text,
  recipient_role public.user_role,
  recipient_active boolean,
  subscription_id uuid,
  endpoint text,
  p256dh text,
  auth_secret text
)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  -- One row per device. No devices registered means no rows, which the route
  -- already treats as the ordinary case rather than a failure — most people
  -- have not turned notifications on, and the bell still has the message.
  return query
    select n.id,
           n.order_id,
           n.type::text,
           n.title,
           n.body,
           p.role,
           p.is_active,
           s.id,
           s.endpoint,
           s.p256dh,
           s.auth
      from public.notifications n
      join public.profiles p on p.id = n.user_id
      left join public.push_subscriptions s on s.user_id = n.user_id
     where n.id = p_notification_id
       -- Checked here rather than left to the route: a deactivated account
       -- should not have their phone buzzed, and the database is the place
       -- that knows for certain whether they are still active.
       and p.is_active;
end;
$$;

comment on function public.push_dispatch_payload(uuid) is
  'Everything /api/push/dispatch needs to deliver one notification. Replaces '
  'the three cross-user reads that relied on Supabase''s service-role key. '
  'Returns nothing for an unknown notification or a deactivated recipient.';

-- ── recording what happened to each attempt ──────────────────────────────

-- A 404 or 410 from a push service means that endpoint is gone for good —
-- the app was uninstalled, or the browser rotated its subscription. Keeping
-- it means paying for a failing request on every future notification.
create or replace function public.push_prune_subscriptions(p_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_n integer;
begin
  if p_ids is null or array_length(p_ids, 1) is null then return 0; end if;
  delete from public.push_subscriptions where id = any(p_ids);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

create or replace function public.push_mark_delivered(p_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_n integer;
begin
  if p_ids is null or array_length(p_ids, 1) is null then return 0; end if;
  update public.push_subscriptions
     set last_success_at = now(), failure_count = 0
   where id = any(p_ids);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- ── does an owner exist ──────────────────────────────────────────────────
--
-- Deliberately returns a bare boolean and nothing else. The /setup page
-- needs one bit to decide what to render, and this is a function an
-- unauthenticated caller can reach, so it gives up one bit: whether this
-- system has been set up. Not the owner's name, their phone, or how many
-- there are.
create or replace function public.owner_exists()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.profiles where role = 'owner' and is_active
  );
$$;

comment on function public.owner_exists() is
  'Whether the one-time owner bootstrap has already happened. Reachable '
  'without a session, and returns exactly one bit for that reason.';

-- ── grants ──────────────────────────────────────────────────────────────
--
-- These reach past RLS, so each is granted to the single application role
-- and nothing else — never to a PostgREST-style anon role, which does not
-- exist here any more.
--
-- The security boundary for the push functions is NOT this grant: it is the
-- x-push-secret header the route checks with a timing-safe comparison before
-- it calls anything. These functions are reachable only by something that
-- already holds the application's database password, and even then
-- push_dispatch_payload needs a notification UUID it must already know.

revoke all on function public.push_dispatch_payload(uuid) from public;
revoke all on function public.push_prune_subscriptions(uuid[]) from public;
revoke all on function public.push_mark_delivered(uuid[]) from public;
revoke all on function public.owner_exists() from public;

grant execute on function public.push_dispatch_payload(uuid) to app_user;
grant execute on function public.push_prune_subscriptions(uuid[]) to app_user;
grant execute on function public.push_mark_delivered(uuid[]) to app_user;
grant execute on function public.owner_exists() to app_user;

-- increment_push_failures already exists (migration 0040) and is already
-- SECURITY DEFINER with no role check, so it works from the dispatch route
-- unchanged. It was only ever granted to `authenticated`, which the shim
-- stripped — so without this the route's failure accounting fails with
-- "permission denied for function".
grant execute on function public.increment_push_failures(uuid[]) to app_user;
