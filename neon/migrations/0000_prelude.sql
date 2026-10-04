-- neon/migrations/0000_prelude.sql
--
-- Run this FIRST, before any of supabase/migrations/, on a bare Neon (or
-- other non-Supabase) Postgres database. Then the whole chain in
-- supabase/migrations/ replays unmodified, and 0001_auth_shim.sql cleans up
-- after it.
--
-- WHY THIS FILE HAS TO EXIST
--
-- neon/README.md used to say "apply every migration in supabase/migrations/
-- exactly as-is — that whole chain is portable". Measured against the real
-- chain (0001–0050) on a bare Postgres 16, it is not, in four specific
-- ways. Every one of them is something Supabase provides that Neon does
-- not, and every one of them aborts the replay rather than degrading:
--
--   1. The roles `anon`, `authenticated` and `service_role`. These are
--      PostgREST's roles, created by Supabase. The chain issues 90 `grant
--      ... to authenticated` and 10 `to anon` statements; the first one
--      fails with `role "authenticated" does not exist`.
--   2. The `extensions` schema. Supabase installs pgcrypto/pg_trgm there
--      and puts it on the database's search_path, and several functions in
--      the chain are declared `set search_path = public, extensions`.
--   3. `auth.users`, plus `auth.uid()`. One foreign key points at it
--      (`profiles.profiles_id_fkey`) and one trigger fires on it
--      (`on_auth_user_created`). The shim removes both afterwards, but they
--      have to be creatable for the chain to replay at all.
--   4. `pg_net`. Not available on Neon at all — confirmed against Neon's
--      extension list, where pg_net, pgsodium and http are all absent.
--      Migration 0041 does `create extension pg_net` and aborts.
--
-- The approach throughout is the same one that made the auth.uid() shim
-- work: keep the call sites and change what backs them. Nothing in
-- supabase/migrations/ is edited, so the chain stays a single source of
-- truth for both databases and a future migration does not have to be
-- written twice.
--
-- SAFETY: this file is for a bare Neon/Postgres database only. It is
-- harmless-looking but it creates a fake `net.http_post`, so the guard
-- below refuses to run against a real Supabase database, exactly as
-- 0001_auth_shim.sql does.

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
end $$;

-- ── 1. the schemas the chain writes into ────────────────────────────────

create schema if not exists extensions;
create schema if not exists auth;
create schema if not exists net;

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;

-- PostGIS installs into public and brings ~590 C functions, the
-- spatial_ref_sys table and two views with it. It is needed only by
-- migration 0044 (region boundaries), which nothing in the application
-- references any more — the maps are drawn client-side with Leaflet, and
-- the boundary columns and region_for_point() are dead. Leave this
-- commented out and 0044 will fail; see step 2 of the runbook, which drops
-- 0044's objects on Supabase BEFORE the migration so the question does not
-- arise. Uncomment only if you decide to keep boundaries.
-- create extension if not exists postgis;

-- Supabase puts `extensions` on the database search_path; several functions
-- in the chain inherit that assumption via `set search_path = public,
-- extensions`. Harmless to mirror, and it keeps those functions resolving
-- the same way they do today.
do $$
begin
  execute format(
    'alter database %I set search_path = public, extensions',
    current_database()
  );
end $$;

-- And for THIS session as well, which the line above does not cover: ALTER
-- DATABASE sets a default that new connections pick up, so a run that
-- applies the prelude and the rest of the chain in one session never sees
-- it. Migration 0004 then fails on
--
--   operator class "gin_trgm_ops" does not exist for access method "gin"
--
-- because gin_trgm_ops lives in the extensions schema and nothing has put
-- that schema on the path yet. That is exactly what happens when the whole
-- chain is pasted into a SQL editor, which is the normal way to set this up.
set search_path = public, extensions;

-- ── 2. PostgREST's roles, as placeholders only ──────────────────────────
--
-- Created NOLOGIN, with no password, purely so the chain's grants resolve.
-- 0001_auth_shim.sql revokes everything from them and drops them again, so
-- they do not survive into the running system. Nothing can authenticate as
-- them in the meantime: no password is ever set, here or anywhere.
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
end $$;

grant usage on schema public, extensions to anon, authenticated, service_role;

-- ── 3. auth.users, as a shell ───────────────────────────────────────────
--
-- Only the columns the chain actually touches. GoTrue's real table has
-- dozens more; none of them are referenced by anything in
-- supabase/migrations/, which was checked column by column. Deliberately
-- WITHOUT encrypted_password: no password hash is ever stored on Neon in
-- this table, so a half-finished migration cannot leave credentials in a
-- place nothing guards. Phase 4 imports hashes into profiles.password_hash
-- instead, under RLS.
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  phone text,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- The chain's own auth.uid(), reading a JWT claim the way PostgREST sets
-- it. Replaced by 0001_auth_shim.sql with the app.current_profile_id
-- version; it exists here only so the chain's policies and function bodies
-- compile while replaying.
create or replace function auth.uid() returns uuid
language sql stable
as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

create or replace function auth.role() returns text
language sql stable
as $$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), 'anon') $$;

create or replace function auth.email() returns text
language sql stable
as $$ select nullif(current_setting('request.jwt.claim.email', true), '') $$;

-- ── 4. pg_net, replaced by an outbox ────────────────────────────────────
--
-- Migrations 0041/0042 push notifications by having a database trigger POST
-- the notification's id to /api/push/dispatch, using pg_net's async HTTP
-- client. Neon has no pg_net and no row-change webhook: its Function
-- Triggers fire on a schedule or on object storage, not on an INSERT.
--
-- So the transport changes and the call site does not. net.http_post() here
-- has pg_net's exact named-parameter signature as 0041/0042 call it, and
-- instead of opening a socket it writes the request to a durable outbox
-- table. Something then drains that table — see the runbook; the
-- recommended shape is the app firing the dispatch itself right after the
-- RPC returns (immediate, no polling delay) with a scheduled sweep of this
-- table as the safety net for anything that missed.
--
-- This is strictly more reliable than what it replaces, which is worth
-- saying plainly: pg_net fires and forgets inside a trigger, so a push lost
-- to a cold start or a 500 was lost silently. A row in a table can be
-- retried.
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

-- Only the undelivered rows are ever scanned, and they are the small
-- minority. A partial index keeps the sweep's cost proportional to the
-- backlog rather than to the history.
create index if not exists push_outbox_pending_idx
  on public.push_outbox (created_at)
  where delivered_at is null;

alter table public.push_outbox enable row level security;

-- No policies, so no ordinary session can read or write this table: the
-- rows carry the push webhook secret in their headers. Everything that
-- touches it goes through a SECURITY DEFINER function, the same pattern
-- app_settings and the two code tables already use.
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

-- pg_net records every response in net._http_response, and
-- /api/push/dispatch deliberately returns a diagnostic body so that table
-- can be read when push goes wrong (see the comment in route.ts). Keep a
-- table of the same name so that habit, and anything written against it,
-- still finds somewhere to look — now filled by the drainer rather than by
-- the extension.
create table if not exists net._http_response (
  id bigint primary key,
  status_code integer,
  content text,
  error_msg text,
  created timestamptz not null default now()
);

revoke all on table net._http_response from public;
