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
