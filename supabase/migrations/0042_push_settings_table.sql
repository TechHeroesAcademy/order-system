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
