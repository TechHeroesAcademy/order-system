create table if not exists public.app_settings (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);

alter table public.app_settings enable row level security;

revoke all on public.app_settings from anon, authenticated;

comment on table public.app_settings is
  'Server-side configuration read only by security-definer functions. Never exposed to the API: no grants to anon/authenticated. Holds the push endpoint URL and webhook secret — see 0041/0042.';

create or replace function public.dispatch_push_notification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_secret text;
begin
  select value into v_url from public.app_settings where key = 'push_endpoint_url';
  select value into v_secret from public.app_settings where key = 'push_webhook_secret';

  if coalesce(v_url, '') = '' or coalesce(v_secret, '') = '' then
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

revoke all on function public.dispatch_push_notification() from public;

