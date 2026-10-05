
set search_path = public, extensions;



-- ========== db/neon/0000_prelude.sql ==================================

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


-- ========== db/migrations/0001_extensions_and_enums.sql ===============

create extension if not exists pgcrypto;
create extension if not exists "uuid-ossp";
create extension if not exists pg_trgm;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'user_role') then
    create type user_role as enum ('owner', 'moderator', 'driver', 'factory');
  end if;
end$$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'order_status') then
    create type order_status as enum (
      'new',
      'assigned',
      'collected',
      'at_factory',
      'ready',
      'with_driver',
      'delivered',
      'refused',
      'cancelled'
    );
  end if;
end$$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'order_source') then
    create type order_source as enum ('website', 'messenger');
  end if;
end$$;


-- ========== db/migrations/0002_profiles.sql ===========================

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null,
  phone text,
  role user_role not null default 'driver',
  region_id uuid,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is 'Application user profile + role, one per auth.users row.';

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists set_profiles_updated_at on public.profiles;
create trigger set_profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, phone, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.email, 'مستخدم جديد'),
    new.raw_user_meta_data ->> 'phone',
    coalesce((new.raw_user_meta_data ->> 'role')::user_role, 'driver')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.current_user_role()
returns user_role
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

create or replace function public.is_owner()
returns boolean language sql stable security definer set search_path = public as $$
  select public.current_user_role() = 'owner';
$$;

create or replace function public.is_owner_or_moderator()
returns boolean language sql stable security definer set search_path = public as $$
  select public.current_user_role() in ('owner', 'moderator');
$$;


-- ========== db/migrations/0003_regions_and_driver_regions.sql =========

create table if not exists public.regions (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  created_at timestamptz not null default now()
);

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'profiles_region_id_fkey'
  ) then
    alter table public.profiles
      add constraint profiles_region_id_fkey
      foreign key (region_id) references public.regions (id) on delete set null;
  end if;
end;
$$;

create table if not exists public.driver_regions (
  driver_id uuid not null references public.profiles (id) on delete cascade,
  region_id uuid not null references public.regions (id) on delete cascade,
  primary key (driver_id, region_id)
);

create index if not exists driver_regions_region_idx on public.driver_regions (region_id);


-- ========== db/migrations/0004_orders.sql =============================

create sequence if not exists public.order_number_seq start 1;

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique,
  source order_source not null default 'website',
  status order_status not null default 'new',

  customer_name text not null,
  customer_phone text not null,
  customer_address text not null,
  region_id uuid references public.regions (id),
  pieces_count integer not null default 1 check (pieces_count > 0),
  piece_details text,
  color text,
  work_required text,
  customer_notes text,

  assigned_driver_id uuid references public.profiles (id),
  suggested_driver_id uuid references public.profiles (id),
  distribution_approved_at timestamptz,
  distribution_approved_by uuid references public.profiles (id),

  collected_at timestamptz,
  factory_received_at timestamptz,
  factory_ready_at timestamptz,
  driver_pickup_at timestamptz,
  delivered_at timestamptz,
  refused_at timestamptz,
  refusal_reason text,
  cancelled_at timestamptz,
  cancel_reason text,

  delivery_code_hash text not null,
  delivery_code_last_attempt_at timestamptz,
  failed_code_attempts integer not null default 0,

  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists orders_status_idx on public.orders (status);
create index if not exists orders_region_idx on public.orders (region_id);
create index if not exists orders_driver_idx on public.orders (assigned_driver_id);
create index if not exists orders_created_at_idx on public.orders (created_at desc);
create index if not exists orders_customer_phone_idx on public.orders (customer_phone);
create index if not exists orders_search_idx on public.orders
  using gin (order_number gin_trgm_ops, customer_name gin_trgm_ops, customer_phone gin_trgm_ops);

drop trigger if exists set_orders_updated_at on public.orders;
create trigger set_orders_updated_at
  before update on public.orders
  for each row execute function public.set_updated_at();

create or replace function public.set_order_number()
returns trigger
language plpgsql
as $$
begin
  if new.order_number is null or new.order_number = '' then
    new.order_number := 'ORD-' || lpad(nextval('public.order_number_seq')::text, 4, '0');
  end if;
  return new;
end;
$$;

drop trigger if exists set_orders_order_number on public.orders;
create trigger set_orders_order_number
  before insert on public.orders
  for each row execute function public.set_order_number();

create or replace function public.order_sla_hours()
returns integer language sql immutable as $$ select 48$$;

create or replace function public.is_order_delayed(o public.orders)
returns boolean
language sql
stable
as $$
  select o.status not in ('delivered', 'cancelled', 'refused')
    and o.created_at < now() - (public.order_sla_hours() || ' hours')::interval;
$$;


-- ========== db/migrations/0005_order_history.sql ======================

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


-- ========== db/migrations/0006_notifications.sql ======================

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  order_id uuid references public.orders (id) on delete cascade,
  type text not null,
  title text not null,
  body text,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists notifications_user_idx on public.notifications (user_id, is_read, created_at desc);

create or replace function public.notify_user(
  p_user_id uuid,
  p_order_id uuid,
  p_type text,
  p_title text,
  p_body text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user_id is null then
    return;
  end if;

  insert into public.notifications (user_id, order_id, type, title, body)
  values (p_user_id, p_order_id, p_type, p_title, p_body);
end;
$$;

create or replace function public.notify_role(
  p_role user_role,
  p_order_id uuid,
  p_type text,
  p_title text,
  p_body text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user record;
begin
  for v_user in select id from public.profiles where role = p_role and is_active loop
    perform public.notify_user(v_user.id, p_order_id, p_type, p_title, p_body);
  end loop;
end;
$$;


-- ========== db/migrations/0007_order_creation.sql =====================

create or replace function public.generate_delivery_code()
returns text
language sql
volatile
as $$
  select lpad((floor(random() * 9000) + 1000)::int::text, 4, '0');
$$;

drop type if exists public.new_order_result cascade;

create type public.new_order_result as (
  order_id uuid,
  order_number text,
  delivery_code text
);

create or replace function public.create_order_internal(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text,
  p_color text,
  p_work_required text,
  p_customer_notes text,
  p_source order_source,
  p_created_by uuid
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := public.generate_delivery_code();
  v_order public.orders;
  v_result public.new_order_result;
begin
  if length(trim(p_customer_name)) = 0 then
    raise exception 'اسم العميل مطلوب' using errcode = '22023';
  end if;
  if length(trim(p_customer_phone)) < 8 then
    raise exception 'رقم هاتف العميل غير صالح' using errcode = '22023';
  end if;
  if p_pieces_count is null or p_pieces_count < 1 then
    raise exception 'عدد القطع يجب أن يكون 1 على الأقل' using errcode = '22023';
  end if;

  insert into public.orders (
    customer_name, customer_phone, customer_address, region_id,
    pieces_count, piece_details, color, work_required, customer_notes,
    source, created_by, delivery_code_hash
  ) values (
    trim(p_customer_name), trim(p_customer_phone), trim(p_customer_address), p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    p_source, p_created_by, crypt(v_code, gen_salt('bf'))
  )
  returning * into v_order;

  perform public.log_order_event(v_order.id, 'created', null, 'new',
    'تم إنشاء الأوردر عبر ' || case when p_source = 'website' then 'الموقع' else 'Messenger' end);

  perform public.notify_role('owner', v_order.id, 'new_order', 'أوردر جديد ' || v_order.order_number,
    'تم استلام أوردر جديد من ' || v_order.customer_name);

  v_result.order_id := v_order.id;
  v_result.order_number := v_order.order_number;
  v_result.delivery_code := v_code;
  return v_result;
end;
$$;

revoke all on function public.create_order_internal from public, anon, authenticated;

create or replace function public.public_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'website', null
  );
end;
$$;

revoke all on function public.public_create_order from public;
grant execute on function public.public_create_order to anon, authenticated;

create or replace function public.moderator_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح لك بإنشاء أوردر' using errcode = '42501';
  end if;

  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'messenger', auth.uid()
  );
end;
$$;

revoke all on function public.moderator_create_order from public;
grant execute on function public.moderator_create_order to authenticated;


-- ========== db/migrations/0008_rls_policies.sql =======================

alter table public.profiles enable row level security;

drop policy if exists profiles_select_self on public.profiles;
create policy profiles_select_self on public.profiles
  for select using (id = auth.uid());

drop policy if exists profiles_select_staff on public.profiles;
create policy profiles_select_staff on public.profiles
  for select using (public.is_owner_or_moderator());

drop policy if exists profiles_update_self_limited on public.profiles;
create policy profiles_update_self_limited on public.profiles
  for update using (id = auth.uid())
  with check (id = auth.uid());

drop policy if exists profiles_update_owner on public.profiles;
create policy profiles_update_owner on public.profiles
  for update using (public.is_owner())
  with check (public.is_owner());

drop policy if exists profiles_update_moderator on public.profiles;
create policy profiles_update_moderator on public.profiles
  for update using (public.current_user_role() = 'moderator' and role in ('driver', 'factory'))
  with check (public.current_user_role() = 'moderator' and role in ('driver', 'factory'));

create or replace function public.prevent_role_self_escalation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() = old.id and not public.is_owner() then
    if new.role is distinct from old.role or new.is_active is distinct from old.is_active then
      raise exception 'لا يمكنك تغيير الدور أو حالة التفعيل الخاصة بك' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_prevent_self_escalation on public.profiles;
create trigger profiles_prevent_self_escalation
  before update on public.profiles
  for each row execute function public.prevent_role_self_escalation();

alter table public.regions enable row level security;

drop policy if exists regions_select_all on public.regions;
create policy regions_select_all on public.regions
  for select using (true);

drop policy if exists regions_write_owner on public.regions;
create policy regions_write_owner on public.regions
  for all using (public.is_owner()) with check (public.is_owner());

alter table public.driver_regions enable row level security;

drop policy if exists driver_regions_select on public.driver_regions;
create policy driver_regions_select on public.driver_regions
  for select using (public.is_owner_or_moderator() or driver_id = auth.uid());

drop policy if exists driver_regions_write_owner on public.driver_regions;
create policy driver_regions_write_owner on public.driver_regions
  for all using (public.is_owner()) with check (public.is_owner());

drop policy if exists driver_regions_write_moderator on public.driver_regions;
create policy driver_regions_write_moderator on public.driver_regions
  for all using (public.current_user_role() = 'moderator')
  with check (public.current_user_role() = 'moderator');

alter table public.orders enable row level security;

drop policy if exists orders_select_staff on public.orders;
create policy orders_select_staff on public.orders
  for select using (public.is_owner_or_moderator());

drop policy if exists orders_select_driver on public.orders;
create policy orders_select_driver on public.orders
  for select using (
    assigned_driver_id = auth.uid()
    and distribution_approved_at is not null
    and public.current_user_role() = 'driver'
  );

drop policy if exists orders_select_factory on public.orders;
create policy orders_select_factory on public.orders
  for select using (
    public.current_user_role() = 'factory'
    and status in ('collected', 'at_factory', 'ready')
  );

drop policy if exists orders_insert_staff on public.orders;
create policy orders_insert_staff on public.orders
  for insert with check (public.is_owner_or_moderator());

drop policy if exists orders_update_owner on public.orders;
create policy orders_update_owner on public.orders
  for update using (public.is_owner()) with check (public.is_owner());

alter table public.order_history enable row level security;

drop policy if exists order_history_select_staff on public.order_history;
create policy order_history_select_staff on public.order_history
  for select using (public.is_owner_or_moderator());

drop policy if exists order_history_select_driver on public.order_history;
create policy order_history_select_driver on public.order_history
  for select using (
    exists (
      select 1 from public.orders o
      where o.id = order_history.order_id
        and o.assigned_driver_id = auth.uid()
        and o.distribution_approved_at is not null
    )
  );

drop policy if exists order_history_select_factory on public.order_history;
create policy order_history_select_factory on public.order_history
  for select using (
    public.current_user_role() = 'factory'
    and exists (
      select 1 from public.orders o
      where o.id = order_history.order_id
        and o.status in ('collected', 'at_factory', 'ready')
    )
  );

alter table public.notifications enable row level security;

drop policy if exists notifications_select_own on public.notifications;
create policy notifications_select_own on public.notifications
  for select using (user_id = auth.uid());

drop policy if exists notifications_update_own on public.notifications;
create policy notifications_update_own on public.notifications
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());


