-- 0040_push_subscriptions_and_manager_factories.sql
--
-- Groundwork for phone push notifications. Two new tables, their RLS, and
-- the RPCs that write them. Nothing in this migration sends anything or
-- changes any existing behavior — the dispatch trigger is 0041, and the app
-- ignores both tables until it is deployed. Safe to apply at any time.
--
-- Push here is the browser's own Web Push (the W3C standard, VAPID keys),
-- not Firebase. On the web, Firebase Cloud Messaging is a wrapper around
-- this same API — same browsers, same permission prompt, same iOS
-- restriction — so going direct costs nothing in reach and keeps device
-- endpoints in this database rather than a third party's.

-- ── who a manager covers ────────────────────────────────────────────────
--
-- Until now nothing linked a person to a factory. Orders have
-- assigned_factory_id; managers had no factory of their own, and
-- notify_staff/notify_role fan out to every active manager unconditionally.
--
-- This table does NOT change that. Managers still see every order and still
-- get every in-app notification — that was a deliberate product decision
-- and it stands. This is narrower: it decides whose *phone* rings for a
-- chat message. The bell stays the complete record; the push is only for
-- work that is yours.
--
-- A manager may cover several factories, and a factory may be covered by
-- several managers, hence a join table rather than a column on profiles.
create table if not exists public.manager_factories (
  manager_id uuid not null references public.profiles (id) on delete cascade,
  factory_id uuid not null references public.factories (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (manager_id, factory_id)
);

-- The lookup this exists for runs in the other direction — "given this
-- order's factory, whose phone rings" — and the primary key's leading
-- column is manager_id, so it cannot serve that.
create index if not exists manager_factories_factory_idx
  on public.manager_factories (factory_id);

alter table public.manager_factories enable row level security;

-- Readable by any signed-in staff member: the Team page shows each
-- manager's coverage the same way it shows a driver's regions, and there is
-- nothing sensitive in "which workshop does this person watch".
drop policy if exists manager_factories_select on public.manager_factories;
create policy manager_factories_select on public.manager_factories
  for select to authenticated using (public.is_owner_or_moderator());

-- No insert/update/delete policy on purpose. Writes go through
-- set_manager_factories() below, which is security definer and carries the
-- owner-only check. A table with no write policy fails closed.

grant select on public.manager_factories to authenticated;

-- ── a device that agreed to be notified ─────────────────────────────────
--
-- One row per browser-on-one-device that has granted permission. A person
-- can have several (phone and laptop), and the same phone reinstalling the
-- app produces a new endpoint rather than reusing the old one, which is why
-- endpoint — not user_id — is the unique key.
--
-- p256dh and auth are the subscription's own encryption keys, handed over
-- by the browser. They are useless without the matching VAPID private key,
-- which lives in the server environment and never in this database.
create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  -- The push service URL the browser gave us. Unique because re-subscribing
  -- on the same device returns the same endpoint, and inserting a second
  -- row for it would mean sending every notification twice.
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  -- Purely for the "which of my devices is this?" list and for support
  -- questions ("it works on my phone but not the tablet").
  user_agent text,
  created_at timestamptz not null default now(),
  last_success_at timestamptz,
  -- Push services return 404/410 for an endpoint that is gone for good
  -- (app uninstalled, permission revoked). The dispatcher deletes those
  -- outright; this counts the soft failures, so a persistently broken
  -- endpoint can be spotted rather than retried forever.
  failure_count integer not null default 0
);

create index if not exists push_subscriptions_user_idx
  on public.push_subscriptions (user_id);

alter table public.push_subscriptions enable row level security;

-- Strictly your own devices. Nobody reads anyone else's endpoint through
-- the API — the dispatcher reads them server-side with the service role,
-- which is the only context that ever needs to see another person's.
drop policy if exists push_subscriptions_select_own on public.push_subscriptions;
create policy push_subscriptions_select_own on public.push_subscriptions
  for select to authenticated using (user_id = auth.uid());

drop policy if exists push_subscriptions_delete_own on public.push_subscriptions;
create policy push_subscriptions_delete_own on public.push_subscriptions
  for delete to authenticated using (user_id = auth.uid());

grant select, delete on public.push_subscriptions to authenticated;

