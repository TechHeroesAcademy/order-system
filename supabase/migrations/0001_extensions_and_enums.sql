-- 0001_extensions_and_enums.sql
-- Extensions and shared enum types for the order management system.

create extension if not exists pgcrypto;
create extension if not exists "uuid-ossp";
create extension if not exists pg_trgm;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'user_role') then
    create type user_role as enum ('owner', 'moderator', 'driver', 'factory');
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'order_status') then
    create type order_status as enum (
      'new',           -- created, not yet assigned/approved
      'assigned',       -- distribution approved by Owner, driver notified
      'collected',      -- driver collected the order from the customer
      'at_factory',     -- factory confirmed receipt from driver
      'ready',          -- factory finished and marked ready for pickup
      'with_driver',    -- same driver picked the order back up from the factory
      'delivered',      -- delivered to customer, delivery code validated, closed
      'refused',        -- customer refused to receive the order
      'cancelled'       -- cancelled by Owner/Moderator before completion
    );
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'order_source') then
    create type order_source as enum ('website', 'messenger');
  end if;
end $$;
