create or replace function public.current_user_role()
returns public.user_role
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles
   where id = auth.uid()
     and is_active;
$$;

create or replace function public.is_owner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.current_user_role() = 'owner', false);
$$;

create or replace function public.is_owner_or_moderator()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.current_user_role() in ('owner', 'moderator'), false);
$$;

revoke all on function public.current_user_role() from public;
revoke all on function public.is_owner() from public;
revoke all on function public.is_owner_or_moderator() from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.current_user_role() to authenticated';
    execute 'grant execute on function public.is_owner() to authenticated';
    execute 'grant execute on function public.is_owner_or_moderator() to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'app_user') then
    execute 'grant execute on function public.current_user_role() to app_user';
    execute 'grant execute on function public.is_owner() to app_user';
    execute 'grant execute on function public.is_owner_or_moderator() to app_user';
  end if;
end$$;

do $$
declare
  v_role_before public.user_role;
begin
  select public.current_user_role() into v_role_before;

  if v_role_before is not null then
    raise exception
      'Expected current_user_role() to be NULL with no session, got %. '
      'This migration cannot verify itself — stopping.', v_role_before;
  end if;

  if public.is_owner() is not false then
    raise exception 'is_owner() must be false with no session, got %', public.is_owner();
  end if;
  if public.is_owner_or_moderator() is not false then
    raise exception 'is_owner_or_moderator() must be false with no session, got %',
      public.is_owner_or_moderator();
  end if;

  if not public.is_owner_or_moderator() then
    raise notice 'verified: the `if not is_owner_or_moderator()` guard now fires with no session';
  else
    raise exception
      'The guard still does not fire with no session. All 49 authorization '
      'checks in this schema remain open. Refusing to apply.';
  end if;
end$$;
