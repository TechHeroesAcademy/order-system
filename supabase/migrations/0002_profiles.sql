-- 0002_profiles.sql
-- One profile row per auth.users row, carrying the role that drives RBAC everywhere else.

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null,
  phone text,
  role user_role not null default 'driver',
  region_id uuid, -- FK added in 0003 after regions exists
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is 'Application user profile + role, one per auth.users row.';

-- Keep updated_at current on every update.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists set_profiles_updated_at on public.profiles;
create trigger set_profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- Auto-create a profile whenever a new auth user is created.
-- Role/full_name/phone are read from the signup metadata (set by the inviting Owner
-- when creating the account, e.g. via supabase.auth.admin.createUser({ user_metadata })).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, phone, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.email, 'مستخدم جديد'),
    new.raw_user_meta_data ->> 'phone',
    coalesce((new.raw_user_meta_data ->> 'role')::user_role, 'driver')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Helper used throughout RLS policies and RPCs to read the caller's role cheaply.
create or replace function public.current_user_role()
returns user_role
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

create or replace function public.is_owner()
returns boolean language sql stable security definer set search_path = public as $$
  select public.current_user_role() = 'owner';
$$;

create or replace function public.is_owner_or_moderator()
returns boolean language sql stable security definer set search_path = public as $$
  select public.current_user_role() in ('owner', 'moderator');
$$;
