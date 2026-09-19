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
create extension if not exists pg_net;

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