-- ── register / forget a device ──────────────────────────────────────────
--
-- Inserts go through this rather than a policy so user_id is taken from
-- auth.uid() and cannot be supplied by the caller — no client can register
-- a device against someone else's account and start receiving their
-- notifications.
--
-- Re-registering the same endpoint updates it in place (the browser can
-- rotate the keys on an existing endpoint), and re-points it at the current
-- user: a shared device where one driver signs out and another signs in
-- must ring for whoever is actually signed in now, not the previous person.
create or replace function public.save_push_subscription(
  p_endpoint text,
  p_p256dh text,
  p_auth text,
  p_user_agent text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if coalesce(trim(p_endpoint), '') = ''
     or coalesce(trim(p_p256dh), '') = ''
     or coalesce(trim(p_auth), '') = '' then
    raise exception 'بيانات الاشتراك غير مكتملة' using errcode = '22023';
  end if;
  -- A push endpoint is a URL from the browser vendor's push service. Bound
  -- so a client can't park arbitrary amounts of data in this table.
  if length(p_endpoint) > 2000 or length(p_p256dh) > 500 or length(p_auth) > 500 then
    raise exception 'بيانات الاشتراك غير صالحة' using errcode = '22023';
  end if;

  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth, user_agent)
  values (v_uid, p_endpoint, p_p256dh, p_auth, left(p_user_agent, 400))
  on conflict (endpoint) do update
    set user_id = excluded.user_id,
        p256dh = excluded.p256dh,
        auth = excluded.auth,
        user_agent = excluded.user_agent,
        failure_count = 0;
end;
$$;

-- Turning notifications off. Scoped to the caller's own rows on top of the
-- delete policy — belt and braces, because this one is easy to get wrong
-- and the failure mode is silently unsubscribing someone else's phone.
create or replace function public.delete_push_subscription(p_endpoint text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  delete from public.push_subscriptions
   where endpoint = p_endpoint and user_id = v_uid;
end;
$$;

-- ── set a manager's factories ───────────────────────────────────────────
--
-- Owner-only, matching update_staff_profile and set_driver_regions_by_name
-- (0037): deciding who is accountable for a workshop is a management
-- decision, not a moderator one.
--
-- Replaces the whole set rather than adding one at a time, so the UI can
-- send what the checkboxes currently say without having to diff.
create or replace function public.set_manager_factories(
  p_manager_id uuid,
  p_factory_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target public.profiles;
  v_ids uuid[] := coalesce(p_factory_ids, '{}');
  v_unknown integer;
begin
  if not public.is_owner() then
    raise exception 'تعديل تغطية المديرين من صلاحية المدير فقط' using errcode = '42501';
  end if;

  select * into v_target from public.profiles where id = p_manager_id;
  if v_target is null then
    raise exception 'الحساب غير موجود';
  end if;
  -- Drivers are covered by regions, not factories. Allowing a driver row
  -- here would create coverage that nothing reads and that looks, in the
  -- database, exactly like a real assignment.
  if v_target.role not in ('owner', 'moderator') then
    raise exception 'التغطية بالمصانع للمديرين فقط';
  end if;

  -- Fail loudly on an id that isn't a factory rather than silently storing
  -- fewer rows than the caller asked for.
  --
  -- The alias here is load-bearing. Written as `unnest(v_ids) as id`, the
  -- `id` inside the subquery binds to factories.id — the inner scope wins —
  -- so the test reads `f.id = f.id`, is true for every row, and the check
  -- silently never fires. It was written that way first; the foreign key
  -- still refused the bad row, so the data stayed correct, but the caller
  -- got a raw constraint violation instead of this message. Naming the
  -- column t(fid) makes the reference unambiguous.
  select count(*) into v_unknown
    from unnest(v_ids) as t(fid)
   where not exists (select 1 from public.factories f where f.id = t.fid);
  if v_unknown > 0 then
    raise exception 'مصنع غير معروف ضمن المحدد';
  end if;

  delete from public.manager_factories
   where manager_id = p_manager_id
     and not (factory_id = any (v_ids));

  insert into public.manager_factories (manager_id, factory_id)
  select p_manager_id, t.fid from unnest(v_ids) as t(fid)
  on conflict do nothing;
end;
$$;

-- ── bookkeeping for devices that didn't answer ──────────────────────────
--
-- Called only by the dispatcher (service role), which is why there is no
-- grant to `authenticated`: nothing a browser does should be able to mark
-- anyone's device as failing. Kept as an RPC rather than a client-side loop
-- so a batch of failures is one round trip instead of one per device.
--
-- Endpoints the push service says are gone for good are deleted outright by
-- the dispatcher; this counts only the soft failures — offline, timed out,
-- push service having a bad day — so a device that is permanently broken can
-- be told apart from one whose owner is on the metro.
create or replace function public.increment_push_failures(p_ids uuid[])
returns void
language sql
security definer
set search_path = public
as $$
  update public.push_subscriptions
     set failure_count = failure_count + 1
   where id = any (coalesce(p_ids, '{}'));
$$;

revoke all on function public.increment_push_failures(uuid[]) from public;

revoke all on function public.save_push_subscription(text, text, text, text) from public;
revoke all on function public.delete_push_subscription(text) from public;
revoke all on function public.set_manager_factories(uuid, uuid[]) from public;

grant execute on function public.save_push_subscription(text, text, text, text) to authenticated;
grant execute on function public.delete_push_subscription(text) to authenticated;
grant execute on function public.set_manager_factories(uuid, uuid[]) to authenticated;
