-- 0025_region_free_text_matching.sql
--
-- Reported as: "the منطقة should be different from the city and it should
-- be used for matching with the orders in the same منطقة and match 100%
-- and should written by keybord not list and mandatory."
--
-- Until now, المنطقة was picked from a fixed dropdown of regions an Owner
-- had to pre-create from Team management first — in practice that list
-- tended to fill up with broad, city-level entries, which is exactly what
-- was reported as "the منطقة should be different from the city": too
-- coarse to be useful for fair, same-area driver matching. This migration
-- doesn't add a separate "city" concept — it makes المنطقة itself granular
-- and frictionless to add, by switching the *input* from "pick off a list"
-- to "type it": both the order's own region and a driver's covered-areas
-- field now take free-typed text. To keep matching genuinely 100% exact
-- (a typo silently breaking a driver's auto-assignment would be worse than
-- the dropdown it replaces), a typed name is resolved through
-- find_or_create_region() below, which normalizes (trim + collapse
-- whitespace) and reuses the existing public.regions row for that exact
-- name if one exists, or creates it on the spot if not. Matching itself is
-- still the same exact region_id equality pick_fair_driver_for_region()
-- (0024) already used — only how a name becomes that id has changed, so
-- "match 100%" is actually easier to guarantee now, not looser: two people
-- who type the same area name (after normalizing) always resolve to the
-- same canonical region row.
--
-- region_id itself is deliberately left nullable at the column level (no
-- database-level NOT NULL added here) — this migration has no way to
-- backfill whatever null region_id rows may already exist on the live
-- database from here. "Mandatory" is instead enforced at the two layers
-- that actually gate new writes: the order form's Zod schema client-side,
-- and find_or_create_region() itself raising if the typed name is empty —
-- every one of the SQL entry points below (public_create_order,
-- moderator_create_order, update_order_details) now runs through it.

-- ========== find_or_create_region: the shared name -> id resolver ==========

