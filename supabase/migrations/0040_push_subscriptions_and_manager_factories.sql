create table if not exists public.manager_factories (
  manager_id uuid not null references public.profiles (id) on delete cascade,
  factory_id uuid not null references public.factories (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (manager_id, factory_id)
);

create index if not exists manager_factories_factory_idx
  on public.manager_factories (factory_id);

alter table public.manager_factories enable row level security;

drop policy if exists manager_factories_select on public.manager_factories;
create policy manager_factories_select on public.manager_factories
  for select to authenticated using (public.is_owner_or_moderator());

grant select on public.manager_factories to authenticated;

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  last_success_at timestamptz,
  failure_count integer not null default 0
);

create index if not exists push_subscriptions_user_idx
  on public.push_subscriptions (user_id);

alter table public.push_subscriptions enable row level security;

drop policy if exists push_subscriptions_select_own on public.push_subscriptions;
create policy push_subscriptions_select_own on public.push_subscriptions
  for select to authenticated using (user_id = auth.uid());

drop policy if exists push_subscriptions_delete_own on public.push_subscriptions;
create policy push_subscriptions_delete_own on public.push_subscriptions
  for delete to authenticated using (user_id = auth.uid());

grant select, delete on public.push_subscriptions to authenticated;

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
  if v_target.role not in ('owner', 'moderator') then
    raise exception 'التغطية بالمصانع للمديرين فقط';
  end if;

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
