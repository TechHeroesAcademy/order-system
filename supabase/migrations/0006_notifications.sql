-- 0006_notifications.sql
-- Simple, clear in-app notifications per role (matches the spec: "إشعارات بسيطة وواضحة").

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  order_id uuid references public.orders (id) on delete cascade,
  type text not null,
  title text not null,
  body text,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists notifications_user_idx on public.notifications (user_id, is_read, created_at desc);

create or replace function public.notify_user(
  p_user_id uuid,
  p_order_id uuid,
  p_type text,
  p_title text,
  p_body text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user_id is null then
    return;
  end if;

  insert into public.notifications (user_id, order_id, type, title, body)
  values (p_user_id, p_order_id, p_type, p_title, p_body);
end;
$$;

-- Notify every active user with a given role (used for Owner-facing events).
create or replace function public.notify_role(
  p_role user_role,
  p_order_id uuid,
  p_type text,
  p_title text,
  p_body text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user record;
begin
  for v_user in select id from public.profiles where role = p_role and is_active loop
    perform public.notify_user(v_user.id, p_order_id, p_type, p_title, p_body);
  end loop;
end;
$$;
