alter table public.profiles add column if not exists address text;

comment on column public.profiles.address is
  'Free-text location/address. Only meaningful for role=factory today — the physical place a driver drops off a collected order and later picks it back up. Shown in Team management, the order-creation factory picker, and the assigned order''s detail view (including the driver''s own).';

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, phone, role, address)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.email, 'مستخدم جديد'),
    new.raw_user_meta_data ->> 'phone',
    coalesce((new.raw_user_meta_data ->> 'role')::user_role, 'driver'),
    new.raw_user_meta_data ->> 'address'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

alter table public.orders add column if not exists handed_to_factory_at timestamptz;

comment on column public.orders.handed_to_factory_at is
  'Set once by driver_hand_to_factory(). Status stays ''collected'' through this step (only factory_confirm_receipt advances it to ''at_factory''), so the frontend uses this column, not status, to tell "collected, not yet handed off" apart from "handed off, waiting on the factory".';

create or replace function public.driver_hand_to_factory(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.assigned_driver_id <> auth.uid() then raise exception 'غير مصرح' using errcode = '42501'; end if;
  if v_order.status <> 'collected' then raise exception 'الأوردر ليس بحالة تسمح بالتوجه للمصنع'; end if;
  if v_order.handed_to_factory_at is not null then
    raise exception 'تم تسجيل هذه الخطوة بالفعل';
  end if;

  update public.orders set handed_to_factory_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'handed_to_factory', 'collected', 'collected', 'المندوب توجه بالأوردر إلى المصنع');
end;
$$;

drop policy if exists profiles_select_factory_for_assigned_driver on public.profiles;
create policy profiles_select_factory_for_assigned_driver on public.profiles
  for select using (
    role = 'factory'
    and exists (
      select 1 from public.orders o
      where o.assigned_factory_id = profiles.id
        and o.assigned_driver_id = auth.uid()
    )
  );

drop view if exists public.factory_orders_view;

create view public.factory_orders_view
with (security_invoker = false) as
select
  o.id,
  o.order_number,
  o.status,
  o.pieces_count,
  o.piece_details,
  o.color,
  o.work_required,
  o.assigned_driver_id,
  p.full_name as assigned_driver_name,
  o.assigned_factory_id,
  f.full_name as assigned_factory_name,
  f.address as assigned_factory_address,
  o.collected_at,
  o.handed_to_factory_at,
  o.factory_received_at,
  o.factory_ready_at,
  o.created_at
from public.orders o
left join public.profiles p on p.id = o.assigned_driver_id
left join public.profiles f on f.id = o.assigned_factory_id
where o.status in ('collected', 'at_factory', 'ready')
  and (
    public.current_user_role() in ('owner', 'moderator')
    or (
      public.current_user_role() = 'factory'
      and (o.assigned_factory_id is null or o.assigned_factory_id = auth.uid())
    )
  );

grant select on public.factory_orders_view to authenticated;
