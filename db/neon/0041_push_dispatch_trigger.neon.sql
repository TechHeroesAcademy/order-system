create or replace function public.should_push_notification(n public.notifications)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role public.user_role;
  v_factory uuid;
begin
  select role into v_role from public.profiles
   where id = n.user_id and is_active;
  if v_role is null then return false; end if;

  if n.type = 'order_assigned' then
    return true;
  end if;

  if n.type = 'chat_message' then
    if v_role = 'driver' then
      return true;
    end if;

    if v_role in ('owner', 'moderator') then
      if n.order_id is null then return false; end if;
      select assigned_factory_id into v_factory
        from public.orders where id = n.order_id;
      if v_factory is null then return false; end if;
      return exists (
        select 1 from public.manager_factories mf
         where mf.manager_id = n.user_id
           and mf.factory_id = v_factory
      );
    end if;

    return false;
  end if;

  return false;
end;
$$;

create or replace function public.dispatch_push_notification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text := nullif(current_setting('app.push_endpoint_url', true), '');
  v_secret text := nullif(current_setting('app.push_webhook_secret', true), '');
begin
  if v_url is null or v_secret is null then
    return null;
  end if;

  if not public.should_push_notification(new) then
    return null;
  end if;

  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('notification_id', new.id),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-Push-Secret', v_secret
    ),
    timeout_milliseconds := 5000
  );

  return null;
exception when others then
  raise warning 'push dispatch skipped for notification %: %', new.id, sqlerrm;
  return null;
end;
$$;

drop trigger if exists dispatch_push_on_notification on public.notifications;
create trigger dispatch_push_on_notification
  after insert on public.notifications
  for each row execute function public.dispatch_push_notification();

revoke all on function public.should_push_notification(public.notifications) from public;
revoke all on function public.dispatch_push_notification() from public;

