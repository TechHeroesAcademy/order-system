create or replace function public.push_dispatch_payload(p_notification_id uuid)
returns table (
  notification_id uuid,
  order_id uuid,
  notification_type text,
  title text,
  body text,
  recipient_role public.user_role,
  recipient_active boolean,
  subscription_id uuid,
  endpoint text,
  p256dh text,
  auth_secret text
)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  return query
    select n.id,
           n.order_id,
           n.type::text,
           n.title,
           n.body,
           p.role,
           p.is_active,
           s.id,
           s.endpoint,
           s.p256dh,
           s.auth
      from public.notifications n
      join public.profiles p on p.id = n.user_id
      left join public.push_subscriptions s on s.user_id = n.user_id
     where n.id = p_notification_id
       and p.is_active;
end;
$$;

comment on function public.push_dispatch_payload(uuid) is
  'Everything /api/push/dispatch needs to deliver one notification. Replaces '
  'the three cross-user reads that relied on Supabase''s service-role key. '
  'Returns nothing for an unknown notification or a deactivated recipient.';

create or replace function public.push_prune_subscriptions(p_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_n integer;
begin
  if p_ids is null or array_length(p_ids, 1) is null then return 0; end if;
  delete from public.push_subscriptions where id = any(p_ids);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

create or replace function public.push_mark_delivered(p_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_n integer;
begin
  if p_ids is null or array_length(p_ids, 1) is null then return 0; end if;
  update public.push_subscriptions
     set last_success_at = now(), failure_count = 0
   where id = any(p_ids);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

create or replace function public.owner_exists()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.profiles where role = 'owner' and is_active
  );
$$;

comment on function public.owner_exists() is
  'Whether the one-time owner bootstrap has already happened. Reachable '
  'without a session, and returns exactly one bit for that reason.';

revoke all on function public.push_dispatch_payload(uuid) from public;
revoke all on function public.push_prune_subscriptions(uuid[]) from public;
revoke all on function public.push_mark_delivered(uuid[]) from public;
revoke all on function public.owner_exists() from public;

grant execute on function public.push_dispatch_payload(uuid) to app_user;
grant execute on function public.push_prune_subscriptions(uuid[]) to app_user;
grant execute on function public.push_mark_delivered(uuid[]) to app_user;
grant execute on function public.owner_exists() to app_user;

grant execute on function public.increment_push_failures(uuid[]) to app_user;