-- ========== db/migrations/0009_workflow_rpcs.sql ======================

create or replace function public.suggest_drivers(p_order_id uuid)
returns table (
  driver_id uuid,
  full_name text,
  covers_region boolean,
  active_orders_count bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_region_id uuid;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select region_id into v_region_id from public.orders where id = p_order_id;

  return query
    select
      p.id,
      p.full_name,
      exists (
        select 1 from public.driver_regions dr
        where dr.driver_id = p.id and dr.region_id = v_region_id
      ) as covers_region,
      (
        select count(*) from public.orders o
        where o.assigned_driver_id = p.id
          and o.status not in ('delivered', 'cancelled', 'refused')
      ) as active_orders_count
    from public.profiles p
    where p.role = 'driver' and p.is_active
    order by covers_region desc, active_orders_count asc, p.full_name asc;
end;
$$;

create or replace function public.set_order_distribution(p_order_id uuid, p_driver_id uuid, p_is_suggestion boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status order_status;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select status into v_status from public.orders where id = p_order_id for update;
  if v_status is null then
    raise exception 'الأوردر غير موجود';
  end if;
  if v_status <> 'new' then
    raise exception 'لا يمكن تعديل توزيع أوردر تم اعتماده بالفعل';
  end if;

  update public.orders
    set assigned_driver_id = p_driver_id,
        suggested_driver_id = case when p_is_suggestion then p_driver_id else suggested_driver_id end
    where id = p_order_id;

  perform public.log_order_event(p_order_id, 'distribution_set', v_status, v_status,
    'تم تحديد مندوب للتوزيع (بانتظار الاعتماد)');
end;
$$;

create or replace function public.clear_order_distribution(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status order_status;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select status into v_status from public.orders where id = p_order_id for update;
  if v_status <> 'new' then
    raise exception 'لا يمكن إلغاء توزيع أوردر تم اعتماده بالفعل';
  end if;

  update public.orders set assigned_driver_id = null where id = p_order_id;
  perform public.log_order_event(p_order_id, 'distribution_cleared', v_status, v_status, 'تم إلغاء التوزيع المقترح');
end;
$$;

create or replace function public.approve_distribution(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  if not public.is_owner() then
    raise exception 'اعتماد التوزيع من صلاحية Owner فقط' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then
    raise exception 'الأوردر غير موجود';
  end if;
  if v_order.status <> 'new' then
    raise exception 'الأوردر ليس في حالة تسمح باعتماد التوزيع';
  end if;
  if v_order.assigned_driver_id is null then
    raise exception 'لا يوجد مندوب محدد لهذا الأوردر';
  end if;

  update public.orders
    set status = 'assigned',
        distribution_approved_at = now(),
        distribution_approved_by = auth.uid()
    where id = p_order_id;

  perform public.log_order_event(p_order_id, 'distribution_approved', 'new', 'assigned', 'تم اعتماد التوزيع وإرسال الأوردر للمندوب');
  perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'order_assigned',
    'أوردر جديد تم إسناده إليك ' || v_order.order_number,
    'العميل: ' || v_order.customer_name);
end;
$$;

create or replace function public.driver_mark_collected(p_order_id uuid)
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
  if v_order.status <> 'assigned' then raise exception 'الأوردر ليس بحالة تسمح بتسجيل الاستلام من العميل'; end if;

  update public.orders set status = 'collected', collected_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'collected_from_customer', 'assigned', 'collected', 'تم استلام الأوردر من العميل');
end;
$$;

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

  perform public.log_order_event(p_order_id, 'handed_to_factory', 'collected', 'collected', 'المندوب توجه بالأوردر إلى المصنع');
end;
$$;

create or replace function public.driver_confirm_factory_pickup(p_order_id uuid)
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
  if v_order.status <> 'ready' then raise exception 'الأوردر ليس جاهزًا للاستلام من المصنع بعد'; end if;

  update public.orders set status = 'with_driver', driver_pickup_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'driver_picked_up_from_factory', 'ready', 'with_driver', 'استلم المندوب الأوردر من المصنع');
end;
$$;

create or replace function public.driver_deliver_to_customer(p_order_id uuid, p_code text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public.orders;
  v_ok boolean;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.assigned_driver_id <> auth.uid() then raise exception 'غير مصرح' using errcode = '42501'; end if;
  if v_order.status <> 'with_driver' then raise exception 'الأوردر ليس بحالة تسمح بالتسليم للعميل'; end if;

  v_ok := (crypt(coalesce(p_code, ''), v_order.delivery_code_hash) = v_order.delivery_code_hash);

  if v_ok then
    update public.orders set status = 'delivered', delivered_at = now() where id = p_order_id;
    perform public.log_order_event(p_order_id, 'delivered', 'with_driver', 'delivered', 'تم التسليم للعميل وتأكيد الكود بنجاح');
  else
    update public.orders
      set failed_code_attempts = failed_code_attempts + 1,
          delivery_code_last_attempt_at = now()
      where id = p_order_id;
    perform public.log_order_event(p_order_id, 'delivery_code_mismatch', 'with_driver', 'with_driver', 'محاولة تسليم بكود غير صحيح');
  end if;

  return v_ok;
end;
$$;

create or replace function public.driver_log_refusal(p_order_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  if length(trim(coalesce(p_reason, ''))) = 0 then
    raise exception 'يجب كتابة سبب رفض الاستلام';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.assigned_driver_id <> auth.uid() then raise exception 'غير مصرح' using errcode = '42501'; end if;
  if v_order.status <> 'with_driver' then raise exception 'الأوردر ليس بحالة تسمح بتسجيل رفض الاستلام'; end if;

  update public.orders
    set status = 'refused', refused_at = now(), refusal_reason = trim(p_reason)
    where id = p_order_id;

  perform public.log_order_event(p_order_id, 'refused', 'with_driver', 'refused', p_reason);
  perform public.notify_role('owner', p_order_id, 'order_refused', 'رفض استلام أوردر ' || v_order.order_number, p_reason);
end;
$$;

create or replace function public.factory_confirm_receipt(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  if public.current_user_role() not in ('factory', 'owner', 'moderator') then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status <> 'collected' then raise exception 'الأوردر ليس بحالة تسمح بتأكيد الاستلام في المصنع'; end if;

  update public.orders set status = 'at_factory', factory_received_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'factory_confirmed_receipt', 'collected', 'at_factory', 'المصنع أكد استلام الأوردر');
  perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'factory_received',
    'تم استلام الأوردر ' || v_order.order_number || ' في المصنع', null);
end;
$$;

create or replace function public.factory_mark_ready(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  if public.current_user_role() not in ('factory', 'owner', 'moderator') then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status <> 'at_factory' then raise exception 'الأوردر ليس داخل المصنع حاليًا'; end if;

  update public.orders set status = 'ready', factory_ready_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'factory_marked_ready', 'at_factory', 'ready', 'المصنع أنهى العمل والأوردر جاهز للتسليم');
  perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'ready_for_pickup',
    'أوردر ' || v_order.order_number || ' جاهز للتسليم', 'يمكنك استلامه من المصنع الآن');
end;
$$;

create or replace function public.owner_cancel_order(p_order_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status in ('delivered', 'cancelled') then
    raise exception 'لا يمكن إلغاء أوردر تم تسليمه أو ملغى بالفعل';
  end if;

  update public.orders set status = 'cancelled', cancelled_at = now(), cancel_reason = p_reason where id = p_order_id;
  perform public.log_order_event(p_order_id, 'cancelled', v_order.status, 'cancelled', p_reason);
end;
$$;

drop type if exists public.tracked_order cascade;

create type public.tracked_order as (
  order_number text,
  status order_status,
  pieces_count integer,
  created_at timestamptz,
  collected_at timestamptz,
  factory_received_at timestamptz,
  factory_ready_at timestamptz,
  driver_pickup_at timestamptz,
  delivered_at timestamptz,
  refused_at timestamptz,
  is_delayed boolean
);

create or replace function public.track_order(p_order_number text, p_phone text)
returns public.tracked_order
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_result public.tracked_order;
  v_digits_input text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  select * into v_order
  from public.orders o
  where upper(o.order_number) = upper(trim(coalesce(p_order_number, '')))
    and right(regexp_replace(o.customer_phone, '\D', '', 'g'), 8) = right(v_digits_input, 8)
  limit 1;

  if v_order is null then
    return null;
  end if;

  v_result.order_number := v_order.order_number;
  v_result.status := v_order.status;
  v_result.pieces_count := v_order.pieces_count;
  v_result.created_at := v_order.created_at;
  v_result.collected_at := v_order.collected_at;
  v_result.factory_received_at := v_order.factory_received_at;
  v_result.factory_ready_at := v_order.factory_ready_at;
  v_result.driver_pickup_at := v_order.driver_pickup_at;
  v_result.delivered_at := v_order.delivered_at;
  v_result.refused_at := v_order.refused_at;
  v_result.is_delayed := public.is_order_delayed(v_order);
  return v_result;
end;
$$;

revoke all on function public.track_order from public;
grant execute on function public.track_order to anon, authenticated;

revoke all on function public.suggest_drivers(uuid) from public;
revoke all on function public.set_order_distribution(uuid, uuid, boolean) from public;
revoke all on function public.clear_order_distribution(uuid) from public;
revoke all on function public.approve_distribution(uuid) from public;
revoke all on function public.driver_mark_collected(uuid) from public;
revoke all on function public.driver_hand_to_factory(uuid) from public;
revoke all on function public.driver_confirm_factory_pickup(uuid) from public;
revoke all on function public.driver_deliver_to_customer(uuid, text) from public;
revoke all on function public.driver_log_refusal(uuid, text) from public;
revoke all on function public.factory_confirm_receipt(uuid) from public;
revoke all on function public.factory_mark_ready(uuid) from public;
revoke all on function public.owner_cancel_order(uuid, text) from public;

grant execute on function public.suggest_drivers(uuid) to authenticated;
grant execute on function public.set_order_distribution(uuid, uuid, boolean) to authenticated;
grant execute on function public.clear_order_distribution(uuid) to authenticated;
grant execute on function public.approve_distribution(uuid) to authenticated;
grant execute on function public.driver_mark_collected(uuid) to authenticated;
grant execute on function public.driver_hand_to_factory(uuid) to authenticated;
grant execute on function public.driver_confirm_factory_pickup(uuid) to authenticated;
grant execute on function public.driver_deliver_to_customer(uuid, text) to authenticated;
grant execute on function public.driver_log_refusal(uuid, text) to authenticated;
grant execute on function public.factory_confirm_receipt(uuid) to authenticated;
grant execute on function public.factory_mark_ready(uuid) to authenticated;
grant execute on function public.owner_cancel_order(uuid, text) to authenticated;


-- ========== db/migrations/0010_reporting_and_views.sql ================

create or replace view public.factory_orders_view
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
  o.collected_at,
  o.factory_received_at,
  o.factory_ready_at,
  o.created_at
from public.orders o
left join public.profiles p on p.id = o.assigned_driver_id
where o.status in ('collected', 'at_factory', 'ready')
  and public.current_user_role() in ('factory', 'owner', 'moderator');

create or replace function public.dashboard_stats()
returns table (
  total_orders bigint,
  new_orders bigint,
  assigned_orders bigint,
  collected_orders bigint,
  at_factory_orders bigint,
  ready_orders bigint,
  with_driver_orders bigint,
  delivered_orders bigint,
  refused_orders bigint,
  cancelled_orders bigint,
  delayed_orders bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    select
      count(*),
      count(*) filter (where status = 'new'),
      count(*) filter (where status = 'assigned'),
      count(*) filter (where status = 'collected'),
      count(*) filter (where status = 'at_factory'),
      count(*) filter (where status = 'ready'),
      count(*) filter (where status = 'with_driver'),
      count(*) filter (where status = 'delivered'),
      count(*) filter (where status = 'refused'),
      count(*) filter (where status = 'cancelled'),
      count(*) filter (where public.is_order_delayed(orders.*))
    from public.orders;
end;
$$;

drop function if exists public.daily_report(date);

create function public.daily_report(p_day date default current_date)
returns table (
  new_orders bigint,
  collected_orders bigint,
  entered_factory bigint,
  in_factory_now bigint,
  ready_now bigint,
  exited_factory bigint,
  delivered_orders bigint,
  delayed_orders bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    select
      count(*) filter (where created_at::date = p_day),
      count(*) filter (where collected_at::date = p_day),
      count(*) filter (where factory_received_at::date = p_day),
      count(*) filter (where status = 'at_factory'),
      count(*) filter (where status = 'ready'),
      count(*) filter (where driver_pickup_at::date = p_day),
      count(*) filter (where delivered_at::date = p_day),
      count(*) filter (where public.is_order_delayed(orders.*))
    from public.orders;
end;
$$;

drop function if exists public.monthly_report(date);

create function public.monthly_report(p_month date default current_date)
returns table (
  total_orders bigint,
  total_pieces bigint,
  completed_orders bigint,
  delayed_orders bigint,
  avg_completion_hours numeric,
  on_time_rate numeric,
  prev_total_orders bigint,
  prev_completed_orders bigint,
  orders_change_percent numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_end date := (date_trunc('month', p_month) + interval '1 month')::date;
  v_prev_start date := (date_trunc('month', p_month) - interval '1 month')::date;
  v_prev_end date := v_start;
  v_total bigint;
  v_prev_total bigint;
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  select count(*) into v_total from public.orders where created_at >= v_start and created_at < v_end;
  select count(*) into v_prev_total from public.orders where created_at >= v_prev_start and created_at < v_prev_end;

  return query
    select
      v_total,
      coalesce((select sum(pieces_count) from public.orders where created_at >= v_start and created_at < v_end), 0),
      (select count(*) from public.orders where created_at >= v_start and created_at < v_end and status = 'delivered'),
      (select count(*) from public.orders where created_at >= v_start and created_at < v_end and public.is_order_delayed(orders.*)),
      (select round(avg(extract(epoch from (delivered_at - created_at)) / 3600.0), 1)
         from public.orders
         where created_at >= v_start and created_at < v_end and status = 'delivered'),
      (select round(
          100.0 * count(*) filter (where delivered_at <= created_at + (public.order_sla_hours() || ' hours')::interval)
          / nullif(count(*), 0),
          1
        )
        from public.orders
        where created_at >= v_start and created_at < v_end and status = 'delivered'),
      v_prev_total,
      (select count(*) from public.orders where created_at >= v_prev_start and created_at < v_prev_end and status = 'delivered'),
      case when v_prev_total = 0 then null else round(100.0 * (v_total - v_prev_total) / v_prev_total, 1) end;
end;
$$;

create or replace function public.delayed_orders_report()
returns table (
  id uuid,
  order_number text,
  customer_name text,
  region_name text,
  driver_name text,
  status order_status,
  created_at timestamptz,
  hours_open numeric
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    select
      o.id, o.order_number, o.customer_name, r.name, p.full_name, o.status, o.created_at,
      round(extract(epoch from (now() - o.created_at)) / 3600.0, 1)
    from public.orders o
    left join public.regions r on r.id = o.region_id
    left join public.profiles p on p.id = o.assigned_driver_id
    where public.is_order_delayed(o.*)
    order by o.created_at asc;
end;
$$;

create or replace function public.top_regions_report()
returns table (region_name text, order_count bigint)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    select coalesce(r.name, 'غير محدد'), count(*)
    from public.orders o
    left join public.regions r on r.id = o.region_id
    group by r.name
    order by count(*) desc;
end;
$$;

revoke all on function public.dashboard_stats() from public;
revoke all on function public.daily_report(date) from public;
revoke all on function public.monthly_report(date) from public;
revoke all on function public.delayed_orders_report() from public;
revoke all on function public.top_regions_report() from public;

grant execute on function public.dashboard_stats() to authenticated;
grant execute on function public.daily_report(date) to authenticated;
grant execute on function public.monthly_report(date) to authenticated;
grant execute on function public.delayed_orders_report() to authenticated;
grant execute on function public.top_regions_report() to authenticated;


-- ========== db/migrations/0011_table_grants.sql =======================

grant usage on schema public to anon, authenticated;

grant select, update on public.profiles to authenticated;

grant select on public.regions to anon, authenticated;
grant insert, update, delete on public.regions to authenticated;

grant select, insert, update, delete on public.driver_regions to authenticated;

grant select, insert, update on public.orders to authenticated;

grant select on public.order_history to authenticated;

grant select, update on public.notifications to authenticated;

grant select on public.factory_orders_view to authenticated;


-- ========== db/migrations/0012_seed_egypt_regions.sql =================

insert into public.regions (name) values
  ('القاهرة'),
  ('الجيزة'),
  ('الإسكندرية'),
  ('الدقهلية'),
  ('البحر الأحمر'),
  ('البحيرة'),
  ('الفيوم'),
  ('الغربية'),
  ('الإسماعيلية'),
  ('المنوفية'),
  ('المنيا'),
  ('القليوبية'),
  ('الوادي الجديد'),
  ('السويس'),
  ('أسوان'),
  ('أسيوط'),
  ('بني سويف'),
  ('بورسعيد'),
  ('دمياط'),
  ('الشرقية'),
  ('جنوب سيناء'),
  ('كفر الشيخ'),
  ('مطروح'),
  ('الأقصر'),
  ('قنا'),
  ('شمال سيناء'),
  ('سوهاج')
on conflict (name) do nothing;


-- ========== db/migrations/0013_driver_reassignment_and_login.sql ======

create or replace function public.reassign_order_driver(p_order_id uuid, p_new_driver_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_new_driver public.profiles;
  v_old_driver_name text;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status in ('delivered', 'cancelled', 'refused') then
    raise exception 'لا يمكن تغيير المندوب لأوردر منتهٍ';
  end if;

  select * into v_new_driver from public.profiles where id = p_new_driver_id;
  if v_new_driver is null or v_new_driver.role <> 'driver' or not v_new_driver.is_active then
    raise exception 'المندوب المحدد غير صالح';
  end if;
  if v_order.assigned_driver_id = p_new_driver_id then
    raise exception 'هذا المندوب مسؤول عن الأوردر بالفعل';
  end if;

  if v_order.assigned_driver_id is not null then
    select full_name into v_old_driver_name from public.profiles where id = v_order.assigned_driver_id;
  end if;

  update public.orders set assigned_driver_id = p_new_driver_id where id = p_order_id;

  perform public.log_order_event(p_order_id, 'driver_reassigned', v_order.status, v_order.status,
    case when v_old_driver_name is not null
      then 'تم تغيير المندوب من ' || v_old_driver_name || ' إلى ' || v_new_driver.full_name
      else 'تم تعيين مندوب: ' || v_new_driver.full_name
    end);

  if v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'reassigned_away',
      'تم نقل الأوردر ' || v_order.order_number || ' إلى مندوب آخر', null);
  end if;

  if v_order.status <> 'new' then
    perform public.notify_user(p_new_driver_id, p_order_id, 'order_assigned',
      'تم إسناد أوردر إليك ' || v_order.order_number, 'العميل: ' || v_order.customer_name);
  end if;
end;
$$;

revoke all on function public.reassign_order_driver from public;
grant execute on function public.reassign_order_driver to authenticated;

alter table public.profiles add column if not exists password_set boolean not null default true;

comment on column public.profiles.password_set is
  'false right after an Owner/Moderator creates the account (or resets its password) — the worker must set their own password on next login before signing in.';

create unique index if not exists profiles_phone_unique_idx on public.profiles (phone) where phone is not null;

drop function if exists public.driver_performance_report();

create function public.driver_performance_report()
returns table (
  driver_id uuid,
  full_name text,
  total_orders bigint,
  completed_orders bigint,
  delayed_orders bigint,
  active_orders bigint,
  avg_completion_hours numeric,
  on_time_rate numeric,
  refusal_count bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    select
      p.id,
      p.full_name,
      count(o.id),
      count(o.id) filter (where o.status = 'delivered'),
      count(o.id) filter (where public.is_order_delayed(o.*)),
      count(o.id) filter (where o.status not in ('delivered', 'cancelled', 'refused')),
      round(avg(extract(epoch from (o.delivered_at - o.created_at)) / 3600.0) filter (where o.status = 'delivered'), 1),
      round(
        100.0 * count(o.id) filter (where o.status = 'delivered' and o.delivered_at <= o.created_at + (public.order_sla_hours() || ' hours')::interval)
        / nullif(count(o.id) filter (where o.status = 'delivered'), 0),
        1
      ),
      count(o.id) filter (where o.status = 'refused')
    from public.profiles p
    left join public.orders o on o.assigned_driver_id = p.id
    where p.role = 'driver'
    group by p.id, p.full_name
    order by p.full_name;
end;
$$;

revoke all on function public.driver_performance_report() from public;
grant execute on function public.driver_performance_report() to authenticated;


-- ========== db/migrations/0014_driver_approval_fix_and_factory_assignment.sql 

create or replace function public.reassign_order_driver(p_order_id uuid, p_new_driver_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_new_driver public.profiles;
  v_old_driver_name text;
  v_new_status public.order_status;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status in ('delivered', 'cancelled', 'refused') then
    raise exception 'لا يمكن تغيير المندوب لأوردر منتهٍ';
  end if;

  select * into v_new_driver from public.profiles where id = p_new_driver_id;
  if v_new_driver is null or v_new_driver.role <> 'driver' or not v_new_driver.is_active then
    raise exception 'المندوب المحدد غير صالح';
  end if;
  if v_order.assigned_driver_id = p_new_driver_id then
    raise exception 'هذا المندوب مسؤول عن الأوردر بالفعل';
  end if;

  if v_order.assigned_driver_id is not null then
    select full_name into v_old_driver_name from public.profiles where id = v_order.assigned_driver_id;
  end if;

  v_new_status := case when v_order.status = 'new' then 'assigned' else v_order.status end;

  update public.orders
    set assigned_driver_id = p_new_driver_id,
        distribution_approved_at = coalesce(distribution_approved_at, now()),
        distribution_approved_by = coalesce(distribution_approved_by, auth.uid()),
        status = v_new_status
    where id = p_order_id;

  perform public.log_order_event(p_order_id, 'driver_reassigned', v_order.status, v_new_status,
    case when v_old_driver_name is not null
      then 'تم تغيير المندوب من ' || v_old_driver_name || ' إلى ' || v_new_driver.full_name
      else 'تم تعيين مندوب: ' || v_new_driver.full_name
    end);

  if v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'reassigned_away',
      'تم نقل الأوردر ' || v_order.order_number || ' إلى مندوب آخر', null);
  end if;

  perform public.notify_user(p_new_driver_id, p_order_id, 'order_assigned',
    'تم إسناد أوردر إليك ' || v_order.order_number, 'العميل: ' || v_order.customer_name);
end;
$$;

alter table public.orders add column if not exists assigned_factory_id uuid references public.profiles (id);
create index if not exists orders_factory_idx on public.orders (assigned_factory_id);

comment on column public.orders.assigned_factory_id is
  'Optional: which factory account this order is routed to, set at creation. NULL means unassigned — visible to every factory account, same as before this column existed.';

drop function if exists public.create_order_internal(text, text, text, uuid, integer, text, text, text, text, order_source, uuid);
drop function if exists public.public_create_order(text, text, text, uuid, integer, text, text, text, text);
drop function if exists public.moderator_create_order(text, text, text, uuid, integer, text, text, text, text);

create or replace function public.create_order_internal(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text,
  p_color text,
  p_work_required text,
  p_customer_notes text,
  p_source order_source,
  p_created_by uuid,
  p_factory_id uuid default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := public.generate_delivery_code();
  v_order public.orders;
  v_result public.new_order_result;
  v_factory public.profiles;
begin
  if length(trim(p_customer_name)) = 0 then
    raise exception 'اسم العميل مطلوب' using errcode = '22023';
  end if;
  if length(trim(p_customer_phone)) < 8 then
    raise exception 'رقم هاتف العميل غير صالح' using errcode = '22023';
  end if;
  if p_pieces_count is null or p_pieces_count < 1 then
    raise exception 'عدد القطع يجب أن يكون 1 على الأقل' using errcode = '22023';
  end if;

  if p_factory_id is not null then
    select * into v_factory from public.profiles where id = p_factory_id;
    if v_factory is null or v_factory.role <> 'factory' or not v_factory.is_active then
      raise exception 'المصنع المحدد غير صالح' using errcode = '22023';
    end if;
  end if;

  insert into public.orders (
    customer_name, customer_phone, customer_address, region_id,
    pieces_count, piece_details, color, work_required, customer_notes,
    source, created_by, delivery_code_hash, assigned_factory_id
  ) values (
    trim(p_customer_name), trim(p_customer_phone), trim(p_customer_address), p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    p_source, p_created_by, crypt(v_code, gen_salt('bf')), p_factory_id
  )
  returning * into v_order;

  perform public.log_order_event(v_order.id, 'created', null, 'new',
    'تم إنشاء الأوردر عبر ' || case when p_source = 'website' then 'الموقع' else 'Messenger' end);

  perform public.notify_role('owner', v_order.id, 'new_order', 'أوردر جديد ' || v_order.order_number,
    'تم استلام أوردر جديد من ' || v_order.customer_name);

  v_result.order_id := v_order.id;
  v_result.order_number := v_order.order_number;
  v_result.delivery_code := v_code;
  return v_result;
end;
$$;

revoke all on function public.create_order_internal from public, anon, authenticated;

create or replace function public.public_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null,
  p_factory_id uuid default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'website', null, p_factory_id
  );
end;
$$;

revoke all on function public.public_create_order from public;
grant execute on function public.public_create_order to anon, authenticated;

create or replace function public.moderator_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null,
  p_factory_id uuid default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح لك بإنشاء أوردر' using errcode = '42501';
  end if;

  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'messenger', auth.uid(), p_factory_id
  );
end;
$$;

revoke all on function public.moderator_create_order from public;
grant execute on function public.moderator_create_order to authenticated;

drop policy if exists orders_select_factory on public.orders;
create policy orders_select_factory on public.orders
  for select using (
    public.current_user_role() = 'factory'
    and status in ('collected', 'at_factory', 'ready')
    and (assigned_factory_id is null or assigned_factory_id = auth.uid())
  );

drop policy if exists order_history_select_factory on public.order_history;
create policy order_history_select_factory on public.order_history
  for select using (
    public.current_user_role() = 'factory'
    and exists (
      select 1 from public.orders o
      where o.id = order_history.order_id
        and o.status in ('collected', 'at_factory', 'ready')
        and (o.assigned_factory_id is null or o.assigned_factory_id = auth.uid())
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
  o.collected_at,
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


-- ========== db/migrations/0015_factory_location_and_handoff_tracking.sql 

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


-- ========== db/migrations/0016_mandatory_assignment_delivery_code_and_geo.sql 

drop function if exists public.create_order_internal(text, text, text, uuid, integer, text, text, text, text, order_source, uuid, uuid);
drop function if exists public.moderator_create_order(text, text, text, uuid, integer, text, text, text, text, uuid);

create or replace function public.create_order_internal(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text,
  p_color text,
  p_work_required text,
  p_customer_notes text,
  p_source order_source,
  p_created_by uuid,
  p_factory_id uuid default null,
  p_driver_id uuid default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := public.generate_delivery_code();
  v_order public.orders;
  v_result public.new_order_result;
  v_factory public.profiles;
  v_driver public.profiles;
  v_new_status public.order_status;
begin
  if length(trim(p_customer_name)) = 0 then
    raise exception 'اسم العميل مطلوب' using errcode = '22023';
  end if;
  if length(trim(p_customer_phone)) < 8 then
    raise exception 'رقم هاتف العميل غير صالح' using errcode = '22023';
  end if;
  if p_pieces_count is null or p_pieces_count < 1 then
    raise exception 'عدد القطع يجب أن يكون 1 على الأقل' using errcode = '22023';
  end if;

  if p_factory_id is not null then
    select * into v_factory from public.profiles where id = p_factory_id;
    if v_factory is null or v_factory.role <> 'factory' or not v_factory.is_active then
      raise exception 'المصنع المحدد غير صالح' using errcode = '22023';
    end if;
  end if;

  if p_driver_id is not null then
    select * into v_driver from public.profiles where id = p_driver_id;
    if v_driver is null or v_driver.role <> 'driver' or not v_driver.is_active then
      raise exception 'المندوب المحدد غير صالح' using errcode = '22023';
    end if;
  end if;

  insert into public.orders (
    customer_name, customer_phone, customer_address, region_id,
    pieces_count, piece_details, color, work_required, customer_notes,
    source, created_by, delivery_code_hash, assigned_factory_id
  ) values (
    trim(p_customer_name), trim(p_customer_phone), trim(p_customer_address), p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    p_source, p_created_by, crypt(v_code, gen_salt('bf')), p_factory_id
  )
  returning * into v_order;

  insert into public.order_delivery_codes (order_id, code) values (v_order.id, v_code);

  perform public.log_order_event(v_order.id, 'created', null, 'new',
    'تم إنشاء الأوردر عبر ' || case when p_source = 'website' then 'الموقع' else 'Messenger' end);

  if p_driver_id is not null then
    v_new_status := case when v_order.status = 'new' then 'assigned' else v_order.status end;

    update public.orders
      set assigned_driver_id = p_driver_id,
          distribution_approved_at = now(),
          distribution_approved_by = p_created_by,
          status = v_new_status
      where id = v_order.id;

    v_order.status := v_new_status;

    perform public.log_order_event(v_order.id, 'driver_reassigned', 'new', v_new_status,
      'تم تعيين مندوب عند إنشاء الأوردر: ' || v_driver.full_name);

    perform public.notify_user(p_driver_id, v_order.id, 'order_assigned',
      'تم إسناد أوردر إليك ' || v_order.order_number, 'العميل: ' || v_order.customer_name);
  end if;

  perform public.notify_role('owner', v_order.id, 'new_order', 'أوردر جديد ' || v_order.order_number,
    'تم استلام أوردر جديد من ' || v_order.customer_name);

  v_result.order_id := v_order.id;
  v_result.order_number := v_order.order_number;
  v_result.delivery_code := v_code;
  return v_result;
end;
$$;

revoke all on function public.create_order_internal from public, anon, authenticated;

create or replace function public.moderator_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null,
  p_factory_id uuid default null,
  p_driver_id uuid default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح لك بإنشاء أوردر' using errcode = '42501';
  end if;

  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'messenger', auth.uid(), p_factory_id, p_driver_id
  );
end;
$$;

revoke all on function public.moderator_create_order from public;
grant execute on function public.moderator_create_order to authenticated;

create table if not exists public.order_delivery_codes (
  order_id uuid primary key references public.orders (id) on delete cascade,
  code text not null,
  created_at timestamptz not null default now()
);

comment on table public.order_delivery_codes is
  'Plaintext delivery codes, kept separately from orders (which is read via
   select("*") all over the app, including by drivers) so the code stays
   reachable only through get_order_delivery_code() below. RLS is enabled
   with no policies at all: every direct client request is denied by
   default, by design — the only legitimate path in is that function.';

alter table public.order_delivery_codes enable row level security;
revoke all on public.order_delivery_codes from public, anon, authenticated;

create or replace function public.get_order_delivery_code(p_order_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select code into v_code from public.order_delivery_codes where order_id = p_order_id;
  return v_code;
end;
$$;

revoke all on function public.get_order_delivery_code from public;
grant execute on function public.get_order_delivery_code to authenticated;

alter table public.profiles add column if not exists lat double precision;
alter table public.profiles add column if not exists lng double precision;

comment on column public.profiles.lat is 'Only meaningful for role=''factory'' — set alongside address, powers the precise Maps link and the Leaflet map/pin. Null means no pin yet (falls back to a text-address Maps search).';
comment on column public.profiles.lng is 'See profiles.lat.';

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, phone, role, address, lat, lng)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.email, 'مستخدم جديد'),
    new.raw_user_meta_data ->> 'phone',
    coalesce((new.raw_user_meta_data ->> 'role')::user_role, 'driver'),
    new.raw_user_meta_data ->> 'address',
    nullif(new.raw_user_meta_data ->> 'lat', '')::double precision,
    nullif(new.raw_user_meta_data ->> 'lng', '')::double precision
  )
  on conflict (id) do nothing;
  return new;
end;
$$;


-- ========== db/migrations/0017_track_order_setof_return.sql ===========

drop function if exists public.track_order(text, text);

create or replace function public.track_order(p_order_number text, p_phone text)
returns setof public.tracked_order
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_result public.tracked_order;
  v_digits_input text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  select * into v_order
  from public.orders o
  where upper(o.order_number) = upper(trim(coalesce(p_order_number, '')))
    and right(regexp_replace(o.customer_phone, '\D', '', 'g'), 8) = right(v_digits_input, 8)
  limit 1;

  if v_order is null then
    return;
  end if;

  v_result.order_number := v_order.order_number;
  v_result.status := v_order.status;
  v_result.pieces_count := v_order.pieces_count;
  v_result.created_at := v_order.created_at;
  v_result.collected_at := v_order.collected_at;
  v_result.factory_received_at := v_order.factory_received_at;
  v_result.factory_ready_at := v_order.factory_ready_at;
  v_result.driver_pickup_at := v_order.driver_pickup_at;
  v_result.delivered_at := v_order.delivered_at;
  v_result.refused_at := v_order.refused_at;
  v_result.is_delayed := public.is_order_delayed(v_order);
  return next v_result;
end;
$$;

revoke all on function public.track_order from public;
grant execute on function public.track_order to anon, authenticated;


-- ========== db/migrations/0018_factory_reassignment_delivery_codes_and_chat.sql 

create or replace function public.reassign_order_factory(p_order_id uuid, p_new_factory_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_new_factory public.profiles;
  v_old_factory_name text;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status in ('delivered', 'cancelled', 'refused') then
    raise exception 'لا يمكن تغيير المصنع لأوردر منتهٍ';
  end if;

  select * into v_new_factory from public.profiles where id = p_new_factory_id;
  if v_new_factory is null or v_new_factory.role <> 'factory' or not v_new_factory.is_active then
    raise exception 'المصنع المحدد غير صالح';
  end if;
  if v_order.assigned_factory_id = p_new_factory_id then
    raise exception 'هذا المصنع مخصص للأوردر بالفعل';
  end if;

  if v_order.assigned_factory_id is not null then
    select full_name into v_old_factory_name from public.profiles where id = v_order.assigned_factory_id;
  end if;

  update public.orders set assigned_factory_id = p_new_factory_id where id = p_order_id;

  perform public.log_order_event(p_order_id, 'factory_reassigned', v_order.status, v_order.status,
    case when v_old_factory_name is not null
      then 'تم تغيير المصنع من ' || v_old_factory_name || ' إلى ' || v_new_factory.full_name
      else 'تم تحديد المصنع: ' || v_new_factory.full_name
    end);

  if v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'factory_reassigned',
      'تم تغيير المصنع الخاص بالأوردر ' || v_order.order_number,
      'المصنع الجديد: ' || v_new_factory.full_name);
  end if;

  if v_order.status in ('collected', 'at_factory', 'ready') then
    perform public.notify_user(p_new_factory_id, p_order_id, 'order_assigned',
      'تم تخصيص أوردر لمصنعكم ' || v_order.order_number, null);
  end if;
end;
$$;

revoke all on function public.reassign_order_factory from public;
grant execute on function public.reassign_order_factory to authenticated;

create or replace function public.get_order_delivery_codes(p_order_ids uuid[])
returns table (order_id uuid, code text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  return query
    select c.order_id, c.code
    from public.order_delivery_codes c
    where c.order_id = any (p_order_ids);
end;
$$;

revoke all on function public.get_order_delivery_codes from public;
grant execute on function public.get_order_delivery_codes to authenticated;

create table if not exists public.order_messages (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  sender_id uuid not null references public.profiles (id),
  sender_role user_role not null,
  body text not null,
  created_at timestamptz not null default now()
);

create index if not exists order_messages_order_idx on public.order_messages (order_id, created_at);

alter table public.order_messages enable row level security;
revoke all on public.order_messages from public, anon, authenticated;

create policy order_messages_select on public.order_messages
  for select using (
    public.is_owner_or_moderator()
    or exists (
      select 1 from public.orders o
      where o.id = order_messages.order_id
        and o.assigned_driver_id = auth.uid()
    )
  );

grant select on public.order_messages to authenticated;

create or replace function public.send_order_message(p_order_id uuid, p_body text)
returns public.order_messages
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_role user_role := public.current_user_role();
  v_body text := trim(coalesce(p_body, ''));
  v_row public.order_messages;
begin
  if length(v_body) = 0 then
    raise exception 'اكتب رسالة قبل الإرسال' using errcode = '22023';
  end if;
  if length(v_body) > 1000 then
    raise exception 'الرسالة طويلة جدًا — بحد أقصى 1000 حرف' using errcode = '22023';
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if v_order is null then
    raise exception 'الأوردر غير موجود';
  end if;

  if not (
    public.is_owner_or_moderator()
    or (v_role = 'driver' and v_order.assigned_driver_id = auth.uid())
  ) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  insert into public.order_messages (order_id, sender_id, sender_role, body)
  values (p_order_id, auth.uid(), v_role, v_body)
  returning * into v_row;

  if v_role = 'driver' then
    perform public.notify_role('owner', p_order_id, 'chat_message',
      'رسالة جديدة على الأوردر ' || v_order.order_number, v_body);
    perform public.notify_role('moderator', p_order_id, 'chat_message',
      'رسالة جديدة على الأوردر ' || v_order.order_number, v_body);
  elsif v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'chat_message',
      'رسالة جديدة على الأوردر ' || v_order.order_number, v_body);
  end if;

  return v_row;
end;
$$;

revoke all on function public.send_order_message from public;
grant execute on function public.send_order_message to authenticated;


-- ========== db/migrations/0019_dual_channel_chat_and_full_step_notifications.sql 

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
  loop
    perform public.notify_user(v_user.id, p_order_id, p_type, p_title, p_body);
  end loop;
end;
$$;

revoke all on function public.notify_staff from public;

alter table public.order_messages add column if not exists channel text not null default 'driver';
alter table public.order_messages drop constraint if exists order_messages_channel_check;
alter table public.order_messages add constraint order_messages_channel_check check (channel in ('driver', 'factory'));

create index if not exists order_messages_order_channel_idx on public.order_messages (order_id, channel, created_at);

create or replace function public.can_read_order_channel(p_order_id uuid, p_channel text, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.orders o
    where o.id = p_order_id
      and (
        (p_channel = 'driver' and o.assigned_driver_id = p_user_id)
        or (p_channel = 'factory' and o.assigned_factory_id = p_user_id)
      )
  );
$$;

revoke all on function public.can_read_order_channel from public;
grant execute on function public.can_read_order_channel to authenticated;

drop policy if exists order_messages_select on public.order_messages;
create policy order_messages_select on public.order_messages
  for select using (
    public.is_owner_or_moderator()
    or public.can_read_order_channel(order_messages.order_id, order_messages.channel, auth.uid())
  );

drop function if exists public.send_order_message(uuid, text);

create or replace function public.send_order_message(p_order_id uuid, p_channel text, p_body text)
returns public.order_messages
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_role user_role := public.current_user_role();
  v_body text := trim(coalesce(p_body, ''));
  v_channel text := coalesce(p_channel, 'driver');
  v_row public.order_messages;
begin
  if v_channel not in ('driver', 'factory') then
    raise exception 'قناة دردشة غير صالحة';
  end if;
  if length(v_body) = 0 then
    raise exception 'اكتب رسالة قبل الإرسال' using errcode = '22023';
  end if;
  if length(v_body) > 1000 then
    raise exception 'الرسالة طويلة جدًا — بحد أقصى 1000 حرف' using errcode = '22023';
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if v_order is null then
    raise exception 'الأوردر غير موجود';
  end if;

  if not (
    public.is_owner_or_moderator()
    or (v_channel = 'driver' and v_role = 'driver' and v_order.assigned_driver_id = auth.uid())
    or (v_channel = 'factory' and v_role = 'factory' and v_order.assigned_factory_id = auth.uid())
  ) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  insert into public.order_messages (order_id, channel, sender_id, sender_role, body)
  values (p_order_id, v_channel, auth.uid(), v_role, v_body)
  returning * into v_row;

  if v_channel = 'driver' then
    if v_role = 'driver' then
      perform public.notify_staff(p_order_id, 'chat_message',
        'رسالة جديدة (دردشة المندوب) على الأوردر ' || v_order.order_number, v_body);
    elsif v_order.assigned_driver_id is not null then
      perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'chat_message',
        'رسالة جديدة على الأوردر ' || v_order.order_number, v_body);
    end if;
  else
    if v_role = 'factory' then
      perform public.notify_staff(p_order_id, 'chat_message',
        'رسالة جديدة (دردشة المصنع) على الأوردر ' || v_order.order_number, v_body);
    elsif v_order.assigned_factory_id is not null then
      perform public.notify_user(v_order.assigned_factory_id, p_order_id, 'chat_message',
        'رسالة جديدة على الأوردر ' || v_order.order_number, v_body);
    end if;
  end if;

  return v_row;
end;
$$;

revoke all on function public.send_order_message from public;
grant execute on function public.send_order_message to authenticated;

create or replace function public.driver_mark_collected(p_order_id uuid)
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
  if v_order.status <> 'assigned' then raise exception 'الأوردر ليس بحالة تسمح بتسجيل الاستلام من العميل'; end if;

  update public.orders set status = 'collected', collected_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'collected_from_customer', 'assigned', 'collected', 'تم استلام الأوردر من العميل');
  perform public.notify_staff(p_order_id, 'order_collected',
    'تم استلام الأوردر ' || v_order.order_number || ' من العميل', null, auth.uid());
end;
$$;

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
  perform public.notify_staff(p_order_id, 'driver_heading_to_factory',
    'المندوب في الطريق للمصنع — الأوردر ' || v_order.order_number, null, auth.uid());
  if v_order.assigned_factory_id is not null then
    perform public.notify_user(v_order.assigned_factory_id, p_order_id, 'driver_heading_to_factory',
      'مندوب في الطريق إليكم بالأوردر ' || v_order.order_number, null);
  end if;
end;
$$;

create or replace function public.driver_confirm_factory_pickup(p_order_id uuid)
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
  if v_order.status <> 'ready' then raise exception 'الأوردر ليس جاهزًا للاستلام من المصنع بعد'; end if;

  update public.orders set status = 'with_driver', driver_pickup_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'driver_picked_up_from_factory', 'ready', 'with_driver', 'استلم المندوب الأوردر من المصنع');
  perform public.notify_staff(p_order_id, 'driver_left_factory',
    'استلم المندوب الأوردر ' || v_order.order_number || ' من المصنع وغادر', null, auth.uid());
  if v_order.assigned_factory_id is not null then
    perform public.notify_user(v_order.assigned_factory_id, p_order_id, 'driver_left_factory',
      'المندوب استلم الأوردر ' || v_order.order_number || ' وغادر المصنع', null);
  end if;
end;
$$;

create or replace function public.driver_deliver_to_customer(p_order_id uuid, p_code text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public.orders;
  v_ok boolean;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.assigned_driver_id <> auth.uid() then raise exception 'غير مصرح' using errcode = '42501'; end if;
  if v_order.status <> 'with_driver' then raise exception 'الأوردر ليس بحالة تسمح بالتسليم للعميل'; end if;

  v_ok := (crypt(coalesce(p_code, ''), v_order.delivery_code_hash) = v_order.delivery_code_hash);

  if v_ok then
    update public.orders set status = 'delivered', delivered_at = now() where id = p_order_id;
    perform public.log_order_event(p_order_id, 'delivered', 'with_driver', 'delivered', 'تم التسليم للعميل وتأكيد الكود بنجاح');
    perform public.notify_staff(p_order_id, 'order_delivered',
      'تم تسليم الأوردر ' || v_order.order_number || ' للعميل', null, auth.uid());
  else
    update public.orders
      set failed_code_attempts = failed_code_attempts + 1,
          delivery_code_last_attempt_at = now()
      where id = p_order_id;
    perform public.log_order_event(p_order_id, 'delivery_code_mismatch', 'with_driver', 'with_driver', 'محاولة تسليم بكود غير صحيح');
  end if;

  return v_ok;
end;
$$;

create or replace function public.driver_log_refusal(p_order_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  if length(trim(coalesce(p_reason, ''))) = 0 then
    raise exception 'يجب كتابة سبب رفض الاستلام';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.assigned_driver_id <> auth.uid() then raise exception 'غير مصرح' using errcode = '42501'; end if;
  if v_order.status <> 'with_driver' then raise exception 'الأوردر ليس بحالة تسمح بتسجيل رفض الاستلام'; end if;

  update public.orders
    set status = 'refused', refused_at = now(), refusal_reason = trim(p_reason)
    where id = p_order_id;

  perform public.log_order_event(p_order_id, 'refused', 'with_driver', 'refused', p_reason);
  perform public.notify_staff(p_order_id, 'order_refused', 'رفض استلام أوردر ' || v_order.order_number, p_reason, auth.uid());
end;
$$;

create or replace function public.factory_confirm_receipt(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  if public.current_user_role() not in ('factory', 'owner', 'moderator') then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status <> 'collected' then raise exception 'الأوردر ليس بحالة تسمح بتأكيد الاستلام في المصنع'; end if;

  update public.orders set status = 'at_factory', factory_received_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'factory_confirmed_receipt', 'collected', 'at_factory', 'المصنع أكد استلام الأوردر');
  perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'factory_received',
    'تم استلام الأوردر ' || v_order.order_number || ' في المصنع', null);
  perform public.notify_staff(p_order_id, 'factory_received',
    'المصنع أكد استلام الأوردر ' || v_order.order_number, null, auth.uid());
end;
$$;

create or replace function public.factory_mark_ready(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  if public.current_user_role() not in ('factory', 'owner', 'moderator') then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status <> 'at_factory' then raise exception 'الأوردر ليس داخل المصنع حاليًا'; end if;

  update public.orders set status = 'ready', factory_ready_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'factory_marked_ready', 'at_factory', 'ready', 'المصنع أنهى العمل والأوردر جاهز للتسليم');
  perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'ready_for_pickup',
    'أوردر ' || v_order.order_number || ' جاهز للتسليم', 'يمكنك استلامه من المصنع الآن');
  perform public.notify_staff(p_order_id, 'ready_for_pickup',
    'الأوردر ' || v_order.order_number || ' جاهز للتسليم من المصنع', null, auth.uid());
end;
$$;

create or replace function public.owner_cancel_order(p_order_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status in ('delivered', 'cancelled') then
    raise exception 'لا يمكن إلغاء أوردر تم تسليمه أو ملغى بالفعل';
  end if;

  update public.orders set status = 'cancelled', cancelled_at = now(), cancel_reason = p_reason where id = p_order_id;
  perform public.log_order_event(p_order_id, 'cancelled', v_order.status, 'cancelled', p_reason);
  perform public.notify_staff(p_order_id, 'order_cancelled', 'تم إلغاء الأوردر ' || v_order.order_number, p_reason, auth.uid());
end;
$$;

create or replace function public.approve_distribution(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  if not public.is_owner() then
    raise exception 'اعتماد التوزيع من صلاحية Owner فقط' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then
    raise exception 'الأوردر غير موجود';
  end if;
  if v_order.status <> 'new' then
    raise exception 'الأوردر ليس في حالة تسمح باعتماد التوزيع';
  end if;
  if v_order.assigned_driver_id is null then
    raise exception 'لا يوجد مندوب محدد لهذا الأوردر';
  end if;

  update public.orders
    set status = 'assigned',
        distribution_approved_at = now(),
        distribution_approved_by = auth.uid()
    where id = p_order_id;

  perform public.log_order_event(p_order_id, 'distribution_approved', 'new', 'assigned', 'تم اعتماد التوزيع وإرسال الأوردر للمندوب');
  perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'order_assigned',
    'أوردر جديد تم إسناده إليك ' || v_order.order_number,
    'العميل: ' || v_order.customer_name);
  perform public.notify_staff(p_order_id, 'distribution_approved',
    'تم اعتماد توزيع الأوردر ' || v_order.order_number, null, auth.uid());
end;
$$;

create or replace function public.reassign_order_driver(p_order_id uuid, p_new_driver_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_new_driver public.profiles;
  v_old_driver_name text;
  v_new_status public.order_status;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status in ('delivered', 'cancelled', 'refused') then
    raise exception 'لا يمكن تغيير المندوب لأوردر منتهٍ';
  end if;

  select * into v_new_driver from public.profiles where id = p_new_driver_id;
  if v_new_driver is null or v_new_driver.role <> 'driver' or not v_new_driver.is_active then
    raise exception 'المندوب المحدد غير صالح';
  end if;
  if v_order.assigned_driver_id = p_new_driver_id then
    raise exception 'هذا المندوب مسؤول عن الأوردر بالفعل';
  end if;

  if v_order.assigned_driver_id is not null then
    select full_name into v_old_driver_name from public.profiles where id = v_order.assigned_driver_id;
  end if;

  v_new_status := case when v_order.status = 'new' then 'assigned' else v_order.status end;

  update public.orders
    set assigned_driver_id = p_new_driver_id,
        distribution_approved_at = coalesce(distribution_approved_at, now()),
        distribution_approved_by = coalesce(distribution_approved_by, auth.uid()),
        status = v_new_status
    where id = p_order_id;

  perform public.log_order_event(p_order_id, 'driver_reassigned', v_order.status, v_new_status,
    case when v_old_driver_name is not null
      then 'تم تغيير المندوب من ' || v_old_driver_name || ' إلى ' || v_new_driver.full_name
      else 'تم تعيين مندوب: ' || v_new_driver.full_name
    end);

  if v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'reassigned_away',
      'تم نقل الأوردر ' || v_order.order_number || ' إلى مندوب آخر', null);
  end if;

  perform public.notify_user(p_new_driver_id, p_order_id, 'order_assigned',
    'تم إسناد أوردر إليك ' || v_order.order_number, 'العميل: ' || v_order.customer_name);
  perform public.notify_staff(p_order_id, 'driver_reassigned',
    'تم تغيير مندوب الأوردر ' || v_order.order_number, null, auth.uid());
end;
$$;

create or replace function public.reassign_order_factory(p_order_id uuid, p_new_factory_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_new_factory public.profiles;
  v_old_factory_name text;
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status in ('delivered', 'cancelled', 'refused') then
    raise exception 'لا يمكن تغيير المصنع لأوردر منتهٍ';
  end if;

  select * into v_new_factory from public.profiles where id = p_new_factory_id;
  if v_new_factory is null or v_new_factory.role <> 'factory' or not v_new_factory.is_active then
    raise exception 'المصنع المحدد غير صالح';
  end if;
  if v_order.assigned_factory_id = p_new_factory_id then
    raise exception 'هذا المصنع مخصص للأوردر بالفعل';
  end if;

  if v_order.assigned_factory_id is not null then
    select full_name into v_old_factory_name from public.profiles where id = v_order.assigned_factory_id;
  end if;

  update public.orders set assigned_factory_id = p_new_factory_id where id = p_order_id;

  perform public.log_order_event(p_order_id, 'factory_reassigned', v_order.status, v_order.status,
    case when v_old_factory_name is not null
      then 'تم تغيير المصنع من ' || v_old_factory_name || ' إلى ' || v_new_factory.full_name
      else 'تم تحديد المصنع: ' || v_new_factory.full_name
    end);

  if v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'factory_reassigned',
      'تم تغيير المصنع الخاص بالأوردر ' || v_order.order_number,
      'المصنع الجديد: ' || v_new_factory.full_name);
  end if;

  if v_order.status in ('collected', 'at_factory', 'ready') then
    perform public.notify_user(p_new_factory_id, p_order_id, 'order_assigned',
      'تم تخصيص أوردر لمصنعكم ' || v_order.order_number, null);
  end if;

  perform public.notify_staff(p_order_id, 'factory_reassigned',
    'تم تغيير مصنع الأوردر ' || v_order.order_number, null, auth.uid());
end;
$$;


-- ========== db/migrations/0020_google_maps_links.sql ==================

alter table public.orders add column if not exists customer_maps_url text;

comment on column public.orders.customer_maps_url is
  'Optional Google Maps link pasted by staff at order creation (a Maps "share" link, e.g. https://www.google.com/maps/place/...). Preferred over a free-text customer_address search by mapsUrlFor() whenever present. Null falls back to searching customer_address.';

alter table public.profiles add column if not exists maps_url text;

comment on column public.profiles.maps_url is
  'Only meaningful for role=factory — same idea as orders.customer_maps_url: an optional pasted Google Maps link, preferred over lat/lng/address by mapsUrlFor() whenever present. Read from signup metadata by handle_new_user(), editable later alongside address/lat/lng (see updateStaffLocationAction / FactoryLocationCell).';

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, phone, role, address, lat, lng, maps_url)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.email, 'مستخدم جديد'),
    new.raw_user_meta_data ->> 'phone',
    coalesce((new.raw_user_meta_data ->> 'role')::user_role, 'driver'),
    new.raw_user_meta_data ->> 'address',
    nullif(new.raw_user_meta_data ->> 'lat', '')::double precision,
    nullif(new.raw_user_meta_data ->> 'lng', '')::double precision,
    new.raw_user_meta_data ->> 'maps_url'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop function if exists public.create_order_internal(text, text, text, uuid, integer, text, text, text, text, order_source, uuid, uuid, uuid);
drop function if exists public.public_create_order(text, text, text, uuid, integer, text, text, text, text, uuid);
drop function if exists public.moderator_create_order(text, text, text, uuid, integer, text, text, text, text, uuid, uuid);

create or replace function public.create_order_internal(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text,
  p_color text,
  p_work_required text,
  p_customer_notes text,
  p_source order_source,
  p_created_by uuid,
  p_factory_id uuid default null,
  p_driver_id uuid default null,
  p_customer_maps_url text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := public.generate_delivery_code();
  v_order public.orders;
  v_result public.new_order_result;
  v_factory public.profiles;
  v_driver public.profiles;
  v_new_status public.order_status;
  v_maps_url text := nullif(trim(coalesce(p_customer_maps_url, '')), '');
begin
  if length(trim(p_customer_name)) = 0 then
    raise exception 'اسم العميل مطلوب' using errcode = '22023';
  end if;
  if length(trim(p_customer_phone)) < 8 then
    raise exception 'رقم هاتف العميل غير صالح' using errcode = '22023';
  end if;
  if p_pieces_count is null or p_pieces_count < 1 then
    raise exception 'عدد القطع يجب أن يكون 1 على الأقل' using errcode = '22023';
  end if;

  if p_factory_id is not null then
    select * into v_factory from public.profiles where id = p_factory_id;
    if v_factory is null or v_factory.role <> 'factory' or not v_factory.is_active then
      raise exception 'المصنع المحدد غير صالح' using errcode = '22023';
    end if;
  end if;

  if p_driver_id is not null then
    select * into v_driver from public.profiles where id = p_driver_id;
    if v_driver is null or v_driver.role <> 'driver' or not v_driver.is_active then
      raise exception 'المندوب المحدد غير صالح' using errcode = '22023';
    end if;
  end if;

  insert into public.orders (
    customer_name, customer_phone, customer_address, customer_maps_url, region_id,
    pieces_count, piece_details, color, work_required, customer_notes,
    source, created_by, delivery_code_hash, assigned_factory_id
  ) values (
    trim(p_customer_name), trim(p_customer_phone), trim(p_customer_address), v_maps_url, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    p_source, p_created_by, crypt(v_code, gen_salt('bf')), p_factory_id
  )
  returning * into v_order;

  insert into public.order_delivery_codes (order_id, code) values (v_order.id, v_code);

  perform public.log_order_event(v_order.id, 'created', null, 'new',
    'تم إنشاء الأوردر عبر ' || case when p_source = 'website' then 'الموقع' else 'Messenger' end);

  if p_driver_id is not null then
    v_new_status := case when v_order.status = 'new' then 'assigned' else v_order.status end;

    update public.orders
      set assigned_driver_id = p_driver_id,
          distribution_approved_at = now(),
          distribution_approved_by = p_created_by,
          status = v_new_status
      where id = v_order.id;

    v_order.status := v_new_status;

    perform public.log_order_event(v_order.id, 'driver_reassigned', 'new', v_new_status,
      'تم تعيين مندوب عند إنشاء الأوردر: ' || v_driver.full_name);

    perform public.notify_user(p_driver_id, v_order.id, 'order_assigned',
      'تم إسناد أوردر إليك ' || v_order.order_number, 'العميل: ' || v_order.customer_name);
  end if;

  perform public.notify_role('owner', v_order.id, 'new_order', 'أوردر جديد ' || v_order.order_number,
    'تم استلام أوردر جديد من ' || v_order.customer_name);

  v_result.order_id := v_order.id;
  v_result.order_number := v_order.order_number;
  v_result.delivery_code := v_code;
  return v_result;
end;
$$;

revoke all on function public.create_order_internal from public, anon, authenticated;

create or replace function public.public_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null,
  p_factory_id uuid default null,
  p_customer_maps_url text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'website', null, p_factory_id, null, p_customer_maps_url
  );
end;
$$;

revoke all on function public.public_create_order from public;
grant execute on function public.public_create_order to anon, authenticated;

create or replace function public.moderator_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null,
  p_factory_id uuid default null,
  p_driver_id uuid default null,
  p_customer_maps_url text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح لك بإنشاء أوردر' using errcode = '42501';
  end if;

  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'messenger', auth.uid(), p_factory_id, p_driver_id, p_customer_maps_url
  );
