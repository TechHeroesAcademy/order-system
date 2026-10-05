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
