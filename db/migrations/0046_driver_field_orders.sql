create or replace function public.driver_create_field_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_name text,
  p_pieces_count integer,
  p_factory_id uuid,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null,
  p_customer_maps_url text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
declare
  v_driver uuid := auth.uid();
  v_role public.user_role;
  v_active boolean;
  v_result public.new_order_result;
begin
  select role, is_active into v_role, v_active
    from public.profiles where id = v_driver;

  if v_role is null or not v_active then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if v_role <> 'driver' then
    raise exception 'هذه الطريقة لإنشاء الأوردر مخصصة للمندوبين' using errcode = '42501';
  end if;
  if p_factory_id is null then
    raise exception 'اختر المصنع' using errcode = '22023';
  end if;

  v_result := public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_name,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'driver_field'::order_source, v_driver, p_factory_id, v_driver, p_customer_maps_url
  );

  update public.orders
     set status = 'assigned',
         distribution_approved_at = now(),
         distribution_approved_by = v_driver
   where id = v_result.order_id;

  perform public.log_order_event(
    v_result.order_id, 'field_order_created', 'new', 'assigned',
    'أوردر ميداني أنشأه المندوب وتم إسناده له مباشرة بدون اعتماد'
  );

  perform public.notify_staff(
    v_result.order_id, 'field_order_created',
    'أوردر ميداني جديد من المندوب',
    'أنشأه ' || coalesce((select full_name from public.profiles where id = v_driver), 'مندوب')
      || ' وتم إسناده له مباشرة'
  );

  return v_result;
end;
$$;

revoke all on function public.driver_create_field_order(text, text, text, text, integer, uuid, text, text, text, text, text) from public;
grant execute on function public.driver_create_field_order(text, text, text, text, integer, uuid, text, text, text, text, text) to authenticated;

create or replace function public.orders_by_source_report(p_month date default current_date)
returns table (source text, order_count bigint, delivered_count bigint, total_pieces bigint)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_end date := (date_trunc('month', p_month) + interval '1 month')::date;
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    select o.source::text,
           count(*),
           count(*) filter (where o.status = 'delivered'),
           coalesce(sum(o.pieces_count), 0)
      from public.orders o
     where o.created_at >= v_start and o.created_at < v_end
     group by o.source
     order by count(*) desc;
end;
$$;

create or replace function public.orders_by_creator_report(p_month date default current_date)
returns table (
  creator_name text,
  creator_role text,
  order_count bigint,
  delivered_count bigint,
  field_order_count bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_end date := (date_trunc('month', p_month) + interval '1 month')::date;
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    select coalesce(o.created_by_name, 'غير معروف'),
           coalesce(o.created_by_role::text, '—'),
           count(*),
           count(*) filter (where o.status = 'delivered'),
           count(*) filter (where o.source = 'driver_field')
      from public.orders o
     where o.created_at >= v_start and o.created_at < v_end
     group by o.created_by_name, o.created_by_role
     order by count(*) desc;
end;
$$;

revoke all on function public.orders_by_source_report(date) from public;
revoke all on function public.orders_by_creator_report(date) from public;
grant execute on function public.orders_by_source_report(date) to authenticated;
grant execute on function public.orders_by_creator_report(date) to authenticated;

create or replace function public.order_source_label(p_source public.order_source)
returns text
language sql
immutable
as $$
  select case p_source
    when 'website' then 'الموقع'
    when 'messenger' then 'Messenger'
    when 'driver_field' then 'المندوب في الشارع'
    else p_source::text
  end;
$$;

do $$
declare v_src text;
begin
  select prosrc into v_src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'create_order_internal';

  if v_src is null then
    raise exception 'create_order_internal not found — apply the earlier migrations first';
  end if;

  if position('case when p_source = ''website'' then ''الموقع'' else ''Messenger'' end' in v_src) = 0 then
    raise notice 'creation-note line not found; it may already be patched — leaving create_order_internal untouched';
    return;
  end if;

  v_src := replace(
    v_src,
    'case when p_source = ''website'' then ''الموقع'' else ''Messenger'' end',
    'public.order_source_label(p_source)'
  );

  execute format(
    'create or replace function public.create_order_internal('
    || 'p_customer_name text, p_customer_phone text, p_customer_address text, '
    || 'p_region_name text, p_pieces_count integer, p_piece_details text, '
    || 'p_color text, p_work_required text, p_customer_notes text, '
    || 'p_source order_source, p_created_by uuid, p_factory_id uuid default null, '
    || 'p_driver_id uuid default null, p_customer_maps_url text default null) '
    || 'returns public.new_order_result language plpgsql security definer '
    || 'set search_path = public, extensions as %L', v_src);
end$$;

revoke all on function public.order_source_label(public.order_source) from public;
grant execute on function public.order_source_label(public.order_source) to authenticated;