end;
$$;

revoke all on function public.moderator_create_order from public;
grant execute on function public.moderator_create_order to authenticated;


-- ========== db/migrations/0021_editable_order_details.sql =============

create or replace function public.update_order_details(
  p_order_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_customer_maps_url text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text,
  p_color text,
  p_work_required text,
  p_customer_notes text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_new_maps_url text := nullif(trim(coalesce(p_customer_maps_url, '')), '');
  v_changes text := '';
begin
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح لك بتعديل بيانات الأوردر' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then
    raise exception 'الأوردر غير موجود';
  end if;

  if length(trim(coalesce(p_customer_name, ''))) = 0 then
    raise exception 'اسم العميل مطلوب' using errcode = '22023';
  end if;
  if length(trim(coalesce(p_customer_phone, ''))) < 8 then
    raise exception 'رقم هاتف العميل غير صالح' using errcode = '22023';
  end if;
  if length(trim(coalesce(p_customer_address, ''))) < 5 then
    raise exception 'العنوان قصير جدًا' using errcode = '22023';
  end if;
  if p_pieces_count is null or p_pieces_count < 1 then
    raise exception 'عدد القطع يجب أن يكون 1 على الأقل' using errcode = '22023';
  end if;

  if trim(v_order.customer_name) is distinct from trim(p_customer_name) then
    v_changes := v_changes || 'الاسم، ';
  end if;
  if trim(v_order.customer_phone) is distinct from trim(p_customer_phone) then
    v_changes := v_changes || 'الهاتف، ';
  end if;
  if trim(v_order.customer_address) is distinct from trim(p_customer_address) then
    v_changes := v_changes || 'العنوان، ';
  end if;
  if coalesce(v_order.customer_maps_url, '') is distinct from coalesce(v_new_maps_url, '') then
    v_changes := v_changes || 'رابط الخريطة، ';
  end if;
  if v_order.region_id is distinct from p_region_id then
    v_changes := v_changes || 'المنطقة، ';
  end if;
  if v_order.pieces_count is distinct from p_pieces_count then
    v_changes := v_changes || 'عدد القطع، ';
  end if;
  if coalesce(v_order.piece_details, '') is distinct from coalesce(p_piece_details, '') then
    v_changes := v_changes || 'تفاصيل القطع، ';
  end if;
  if coalesce(v_order.color, '') is distinct from coalesce(p_color, '') then
    v_changes := v_changes || 'اللون، ';
  end if;
  if coalesce(v_order.work_required, '') is distinct from coalesce(p_work_required, '') then
    v_changes := v_changes || 'المطلوب عمله، ';
  end if;
  if coalesce(v_order.customer_notes, '') is distinct from coalesce(p_customer_notes, '') then
    v_changes := v_changes || 'الملاحظات، ';
  end if;

  update public.orders set
    customer_name = trim(p_customer_name),
    customer_phone = trim(p_customer_phone),
    customer_address = trim(p_customer_address),
    customer_maps_url = v_new_maps_url,
    region_id = p_region_id,
    pieces_count = p_pieces_count,
    piece_details = p_piece_details,
    color = p_color,
    work_required = p_work_required,
    customer_notes = p_customer_notes
  where id = p_order_id;

  if v_changes <> '' then
    perform public.log_order_event(p_order_id, 'details_edited', v_order.status, v_order.status,
      'تم تعديل: ' || left(v_changes, length(v_changes) - 2));
  end if;
end;
$$;

revoke all on function public.update_order_details from public, anon, authenticated;
grant execute on function public.update_order_details to authenticated;
