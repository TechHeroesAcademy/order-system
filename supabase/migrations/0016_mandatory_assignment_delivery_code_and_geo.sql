-- 0016_mandatory_assignment_delivery_code_and_geo.sql
--
--   1) "driver and factory mandatory when a Moderator creates the order
--      (not Owner)" — the app layer (createModeratorOrderAction) is what
--      enforces "mandatory for Moderator, optional for Owner" (a role-based
--      UI rule doesn't belong in a shared DB function), but there was no
--      way to assign a driver AT creation time at all — driver assignment
--      only ever happened afterward, through the separate suggest/approve
--      distribution flow or the direct "change driver" control. This adds
--      an optional p_driver_id to create_order_internal/moderator_create_order,
--      mirroring exactly what reassign_order_driver's direct-assignment path
--      already does (assign + pre-approve + notify) so a driver picked at
--      creation is immediately visible to that driver, same as any other
--      direct assignment.
--
--   2) "the delivery code should appear anytime, not only the first time" —
--      by original design the plaintext code is never stored, only a bcrypt
--      hash (delivery_code_hash), specifically so nobody with read access to
--      the app or database could look it up and fake a delivery confirmation
--      — the code's entire value as proof-of-delivery is that only the
--      customer's paper receipt has it. Storing it in plaintext on `orders`
--      itself would leak it through every `select("*")` in the app,
--      including the driver's own order page — which would defeat the
--      point (a driver could "confirm delivery" without the customer ever
--      reading them the code). Instead: the plaintext lives in a new table
--      with RLS enabled and zero policies (default-deny for every direct
--      client request), reachable only through a SECURITY DEFINER RPC that
--      checks is_owner_or_moderator() itself — so Owner/Moderator can look
--      it up whenever they need to (e.g. to remind a customer who lost
--      their receipt), and a driver or factory account still can never see
--      it, same as before.
--
--   3) "factory maps link with lat/lon, Leaflet" — profiles.address (0015)
--      was free text only, good enough for a Google Maps *search* link but
--      not precise, and not something a map component can plot a pin from.
--      Adds nullable lat/lng columns (only meaningful for role='factory',
--      same as address) so the frontend can show an exact-location Maps
--      link and a real Leaflet map/pin instead of a text search.

-- ---------- 1) driver assignment at order creation ----------

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

  -- Same shortcut reassign_order_driver's direct-assignment path takes: a
  -- driver picked right at creation is assigned AND pre-approved in one
  -- step, so the order is immediately visible to them (see 0014) instead of
  -- waiting on a separate suggest/approve pass.
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

-- public_create_order's signature/body is untouched — it already defaults
-- p_factory_id and now simply also defaults the new p_driver_id (via
-- create_order_internal's own default) to null; anonymous website orders
-- were retired to a redirect-to-login anyway (see src/app/order/new), so
-- there's no path that would ever want to pass one.

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

-- ---------- 2) delivery code, viewable on demand (Owner/Moderator only) ----------

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

  -- null for any order created before this migration shipped — it was
  -- never captured in plaintext for those, only hashed (see 0004/0007).
  select code into v_code from public.order_delivery_codes where order_id = p_order_id;
  return v_code;
end;
$$;

revoke all on function public.get_order_delivery_code from public;
grant execute on function public.get_order_delivery_code to authenticated;

-- ---------- 3) factory geo-coordinates ----------

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
