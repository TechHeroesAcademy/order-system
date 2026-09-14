-- 0005_order_history.sql
-- Full movement/audit log per order ("سجل حركة الأوردر"). Every status change and
-- notable action (distribution set, code attempt, refusal, ...) is appended here.

create table if not exists public.order_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  event_type text not null,
  from_status order_status,
  to_status order_status,
  actor_id uuid references public.profiles (id),
  actor_role user_role,
  note text,
  created_at timestamptz not null default now()
);

create index if not exists order_history_order_idx on public.order_history (order_id, created_at);

create or replace function public.log_order_event(
  p_order_id uuid,
  p_event_type text,
  p_from_status order_status,
  p_to_status order_status,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role user_role;
begin
  select role into v_actor_role from public.profiles where id = v_actor_id;

  insert into public.order_history (order_id, event_type, from_status, to_status, actor_id, actor_role, note)
  values (p_order_id, p_event_type, p_from_status, p_to_status, v_actor_id, v_actor_role, p_note);
end;
$$;
