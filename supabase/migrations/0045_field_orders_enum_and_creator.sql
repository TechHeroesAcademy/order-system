alter type public.order_source add value if not exists 'driver_field';

alter table public.orders add column if not exists created_by_name text;
alter table public.orders add column if not exists created_by_role public.user_role;

update public.orders o
   set created_by_name = p.full_name,
       created_by_role = p.role
  from public.profiles p
 where p.id = o.created_by
   and o.created_by_name is null;

create or replace function public.stamp_order_creator_name()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.created_by is not null then
    select full_name, role into new.created_by_name, new.created_by_role
      from public.profiles where id = new.created_by;
  end if;
  return new;
end;
$$;

drop trigger if exists stamp_order_creator on public.orders;
create trigger stamp_order_creator
  before insert on public.orders
  for each row execute function public.stamp_order_creator_name();

revoke all on function public.stamp_order_creator_name() from public;