create or replace function public.find_or_create_region(p_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_id uuid;
begin
  if length(v_name) < 2 then
    raise exception 'اكتب اسم المنطقة' using errcode = '22023';
  end if;
  if length(v_name) > 100 then
    raise exception 'اسم المنطقة طويل جدًا' using errcode = '22023';
  end if;

  -- regions.name already has a UNIQUE constraint (0003) — this upsert is
  -- the atomic, race-safe "find it, or create it" this feature needs: two
  -- staff typing the same new area name at the same moment both resolve to
  -- the one row that wins, never two near-duplicate regions.
  insert into public.regions (name) values (v_name)
  on conflict (name) do update set name = excluded.name
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.find_or_create_region from public;
grant execute on function public.find_or_create_region to authenticated;

-- ========== driver coverage areas: typed, same resolver, one atomic replace ==========

create or replace function public.set_driver_regions_by_name(p_driver_id uuid, p_region_names text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
  v_id uuid;
  v_ids uuid[] := '{}';
begin
  -- Editing a driver's covered areas was deliberately left Owner+Moderator
  -- (not narrowed to Owner-only like assignment/new-account-creation in
  -- 0024) — same authorization this replaces (setDriverRegionsAction).
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  if not exists (select 1 from public.profiles where id = p_driver_id and role = 'driver') then
    raise exception 'هذا الحساب ليس مندوبًا';
  end if;

  foreach v_name in array coalesce(p_region_names, '{}'::text[])
  loop
    if length(trim(coalesce(v_name, ''))) > 0 then
      v_id := public.find_or_create_region(v_name);
      if not (v_id = any(v_ids)) then
        v_ids := array_append(v_ids, v_id);
      end if;
    end if;
  end loop;

  delete from public.driver_regions where driver_id = p_driver_id;

  if array_length(v_ids, 1) > 0 then
    insert into public.driver_regions (driver_id, region_id)
    select p_driver_id, x from unnest(v_ids) as x;
  end if;
end;
$$;

revoke all on function public.set_driver_regions_by_name from public;
grant execute on function public.set_driver_regions_by_name to authenticated;

-- ========== order creation / edit: p_region_id uuid -> p_region_name text ==========

drop function if exists public.create_order_internal(
  text, text, text, uuid, integer, text, text, text, text, order_source, uuid, uuid, uuid, text
);

create or replace function public.create_order_internal(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_name text,
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
  v_pickup_code text := public.generate_delivery_code();
  v_region_id uuid;
  v_order public.orders;
  v_result public.new_order_result;
  v_factory public.profiles;
  v_driver public.profiles;
  v_new_status public.order_status;
  v_maps_url text := nullif(trim(coalesce(p_customer_maps_url, '')), '');
  v_auto_driver_id uuid;
  v_auto_driver_name text;
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

  -- Mandatory + resolved to a canonical region row here — after the basic
  -- field checks above, so an invalid name never gets created as a
  -- side effect of a request that was going to fail anyway.
  v_region_id := public.find_or_create_region(p_region_name);

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
    source, created_by, delivery_code_hash, pickup_code_hash, assigned_factory_id
  ) values (
    trim(p_customer_name), trim(p_customer_phone), trim(p_customer_address), v_maps_url, v_region_id,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    p_source, p_created_by, crypt(v_code, gen_salt('bf')), crypt(v_pickup_code, gen_salt('bf')), p_factory_id
  )
  returning * into v_order;

  insert into public.order_delivery_codes (order_id, code) values (v_order.id, v_code);
  insert into public.order_pickup_codes (order_id, code) values (v_order.id, v_pickup_code);

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
  else
    -- Same fair, region-based suggestion as 0024 — only the input changed,
    -- not the matching itself: v_region_id is the same canonical id
    -- pick_fair_driver_for_region() always matched on before this.
    v_auto_driver_id := public.pick_fair_driver_for_region(v_region_id);
    if v_auto_driver_id is not null then
      update public.orders
        set assigned_driver_id = v_auto_driver_id,
            suggested_driver_id = v_auto_driver_id
        where id = v_order.id;

      select full_name into v_auto_driver_name from public.profiles where id = v_auto_driver_id;
      perform public.log_order_event(v_order.id, 'distribution_set', 'new', 'new',
        'تم اقتراح مندوب تلقائيًا حسب المنطقة: ' || v_auto_driver_name || ' (بانتظار اعتماد المدير)');
    end if;
  end if;

  perform public.notify_role('owner', v_order.id, 'new_order', 'أوردر جديد ' || v_order.order_number,
    'تم استلام أوردر جديد من ' || v_order.customer_name);

  v_result.order_id := v_order.id;
  v_result.order_number := v_order.order_number;
  v_result.delivery_code := v_code;
  v_result.pickup_code := v_pickup_code;
  return v_result;
end;
$$;

revoke all on function public.create_order_internal from public, anon, authenticated;

drop function if exists public.public_create_order(
  text, text, text, uuid, integer, text, text, text, text, uuid, text
);

create or replace function public.public_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_name text,
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
    p_customer_name, p_customer_phone, p_customer_address, p_region_name,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'website', null, p_factory_id, null, p_customer_maps_url
  );
end;
$$;

revoke all on function public.public_create_order from public;
grant execute on function public.public_create_order to anon, authenticated;

drop function if exists public.moderator_create_order(
  text, text, text, uuid, integer, text, text, text, text, uuid, uuid, text
);

create or replace function public.moderator_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_name text,
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

  if not public.is_owner() and (p_driver_id is not null or p_factory_id is not null) then
    raise exception 'تحديد المندوب أو المصنع من صلاحية المدير فقط' using errcode = '42501';
  end if;

  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_name,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'messenger', auth.uid(), p_factory_id, p_driver_id, p_customer_maps_url
  );
end;
$$;

revoke all on function public.moderator_create_order from public;
grant execute on function public.moderator_create_order to authenticated;

drop function if exists public.update_order_details(
  uuid, text, text, text, text, uuid, integer, text, text, text, text
);

create or replace function public.update_order_details(
  p_order_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_customer_maps_url text,
  p_region_name text,
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
  v_region_id uuid;
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

  v_region_id := public.find_or_create_region(p_region_name);

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
  if v_order.region_id is distinct from v_region_id then
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
    region_id = v_region_id,
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
