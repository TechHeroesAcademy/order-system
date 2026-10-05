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
