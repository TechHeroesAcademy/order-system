create or replace function public.moderator_notification_types()
returns text[]
language sql
immutable
as $$ select array['order_delivered']$$;

create or replace function public.notify_staff(
  p_order_id uuid,
  p_type text,
  p_title text,
  p_body text default null,
  p_exclude uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user record;
begin
  for v_user in
    select id from public.profiles
    where role in ('owner', 'moderator') and is_active
      and (p_exclude is null or id <> p_exclude)
      and (role = 'owner' or p_type = any (public.moderator_notification_types()))
  loop
    perform public.notify_user(v_user.id, p_order_id, p_type, p_title, p_body);
  end loop;
end;
$$;

revoke all on function public.notify_staff(uuid, text, text, text, uuid) from public;
revoke all on function public.moderator_notification_types() from public;

delete from public.notifications n
 using public.profiles p
 where p.id = n.user_id
   and p.role = 'moderator'
   and not (n.type = any (public.moderator_notification_types()));
