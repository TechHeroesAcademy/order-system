-- ============================================================================
-- NEON SETUP — PART 4 OF 4
--
-- PASTE THIS WHOLE FILE INTO NEON'S SQL EDITOR AND RUN IT.
-- Run the parts in order. Wait for each to finish before starting the next.
-- Each part is safe to re-run: every statement is idempotent.
--
-- The Neon-specific part: replaces auth.uid(), removes the PostgREST roles,
-- adds the password and login machinery that replaces GoTrue, and the two
-- service paths (push dispatch, the owner check) that used to rely on
-- Supabase's service-role key bypassing row-level security.
--
-- GENERATED — do not edit. Edit the source files listed below and re-run
-- scripts/build-neon-bundle.mjs, so Supabase and Neon cannot drift apart.
--
-- Contains, in order:
--    1. neon/migrations/0001_auth_shim.sql
--    2. neon/migrations/0002_local_auth.sql
--    3. neon/migrations/0003_service_paths.sql
-- ============================================================================

-- The chain installs pgcrypto/pg_trgm into the extensions schema (as Supabase
-- does) and several functions resolve against it. Declared per part rather
-- than relied on from the database default, so pasting a part into a fresh
-- editor session always works.
set search_path = public, extensions;



-- ========== neon/migrations/0001_auth_shim.sql ========================

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
end$$;

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

alter table public.profiles drop constraint if exists profiles_id_fkey;
alter table public.profiles alter column id set default gen_random_uuid();

drop trigger if exists on_auth_user_created on auth.users;
drop function if exists public.handle_new_user();

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'app_user') then
    create role app_user nologin;
  end if;
end$$;

do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on schema public from %I', r);
      execute format('revoke all on all tables in schema public from %I', r);
      execute format('revoke all on all functions in schema public from %I', r);
      execute format('revoke all on all sequences in schema public from %I', r);
      execute format('revoke all on schema extensions from %I', r);
      execute format('revoke all on all functions in schema extensions from %I', r);
    end if;
  end loop;
end$$;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
end$$;

do $$
declare r text;
begin
  foreach r in array array['anon', 'service_role'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      begin
        execute format('drop role %I', r);
        raise notice 'dropped the % role', r;
      exception when others then
        raise notice
          'could not drop the % role (%) — it has been stripped of all '
          'privileges and is NOLOGIN, so this is cosmetic only', r, sqlerrm;
      end;
    end if;
  end loop;
end$$;

grant usage on schema public to app_user;

grant select, update on public.profiles to app_user;
grant select, insert, update, delete on public.regions to app_user;
grant select, insert, update, delete on public.driver_regions to app_user;
grant select, insert, update on public.orders to app_user;
grant select on public.order_history to app_user;
grant select, insert, update on public.order_messages to app_user;
grant select, update on public.notifications to app_user;

grant select, insert, update, delete on public.factories to app_user;
grant select on public.manager_factories to app_user;
grant select, insert, update, delete on public.push_subscriptions to app_user;

grant execute on all functions in schema public to app_user;

grant authenticated to app_user;

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
end$$;

grant usage on schema public to app_admin;
grant select on public.profiles to app_admin;


-- ========== neon/migrations/0002_local_auth.sql =======================

create extension if not exists pgcrypto with schema extensions;

create or replace function public.canonical_phone(p_phone text)
returns text
language plpgsql
immutable
as $$
declare
  v text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if left(v, 4) = '0020' and length(v) >= 12 then
    v := substr(v, 5);
  elsif left(v, 2) = '20' and length(v) = 12 then
    v := substr(v, 3);
  end if;

  if length(v) > 0 and left(v, 1) <> '0' then
    v := '0' || v;
  end if;

  return v;
end;
$$;

revoke all on function public.canonical_phone(text) from public;
grant execute on function public.canonical_phone(text) to app_user;

create unique index if not exists profiles_canonical_phone_key
  on public.profiles (public.canonical_phone(phone))
  where phone is not null;

create table if not exists public.user_credentials (
  profile_id uuid primary key references public.profiles (id) on delete cascade,
  password_hash text,
  failed_attempts integer not null default 0,
  locked_until timestamptz,
  last_login_at timestamptz,
  password_changed_at timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.user_credentials enable row level security;

revoke all on table public.user_credentials from public;

comment on table public.user_credentials is
  'Password hashes and login throttling state. RLS on with zero policies: '
  'unreachable except through the auth_* SECURITY DEFINER functions. Kept '
  'out of profiles because profiles is readable by all staff.';

create or replace function public.auth_lockout_for(p_attempts integer)
returns interval
language sql
immutable
as $$
  select case
    when p_attempts >= 20 then interval '24 hours'
    when p_attempts >= 10 then interval '1 hour'
    when p_attempts >= 5  then interval '5 minutes'
    else interval '0'
  end;
$$;

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
    return;
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

create or replace function public.auth_set_initial_password(
  p_phone text,
  p_password text
)
returns table (status text, profile_id uuid, role public.user_role, full_name text)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_phone text := public.canonical_phone(p_phone);
  v_p record;
begin
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

  if v_p.password_hash is not null then
    return query select 'already_set'::text, null::uuid, null::public.user_role, null::text;
    return;
  end if;

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

  if v_p.locked_until is not null and v_p.locked_until > now() then
    return query select 'locked'::text, null::uuid, null::public.user_role, null::text,
                        ceil(extract(epoch from (v_p.locked_until - now())))::integer;
    return;
  end if;

  if v_p.password_hash = extensions.crypt(coalesce(p_password, ''), v_p.password_hash) then
    update public.user_credentials c
       set failed_attempts = 0, locked_until = null, last_login_at = now(), updated_at = now()
     where c.profile_id = v_p.id;
    return query select 'ok'::text, v_p.id, v_p.role, v_p.full_name, null::integer;
    return;
  end if;

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

  insert into public.user_credentials (profile_id) values (v_id);

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


-- ========== neon/migrations/0003_service_paths.sql ====================

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
       and p.is_active;
end;
$$;

comment on function public.push_dispatch_payload(uuid) is
  'Everything /api/push/dispatch needs to deliver one notification. Replaces '
  'the three cross-user reads that relied on Supabase''s service-role key. '
  'Returns nothing for an unknown notification or a deactivated recipient.';

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

revoke all on function public.push_dispatch_payload(uuid) from public;
revoke all on function public.push_prune_subscriptions(uuid[]) from public;
revoke all on function public.push_mark_delivered(uuid[]) from public;
revoke all on function public.owner_exists() from public;

grant execute on function public.push_dispatch_payload(uuid) to app_user;
grant execute on function public.push_prune_subscriptions(uuid[]) to app_user;
grant execute on function public.push_mark_delivered(uuid[]) to app_user;
grant execute on function public.owner_exists() to app_user;

grant execute on function public.increment_push_failures(uuid[]) to app_user;
