do $$
begin
  if exists (
    select 1 from pg_extension where extname = 'pg_net'
  ) or exists (
    select 1 from information_schema.columns
    where table_schema = 'auth' and table_name = 'users'
      and column_name in ('instance_id', 'encrypted_password', 'confirmation_token')
  ) then
    raise exception
      'Refusing to run: this looks like a real Supabase-managed database '
      '(pg_net is installed, or auth.users has Supabase-specific columns). '
      'This file creates a stand-in net.http_post and PostgREST-shaped '
      'roles, and is meant for a bare Neon/Postgres database only. '
      'Aborting.';
  end if;
end$$;

create schema if not exists extensions;
create schema if not exists auth;
create schema if not exists net;

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;

do $$
begin
  execute format(
    'alter database %I set search_path = public, extensions',
    current_database()
  );
end$$;

set search_path = public, extensions;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin;
  end if;
end$$;

grant usage on schema public, extensions to anon, authenticated, service_role;

create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  phone text,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create or replace function auth.uid() returns uuid
language sql stable
as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid$$;

create or replace function auth.role() returns text
language sql stable
as $$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), 'anon')$$;

create or replace function auth.email() returns text
language sql stable
as $$ select nullif(current_setting('request.jwt.claim.email', true), '')$$;

create table if not exists public.push_outbox (
  id bigserial primary key,
  url text not null,
  body jsonb not null,
  headers jsonb not null default '{}'::jsonb,
  timeout_ms integer,
  created_at timestamptz not null default now(),
  delivered_at timestamptz,
  attempts integer not null default 0,
  last_error text
);

create index if not exists push_outbox_pending_idx
  on public.push_outbox (created_at)
  where delivered_at is null;

alter table public.push_outbox enable row level security;

revoke all on table public.push_outbox from public;
revoke all on sequence public.push_outbox_id_seq from public;

create or replace function net.http_post(
  url text,
  body jsonb default '{}'::jsonb,
  params jsonb default '{}'::jsonb,
  headers jsonb default '{}'::jsonb,
  timeout_milliseconds integer default 5000
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
begin
  insert into public.push_outbox (url, body, headers, timeout_ms)
  values (url, body, headers, timeout_milliseconds)
  returning id into v_id;
  return v_id;
end;
$$;

comment on function net.http_post(text, jsonb, jsonb, jsonb, integer) is
  'Stand-in for pg_net on a database that does not have it. Same named '
  'parameters as pg_net''s http_post so migrations 0041/0042 call it '
  'unmodified, but it queues the request in public.push_outbox instead of '
  'sending it. Something outside the database drains that table.';

revoke all on function net.http_post(text, jsonb, jsonb, jsonb, integer) from public;

create table if not exists net._http_response (
  id bigint primary key,
  status_code integer,
  content text,
  error_msg text,
  created timestamptz not null default now()
);

revoke all on table net._http_response from public;
