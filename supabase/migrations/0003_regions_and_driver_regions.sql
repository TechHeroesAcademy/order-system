-- 0003_regions_and_driver_regions.sql

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

-- Which regions each driver covers (used by the auto-distribution suggestion).
create table if not exists public.driver_regions (
  driver_id uuid not null references public.profiles (id) on delete cascade,
  region_id uuid not null references public.regions (id) on delete cascade,
  primary key (driver_id, region_id)
);

create index if not exists driver_regions_region_idx on public.driver_regions (region_id);
