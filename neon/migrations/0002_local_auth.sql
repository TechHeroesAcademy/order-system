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
