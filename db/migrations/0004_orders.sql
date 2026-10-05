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
