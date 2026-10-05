begin;

create or replace function public.push_outbox_claim(p_limit integer default 20)
returns table (id bigint, notification_id uuid, attempts integer)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  return query
  with claimed as (
    select o.id
      from public.push_outbox o
     where o.delivered_at is null
       and o.attempts < 5
     order by o.created_at
     limit greatest(1, least(coalesce(p_limit, 20), 100))
     for update skip locked
  )
  update public.push_outbox o
     set attempts = o.attempts + 1
    from claimed c
   where o.id = c.id
  returning o.id,
            (o.body ->> 'notification_id')::uuid,
            o.attempts;
end;
$$;

comment on function public.push_outbox_claim(integer) is
  'Takes the next pending queued push requests and counts an attempt against '
  'each, so two concurrent drains never send the same notification twice '
  '(FOR UPDATE SKIP LOCKED). Returns the notification id the application '
  'needs. Callable without a session, like push_dispatch_payload, because '
  'the request that drains the queue may not be the one that filled it.';

create or replace function public.push_outbox_mark_sent(p_ids bigint[])
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  if p_ids is null or cardinality(p_ids) = 0 then
    return 0;
  end if;
  update public.push_outbox
     set delivered_at = now(), last_error = null
   where id = any (p_ids)
     and delivered_at is null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.push_outbox_mark_failed(
  p_ids bigint[],
  p_error text default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  if p_ids is null or cardinality(p_ids) = 0 then
    return 0;
  end if;
  update public.push_outbox
     set last_error = left(coalesce(p_error, 'unknown'), 500)
   where id = any (p_ids)
     and delivered_at is null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

comment on function public.push_outbox_mark_failed(bigint[], text) is
  'Records why a send failed without marking it delivered, so it is retried '
  'on the next drain. push_outbox_claim stops retrying at 5 attempts, which '
  'is what keeps a permanently undeliverable row from being picked up for '
  'ever.';

create or replace function public.push_outbox_prune(p_keep_days integer default 7)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  delete from public.push_outbox
   where delivered_at is not null
     and delivered_at < now() - make_interval(days => greatest(1, coalesce(p_keep_days, 7)));
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.push_outbox_claim(integer) from public;
revoke all on function public.push_outbox_mark_sent(bigint[]) from public;
revoke all on function public.push_outbox_mark_failed(bigint[], text) from public;
revoke all on function public.push_outbox_prune(integer) from public;

grant execute on function public.push_outbox_claim(integer) to authenticated;
grant execute on function public.push_outbox_mark_sent(bigint[]) to authenticated;
grant execute on function public.push_outbox_mark_failed(bigint[], text) to authenticated;
grant execute on function public.push_outbox_prune(integer) to authenticated;

do $$
declare
  v_missing text[] := '{}';
  v_name text;
begin
  foreach v_name in array array[
    'push_outbox_claim', 'push_outbox_mark_sent',
    'push_outbox_mark_failed', 'push_outbox_prune'
  ] loop
    if not exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = v_name and p.prosecdef
    ) then
      v_missing := v_missing || v_name;
    end if;
  end loop;
  if cardinality(v_missing) > 0 then
    raise exception 'push outbox drain functions missing or not SECURITY DEFINER: %', v_missing;
  end if;
end;
$$;

commit;
