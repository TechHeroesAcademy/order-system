set search_path = public, extensions;


drop policy if exists orders_select_factory on public.orders;
create policy orders_select_factory on public.orders
  for select using (
    public.current_user_role() = 'factory'
    and (
      assigned_factory_id = auth.uid()
      or (assigned_factory_id is null and status in ('collected', 'at_factory', 'ready'))
    )
  );

drop policy if exists order_history_select_factory on public.order_history;
create policy order_history_select_factory on public.order_history
  for select using (
    public.current_user_role() = 'factory'
    and exists (
      select 1 from public.orders o
      where o.id = order_history.order_id
        and (
          o.assigned_factory_id = auth.uid()
          or (o.assigned_factory_id is null and o.status in ('collected', 'at_factory', 'ready'))
        )
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
  o.driver_pickup_at,
  o.delivered_at,
  o.created_at
from public.orders o
left join public.profiles p on p.id = o.assigned_driver_id
left join public.profiles f on f.id = o.assigned_factory_id
where
  public.current_user_role() in ('owner', 'moderator')
  or (
    public.current_user_role() = 'factory'
    and (
      o.assigned_factory_id = auth.uid()
      or (o.assigned_factory_id is null and o.status in ('collected', 'at_factory', 'ready'))
    )
  );

grant select on public.factory_orders_view to authenticated;


drop policy if exists orders_select_factory on public.orders;
create policy orders_select_factory on public.orders
  for select using (
    public.current_user_role() = 'factory'
    and (
      (assigned_factory_id = auth.uid() and status not in ('new', 'assigned'))
      or (assigned_factory_id is null and status in ('collected', 'at_factory', 'ready'))
    )
  );

drop policy if exists order_history_select_factory on public.order_history;
create policy order_history_select_factory on public.order_history
  for select using (
    public.current_user_role() = 'factory'
    and exists (
      select 1 from public.orders o
      where o.id = order_history.order_id
        and (
          (o.assigned_factory_id = auth.uid() and o.status not in ('new', 'assigned'))
          or (o.assigned_factory_id is null and o.status in ('collected', 'at_factory', 'ready'))
        )
    )
  );

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
  o.assigned_factory_id,
  f.full_name as assigned_factory_name,
  f.address as assigned_factory_address,
  o.collected_at,
  o.handed_to_factory_at,
  o.factory_received_at,
  o.factory_ready_at,
  o.driver_pickup_at,
  o.delivered_at,
  o.created_at
from public.orders o
left join public.profiles p on p.id = o.assigned_driver_id
left join public.profiles f on f.id = o.assigned_factory_id
where
  public.current_user_role() in ('owner', 'moderator')
  or (
    public.current_user_role() = 'factory'
    and (
      (o.assigned_factory_id = auth.uid() and o.status not in ('new', 'assigned'))
      or (o.assigned_factory_id is null and o.status in ('collected', 'at_factory', 'ready'))
    )
  );

grant select on public.factory_orders_view to authenticated;


alter table public.orders add column if not exists pickup_code_hash text;
alter table public.orders add column if not exists failed_pickup_code_attempts integer not null default 0;
alter table public.orders add column if not exists pickup_code_last_attempt_at timestamptz;

comment on column public.orders.pickup_code_hash is
  'bcrypt hash of the code the driver must get from the customer to confirm pickup (driver_mark_collected) — same protection model as delivery_code_hash, just at the other end of the trip. Null for orders created before this migration; driver_mark_collected treats a null hash as "no code was ever issued" and skips the check rather than rejecting the driver forever.';

create table if not exists public.order_pickup_codes (
  order_id uuid primary key references public.orders (id) on delete cascade,
  code text not null,
  created_at timestamptz not null default now()
);

comment on table public.order_pickup_codes is
  'Plaintext pickup codes, mirroring order_delivery_codes (0016) exactly: RLS enabled with zero policies (every direct client request denied by default), reachable only through get_order_pickup_code() below.';

alter table public.order_pickup_codes enable row level security;
revoke all on public.order_pickup_codes from public, anon, authenticated;

create or replace function public.get_order_pickup_code(p_order_id uuid)
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

  select code into v_code from public.order_pickup_codes where order_id = p_order_id;
  return v_code;
end;
$$;

revoke all on function public.get_order_pickup_code from public;
grant execute on function public.get_order_pickup_code to authenticated;

do $$
begin
  if not exists (
    select 1
    from pg_attribute a
    join pg_type t on t.typrelid = a.attrelid
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public'
      and t.typname = 'new_order_result'
      and a.attname = 'pickup_code'
      and not a.attisdropped
  ) then
    alter type public.new_order_result add attribute pickup_code text;
  end if;
end$$;

drop function if exists public.driver_mark_collected(uuid);

create or replace function public.driver_mark_collected(p_order_id uuid, p_code text)
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
  if v_order.status <> 'assigned' then raise exception 'الأوردر ليس بحالة تسمح بتسجيل الاستلام من العميل'; end if;

  if v_order.pickup_code_hash is null then
    v_ok := true;
  else
    v_ok := (crypt(coalesce(p_code, ''), v_order.pickup_code_hash) = v_order.pickup_code_hash);
  end if;

  if v_ok then
    update public.orders set status = 'collected', collected_at = now() where id = p_order_id;
    perform public.log_order_event(p_order_id, 'collected_from_customer', 'assigned', 'collected', 'تم استلام الأوردر من العميل');
    perform public.notify_staff(p_order_id, 'order_collected',
      'تم استلام الأوردر ' || v_order.order_number || ' من العميل', null, auth.uid());
  else
    update public.orders
      set failed_pickup_code_attempts = failed_pickup_code_attempts + 1,
          pickup_code_last_attempt_at = now()
      where id = p_order_id;
    perform public.log_order_event(p_order_id, 'pickup_code_mismatch', 'assigned', 'assigned', 'محاولة استلام من العميل بكود غير صحيح');
  end if;

  return v_ok;
end;
$$;

revoke all on function public.driver_mark_collected(uuid, text) from public;
grant execute on function public.driver_mark_collected(uuid, text) to authenticated;

create or replace function public.set_order_distribution(p_order_id uuid, p_driver_id uuid, p_is_suggestion boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status order_status;
begin
  if not public.is_owner() then
    raise exception 'تحديد المندوب من صلاحية المدير فقط' using errcode = '42501';
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
  if not public.is_owner() then
    raise exception 'تحديد المندوب من صلاحية المدير فقط' using errcode = '42501';
  end if;

  select status into v_status from public.orders where id = p_order_id for update;
  if v_status <> 'new' then
    raise exception 'لا يمكن إلغاء توزيع أوردر تم اعتماده بالفعل';
  end if;

  update public.orders set assigned_driver_id = null where id = p_order_id;
  perform public.log_order_event(p_order_id, 'distribution_cleared', v_status, v_status, 'تم إلغاء التوزيع المقترح');
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
  if not public.is_owner() then
    raise exception 'تغيير المندوب من صلاحية المدير فقط' using errcode = '42501';
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
  if not public.is_owner() then
    raise exception 'تغيير المصنع من صلاحية المدير فقط' using errcode = '42501';
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

create or replace function public.pick_fair_driver_for_region(p_region_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select p.id
  from public.profiles p
  where p.role = 'driver'
    and p.is_active
    and p_region_id is not null
    and exists (
      select 1 from public.driver_regions dr
      where dr.driver_id = p.id and dr.region_id = p_region_id
    )
  order by (
    select count(*) from public.orders o
    where o.assigned_driver_id = p.id
      and o.status not in ('delivered', 'cancelled', 'refused')
  ) asc, p.full_name asc
  limit 1;
$$;

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
  v_pickup_code text := public.generate_delivery_code();
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
    trim(p_customer_name), trim(p_customer_phone), trim(p_customer_address), v_maps_url, p_region_id,
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
    v_auto_driver_id := public.pick_fair_driver_for_region(p_region_id);
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

  if not public.is_owner() and (p_driver_id is not null or p_factory_id is not null) then
    raise exception 'تحديد المندوب أو المصنع من صلاحية المدير فقط' using errcode = '42501';
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

  insert into public.regions (name) values (v_name)
  on conflict (name) do update set name = excluded.name
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.find_or_create_region from public;
grant execute on function public.find_or_create_region to authenticated;

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


create table if not exists public.pickup_points (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text,
  lat double precision,
  lng double precision,
  maps_url text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.pickup_points is
  'Drop-off locations for collected cooking utensils, region-scoped like driver coverage areas (see pickup_point_regions). The pickup-point-to-factory leg itself is not tracked here — see the migration header comment.';

drop trigger if exists set_pickup_points_updated_at on public.pickup_points;
create trigger set_pickup_points_updated_at
  before update on public.pickup_points
  for each row execute function public.set_updated_at();

create table if not exists public.pickup_point_regions (
  pickup_point_id uuid not null references public.pickup_points(id) on delete cascade,
  region_id uuid not null references public.regions(id) on delete cascade,
  primary key (pickup_point_id, region_id)
);

comment on table public.pickup_point_regions is
  'Which منطقة name(s) each pickup point covers — same shape as driver_regions.';

alter table public.pickup_points enable row level security;
alter table public.pickup_point_regions enable row level security;

drop policy if exists pickup_points_select_staff on public.pickup_points;
create policy pickup_points_select_staff on public.pickup_points
  for select using (auth.role() = 'authenticated');

drop policy if exists pickup_point_regions_select_staff on public.pickup_point_regions;
create policy pickup_point_regions_select_staff on public.pickup_point_regions
  for select using (auth.role() = 'authenticated');

grant select on public.pickup_points to authenticated;
grant select on public.pickup_point_regions to authenticated;

create or replace function public.create_pickup_point(
  p_name text,
  p_address text,
  p_maps_url text,
  p_region_names text[]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_name text;
  v_region_id uuid;
begin
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'اسم نقطة التجميع مطلوب' using errcode = '22023';
  end if;

  insert into public.pickup_points (name, address, maps_url)
  values (
    trim(p_name),
    nullif(trim(coalesce(p_address, '')), ''),
    nullif(trim(coalesce(p_maps_url, '')), '')
  )
  returning id into v_id;

  foreach v_name in array coalesce(p_region_names, '{}'::text[])
  loop
    if length(trim(coalesce(v_name, ''))) > 0 then
      v_region_id := public.find_or_create_region(v_name);
      insert into public.pickup_point_regions (pickup_point_id, region_id)
        values (v_id, v_region_id)
        on conflict do nothing;
    end if;
  end loop;

  return v_id;
end;
$$;
revoke all on function public.create_pickup_point(text, text, text, text[]) from public;
grant execute on function public.create_pickup_point(text, text, text, text[]) to authenticated;

create or replace function public.update_pickup_point(
  p_id uuid,
  p_name text,
  p_address text,
  p_maps_url text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'اسم نقطة التجميع مطلوب' using errcode = '22023';
  end if;

  update public.pickup_points
    set name = trim(p_name),
        address = nullif(trim(coalesce(p_address, '')), ''),
        maps_url = nullif(trim(coalesce(p_maps_url, '')), '')
    where id = p_id;

  if not found then
    raise exception 'نقطة التجميع غير موجودة';
  end if;
end;
$$;
revoke all on function public.update_pickup_point(uuid, text, text, text) from public;
grant execute on function public.update_pickup_point(uuid, text, text, text) to authenticated;

create or replace function public.set_pickup_point_active(p_id uuid, p_is_active boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  update public.pickup_points set is_active = p_is_active where id = p_id;
  if not found then
    raise exception 'نقطة التجميع غير موجودة';
  end if;
end;
$$;
revoke all on function public.set_pickup_point_active(uuid, boolean) from public;
grant execute on function public.set_pickup_point_active(uuid, boolean) to authenticated;

create or replace function public.set_pickup_point_regions(p_pickup_point_id uuid, p_region_names text[])
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
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if not exists (select 1 from public.pickup_points where id = p_pickup_point_id) then
    raise exception 'نقطة التجميع غير موجودة';
  end if;

  foreach v_name in array coalesce(p_region_names, '{}'::text[]) loop
    if length(trim(coalesce(v_name, ''))) > 0 then
      v_id := public.find_or_create_region(v_name);
      if not (v_id = any(v_ids)) then
        v_ids := array_append(v_ids, v_id);
      end if;
    end if;
  end loop;

  delete from public.pickup_point_regions where pickup_point_id = p_pickup_point_id;
  if array_length(v_ids, 1) > 0 then
    insert into public.pickup_point_regions (pickup_point_id, region_id)
      select p_pickup_point_id, x from unnest(v_ids) as x;
  end if;
end;
$$;
revoke all on function public.set_pickup_point_regions(uuid, text[]) from public;
grant execute on function public.set_pickup_point_regions(uuid, text[]) to authenticated;


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

  if p_driver_id is not null then
    raise exception 'يتم تعيين المندوب تلقائيًا عند إنشاء الأوردر، لا يمكن اختياره يدويًا' using errcode = '42501';
  end if;

  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_name,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'messenger', auth.uid(), p_factory_id, null, p_customer_maps_url
  );
end;
$$;

revoke all on function public.moderator_create_order(text, text, text, text, integer, text, text, text, text, uuid, uuid, text) from public;
grant execute on function public.moderator_create_order(text, text, text, text, integer, text, text, text, text, uuid, uuid, text) to authenticated;


drop function if exists public.set_pickup_point_regions(uuid, text[]);
drop function if exists public.set_pickup_point_active(uuid, boolean);
drop function if exists public.update_pickup_point(uuid, text, text, text);
drop function if exists public.create_pickup_point(text, text, text, text[]);

drop table if exists public.pickup_point_regions cascade;
drop table if exists public.pickup_points cascade;


alter table public.order_messages add column if not exists driver_id uuid references public.profiles(id);

update public.order_messages om
  set driver_id = o.assigned_driver_id
  from public.orders o
  where om.order_id = o.id
    and om.channel = 'driver'
    and om.driver_id is distinct from o.assigned_driver_id;

create index if not exists order_messages_driver_stint_idx on public.order_messages (order_id, driver_id) where channel = 'driver';

drop policy if exists order_messages_select on public.order_messages;
drop function if exists public.can_read_order_channel(uuid, text, uuid);

create or replace function public.can_read_order_channel(
  p_order_id uuid,
  p_channel text,
  p_user_id uuid,
  p_message_driver_id uuid default null
)
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
        (p_channel = 'driver' and o.assigned_driver_id = p_user_id and p_message_driver_id = p_user_id)
        or (p_channel = 'factory' and o.assigned_factory_id = p_user_id)
      )
  );
$$;

revoke all on function public.can_read_order_channel(uuid, text, uuid, uuid) from public;
grant execute on function public.can_read_order_channel(uuid, text, uuid, uuid) to authenticated;

create policy order_messages_select on public.order_messages
  for select using (
    public.is_owner_or_moderator()
    or public.can_read_order_channel(order_messages.order_id, order_messages.channel, auth.uid(), order_messages.driver_id)
  );

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

  insert into public.order_messages (order_id, channel, sender_id, sender_role, body, driver_id)
  values (
    p_order_id, v_channel, auth.uid(), v_role, v_body,
    case when v_channel = 'driver' then v_order.assigned_driver_id else null end
  )
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

revoke all on function public.send_order_message(uuid, text, text) from public;
grant execute on function public.send_order_message(uuid, text, text) to authenticated;


create or replace function public.owner_cancel_order(p_order_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  if not public.is_owner() then
    raise exception 'إلغاء الأوردر من صلاحية المدير فقط' using errcode = '42501';
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

revoke all on function public.owner_cancel_order(uuid, text) from public;
grant execute on function public.owner_cancel_order(uuid, text) to authenticated;


create or replace function public.set_order_number()
returns trigger
language plpgsql
as $$
begin
  if new.order_number is null or new.order_number = '' then
    new.order_number := 'ORD-' || lpad(nextval('public.order_number_seq')::text, 5, '0');
  end if;
  return new;
end;
$$;


alter table public.orders add column if not exists assigned_driver_name text;
alter table public.orders add column if not exists assigned_factory_name text;

update public.orders o
set assigned_driver_name = p.full_name
from public.profiles p
where o.assigned_driver_id = p.id and o.assigned_driver_name is null;

update public.orders o
set assigned_factory_name = p.full_name
from public.profiles p
where o.assigned_factory_id = p.id and o.assigned_factory_name is null;

create or replace function public.stamp_order_assignee_names()
returns trigger
language plpgsql
as $$
begin
  if new.assigned_driver_id is not null
     and (tg_op = 'INSERT' or new.assigned_driver_id is distinct from old.assigned_driver_id) then
    select full_name into new.assigned_driver_name from public.profiles where id = new.assigned_driver_id;
  end if;

  if new.assigned_factory_id is not null
     and (tg_op = 'INSERT' or new.assigned_factory_id is distinct from old.assigned_factory_id) then
    select full_name into new.assigned_factory_name from public.profiles where id = new.assigned_factory_id;
  end if;

  return new;
end;
$$;

drop trigger if exists stamp_order_assignee_names on public.orders;
create trigger stamp_order_assignee_names
  before insert or update on public.orders
  for each row execute function public.stamp_order_assignee_names();

alter table public.orders drop constraint orders_assigned_driver_id_fkey;
alter table public.orders add constraint orders_assigned_driver_id_fkey
  foreign key (assigned_driver_id) references public.profiles (id) on delete set null;

alter table public.orders drop constraint orders_suggested_driver_id_fkey;
alter table public.orders add constraint orders_suggested_driver_id_fkey
  foreign key (suggested_driver_id) references public.profiles (id) on delete set null;

alter table public.orders drop constraint orders_distribution_approved_by_fkey;
alter table public.orders add constraint orders_distribution_approved_by_fkey
  foreign key (distribution_approved_by) references public.profiles (id) on delete set null;

alter table public.orders drop constraint orders_created_by_fkey;
alter table public.orders add constraint orders_created_by_fkey
  foreign key (created_by) references public.profiles (id) on delete set null;

alter table public.orders drop constraint orders_assigned_factory_id_fkey;
alter table public.orders add constraint orders_assigned_factory_id_fkey
  foreign key (assigned_factory_id) references public.profiles (id) on delete set null;

alter table public.order_history drop constraint order_history_actor_id_fkey;
alter table public.order_history add constraint order_history_actor_id_fkey
  foreign key (actor_id) references public.profiles (id) on delete set null;

alter table public.order_messages alter column sender_id drop not null;
alter table public.order_messages drop constraint order_messages_sender_id_fkey;
alter table public.order_messages add constraint order_messages_sender_id_fkey
  foreign key (sender_id) references public.profiles (id) on delete set null;

alter table public.order_messages drop constraint order_messages_driver_id_fkey;
alter table public.order_messages add constraint order_messages_driver_id_fkey
  foreign key (driver_id) references public.profiles (id) on delete set null;

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
  o.assigned_driver_name,
  o.assigned_factory_id,
  o.assigned_factory_name,
  f.address as assigned_factory_address,
  o.collected_at,
  o.handed_to_factory_at,
  o.factory_received_at,
  o.factory_ready_at,
  o.driver_pickup_at,
  o.delivered_at,
  o.created_at
from public.orders o
left join public.profiles f on f.id = o.assigned_factory_id
where
  public.current_user_role() in ('owner', 'moderator')
  or (
    public.current_user_role() = 'factory'
    and (
      (o.assigned_factory_id = auth.uid() and o.status not in ('new', 'assigned'))
      or (o.assigned_factory_id is null and o.status in ('collected', 'at_factory', 'ready'))
    )
  );

grant select on public.factory_orders_view to authenticated;


create table if not exists public.factories (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text,
  address text,
  lat double precision,
  lng double precision,
  maps_url text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.factories is
  'Workshops an order is routed to. Replaces the old profiles.role=''factory'' '
  'accounts — a factory is a place, not a user, and has no login.';

drop trigger if exists set_factories_updated_at on public.factories;
create trigger set_factories_updated_at
  before update on public.factories
  for each row execute function public.set_updated_at();

insert into public.factories (id, name, phone, address, lat, lng, maps_url, is_active, created_at)
select p.id, p.full_name, p.phone, p.address, p.lat, p.lng, p.maps_url, p.is_active, p.created_at
from public.profiles p
where p.role = 'factory'
   or p.id in (select o.assigned_factory_id from public.orders o where o.assigned_factory_id is not null)
on conflict (id) do nothing;

do $$
declare
  v_orphans integer;
begin
  select count(*) into v_orphans
  from public.orders o
  where o.assigned_factory_id is not null
    and not exists (select 1 from public.factories f where f.id = o.assigned_factory_id);

  if v_orphans > 0 then
    raise exception
      'ABORT: % order(s) point at a factory id with no matching factories row. '
      'Nothing has been changed. Investigate before re-running.', v_orphans;
  end if;
end$$;

alter table public.orders drop constraint if exists orders_assigned_factory_id_fkey;
alter table public.orders add constraint orders_assigned_factory_id_fkey
  foreign key (assigned_factory_id) references public.factories (id) on delete restrict;

alter table public.factories enable row level security;

drop policy if exists factories_select on public.factories;
create policy factories_select on public.factories
  for select to authenticated using (true);

grant select on public.factories to authenticated;

create or replace function public.stamp_order_assignee_names()
returns trigger
language plpgsql
as $$
begin
  if new.assigned_driver_id is not null
     and (tg_op = 'INSERT' or new.assigned_driver_id is distinct from old.assigned_driver_id) then
    select full_name into new.assigned_driver_name from public.profiles where id = new.assigned_driver_id;
  end if;

  if new.assigned_factory_id is not null
     and (tg_op = 'INSERT' or new.assigned_factory_id is distinct from old.assigned_factory_id) then
    select coalesce(f.name, new.assigned_factory_name) into new.assigned_factory_name
    from public.factories f where f.id = new.assigned_factory_id;
  end if;

  return new;
end;
$$;

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
  v_factory public.factories;
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

  v_region_id := public.find_or_create_region(p_region_name);

  if p_factory_id is not null then
    select * into v_factory from public.factories where id = p_factory_id;
    if v_factory is null or not v_factory.is_active then
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

create or replace function public.reassign_order_factory(p_order_id uuid, p_new_factory_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_new_factory public.factories;
  v_old_factory_name text;
begin
  if not public.is_owner() then
    raise exception 'تغيير المصنع من صلاحية المدير فقط' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status in ('delivered', 'cancelled', 'refused') then
    raise exception 'لا يمكن تغيير المصنع لأوردر منتهٍ';
  end if;

  select * into v_new_factory from public.factories where id = p_new_factory_id;
  if v_new_factory is null or not v_new_factory.is_active then
    raise exception 'المصنع المحدد غير صالح';
  end if;
  if v_order.assigned_factory_id = p_new_factory_id then
    raise exception 'هذا المصنع مخصص للأوردر بالفعل';
  end if;

  if v_order.assigned_factory_id is not null then
    select name into v_old_factory_name from public.factories where id = v_order.assigned_factory_id;
  end if;

  update public.orders set assigned_factory_id = p_new_factory_id where id = p_order_id;

  perform public.log_order_event(p_order_id, 'factory_reassigned', v_order.status, v_order.status,
    case when v_old_factory_name is not null
      then 'تم تغيير المصنع من ' || v_old_factory_name || ' إلى ' || v_new_factory.name
      else 'تم تحديد المصنع: ' || v_new_factory.name
    end);

  if v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'factory_reassigned',
      'تم تغيير المصنع الخاص بالأوردر ' || v_order.order_number,
      'المصنع الجديد: ' || v_new_factory.name);
  end if;

  perform public.notify_staff(p_order_id, 'factory_reassigned',
    'تم تغيير مصنع الأوردر ' || v_order.order_number, null, auth.uid());
end;
$$;

create or replace function public.create_factory(
  p_name text,
  p_phone text default null,
  p_address text default null,
  p_lat double precision default null,
  p_lng double precision default null,
  p_maps_url text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not public.is_owner() then
    raise exception 'إضافة مصنع من صلاحية المدير فقط' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_name, ''))) < 2 then
    raise exception 'اسم المصنع مطلوب' using errcode = '22023';
  end if;

  insert into public.factories (name, phone, address, lat, lng, maps_url)
  values (trim(p_name), nullif(trim(coalesce(p_phone, '')), ''), p_address, p_lat, p_lng, p_maps_url)
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.update_factory(
  p_factory_id uuid,
  p_name text,
  p_phone text default null,
  p_address text default null,
  p_lat double precision default null,
  p_lng double precision default null,
  p_maps_url text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_name, ''))) < 2 then
    raise exception 'اسم المصنع مطلوب' using errcode = '22023';
  end if;
  if not exists (select 1 from public.factories where id = p_factory_id) then
    raise exception 'المصنع غير موجود';
  end if;

  update public.factories
     set name = trim(p_name),
         phone = nullif(trim(coalesce(p_phone, '')), ''),
         address = p_address,
         lat = p_lat,
         lng = p_lng,
         maps_url = p_maps_url
   where id = p_factory_id;
end;
$$;

create or replace function public.set_factory_active(p_factory_id uuid, p_is_active boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  update public.factories set is_active = p_is_active where id = p_factory_id;
  if not found then
    raise exception 'المصنع غير موجود';
  end if;
end;
$$;

create or replace function public.delete_factory(p_factory_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner() then
    raise exception 'حذف مصنع من صلاحية المدير فقط' using errcode = '42501';
  end if;

  delete from public.factories where id = p_factory_id;
  if not found then
    raise exception 'المصنع غير موجود';
  end if;
exception
  when foreign_key_violation then
    raise exception 'لا يمكن حذف مصنع مرتبط بأوردرات. استخدم "تعطيل" بدلًا من الحذف.'
      using errcode = '23503';
end;
$$;

revoke all on function public.create_factory(text, text, text, double precision, double precision, text) from public, anon;
revoke all on function public.update_factory(uuid, text, text, text, double precision, double precision, text) from public, anon;
revoke all on function public.set_factory_active(uuid, boolean) from public, anon;
revoke all on function public.delete_factory(uuid) from public, anon;

grant execute on function public.create_factory(text, text, text, double precision, double precision, text) to authenticated;
grant execute on function public.update_factory(uuid, text, text, text, double precision, double precision, text) to authenticated;
grant execute on function public.set_factory_active(uuid, boolean) to authenticated;
grant execute on function public.delete_factory(uuid) to authenticated;


create or replace function public.factory_confirm_receipt(p_order_id uuid)
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

  if not (
    coalesce(public.is_owner_or_moderator(), false)
    or (public.current_user_role() = 'driver' and v_order.assigned_driver_id = auth.uid())
    or public.current_user_role() = 'factory'
  ) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  if v_order.status <> 'collected' then raise exception 'الأوردر ليس بحالة تسمح بتأكيد الاستلام في المصنع'; end if;

  update public.orders
     set status = 'at_factory',
         factory_received_at = now(),
         handed_to_factory_at = coalesce(handed_to_factory_at, now())
   where id = p_order_id;

  perform public.log_order_event(p_order_id, 'factory_confirmed_receipt', 'collected', 'at_factory',
    'تم تسليم الأوردر للمصنع');

  if v_order.assigned_driver_id is not null and v_order.assigned_driver_id is distinct from auth.uid() then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'factory_received',
      'تم استلام الأوردر ' || v_order.order_number || ' في المصنع', null);
  end if;

  perform public.notify_staff(p_order_id, 'factory_received',
    'تم تسليم الأوردر ' || v_order.order_number || ' للمصنع', null, auth.uid());
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
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;

  if not (
    coalesce(public.is_owner_or_moderator(), false)
    or (public.current_user_role() = 'driver' and v_order.assigned_driver_id = auth.uid())
    or public.current_user_role() = 'factory'
  ) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  if v_order.status <> 'at_factory' then raise exception 'الأوردر ليس داخل المصنع حاليًا'; end if;

  update public.orders set status = 'ready', factory_ready_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'factory_marked_ready', 'at_factory', 'ready',
    'المصنع أنهى العمل والأوردر جاهز للاستلام');

  if v_order.assigned_driver_id is not null and v_order.assigned_driver_id is distinct from auth.uid() then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'ready_for_pickup',
      'أوردر ' || v_order.order_number || ' جاهز للتسليم', 'يمكنك استلامه من المصنع الآن');
  end if;

  perform public.notify_staff(p_order_id, 'ready_for_pickup',
    'الأوردر ' || v_order.order_number || ' جاهز للاستلام من المصنع', null, auth.uid());
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
end;
$$;

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
  if v_channel <> 'driver' then
    raise exception 'قناة الدردشة الوحيدة المتاحة هي دردشة المندوب' using errcode = '22023';
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
    public.is_owner()
    or (v_role = 'driver' and v_order.assigned_driver_id = auth.uid())
  ) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  insert into public.order_messages (order_id, channel, sender_id, sender_role, body, driver_id)
  values (p_order_id, v_channel, auth.uid(), v_role, v_body, v_order.assigned_driver_id)
  returning * into v_row;

  if v_role = 'driver' then
    perform public.notify_role('owner', p_order_id, 'chat_message',
      'رسالة جديدة من المندوب على الأوردر ' || v_order.order_number, v_body);
  elsif v_order.assigned_driver_id is not null then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'chat_message',
      'رسالة جديدة على الأوردر ' || v_order.order_number, v_body);
  end if;

  return v_row;
end;
$$;

drop policy if exists order_messages_select on public.order_messages;
create policy order_messages_select on public.order_messages
  for select using (
    public.is_owner()
    or public.can_read_order_channel(order_messages.order_id, order_messages.channel, auth.uid(), order_messages.driver_id)
  );


create or replace function public.approve_distribution_one(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
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

create or replace function public.approve_distribution(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner() then
    raise exception 'اعتماد التوزيع من صلاحية المدير فقط' using errcode = '42501';
  end if;
  perform public.approve_distribution_one(p_order_id);
end;
$$;

create or replace function public.approve_distribution_bulk(p_order_ids uuid[])
returns table (order_id uuid, order_number text, succeeded boolean, error text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not public.is_owner() then
    raise exception 'اعتماد التوزيع من صلاحية المدير فقط' using errcode = '42501';
  end if;
  if coalesce(array_length(p_order_ids, 1), 0) = 0 then
    return;
  end if;
  if array_length(p_order_ids, 1) > 200 then
    raise exception 'لا يمكن اعتماد أكثر من 200 أوردر في المرة الواحدة' using errcode = '22023';
  end if;

  for v_id in select distinct u from unnest(p_order_ids) u order by 1 loop
    order_id := v_id;
    select o.order_number into order_number from public.orders o where o.id = v_id;

    begin
      perform public.approve_distribution_one(v_id);
      succeeded := true;
      error := null;
    exception when others then
      succeeded := false;
      error := sqlerrm;
    end;

    return next;
  end loop;
end;
$$;

create or replace function public.set_order_distribution_one(
  p_order_id uuid,
  p_driver_id uuid,
  p_is_suggestion boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status order_status;
begin
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

create or replace function public.set_order_distribution(p_order_id uuid, p_driver_id uuid, p_is_suggestion boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner() then
    raise exception 'تحديد المندوب من صلاحية المدير فقط' using errcode = '42501';
  end if;
  perform public.set_order_distribution_one(p_order_id, p_driver_id, p_is_suggestion);
end;
$$;

create or replace function public.set_order_distribution_bulk(p_order_ids uuid[], p_driver_id uuid)
returns table (order_id uuid, order_number text, succeeded boolean, error text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_driver public.profiles;
begin
  if not public.is_owner() then
    raise exception 'تحديد المندوب من صلاحية المدير فقط' using errcode = '42501';
  end if;
  if coalesce(array_length(p_order_ids, 1), 0) = 0 then
    return;
  end if;
  if array_length(p_order_ids, 1) > 200 then
    raise exception 'لا يمكن تعديل أكثر من 200 أوردر في المرة الواحدة' using errcode = '22023';
  end if;

  select * into v_driver from public.profiles where id = p_driver_id;
  if v_driver is null or v_driver.role <> 'driver' or not v_driver.is_active then
    raise exception 'المندوب المحدد غير صالح' using errcode = '22023';
  end if;

  for v_id in select distinct u from unnest(p_order_ids) u order by 1 loop
    order_id := v_id;
    select o.order_number into order_number from public.orders o where o.id = v_id;

    begin
      perform public.set_order_distribution_one(v_id, p_driver_id, false);
      succeeded := true;
      error := null;
    exception when others then
      succeeded := false;
      error := sqlerrm;
    end;

    return next;
  end loop;
end;
$$;

revoke all on function public.approve_distribution_one(uuid) from public, anon, authenticated;
revoke all on function public.set_order_distribution_one(uuid, uuid, boolean) from public, anon, authenticated;

revoke all on function public.approve_distribution_bulk(uuid[]) from public, anon;
revoke all on function public.set_order_distribution_bulk(uuid[], uuid) from public, anon;
grant execute on function public.approve_distribution_bulk(uuid[]) to authenticated;
grant execute on function public.set_order_distribution_bulk(uuid[], uuid) to authenticated;

alter table public.orders add column if not exists needs_allocation_at timestamptz;
alter table public.orders add column if not exists needs_allocation_reason text;

create index if not exists orders_needs_allocation_idx
  on public.orders (needs_allocation_at) where needs_allocation_at is not null;

comment on column public.orders.needs_allocation_at is
  'Set when an order was left without a driver by something other than normal '
  'backlog (today: the assigned driver being removed with no one covering the '
  'area). Cleared automatically by stamp_order_assignee_names the moment a '
  'driver is assigned or the order reaches a terminal status.';

create or replace function public.stamp_order_assignee_names()
returns trigger
language plpgsql
as $$
begin
  if new.assigned_driver_id is not null
     and (tg_op = 'INSERT' or new.assigned_driver_id is distinct from old.assigned_driver_id) then
    select full_name into new.assigned_driver_name from public.profiles where id = new.assigned_driver_id;
  end if;

  if new.assigned_factory_id is not null
     and (tg_op = 'INSERT' or new.assigned_factory_id is distinct from old.assigned_factory_id) then
    select coalesce(f.name, new.assigned_factory_name) into new.assigned_factory_name
    from public.factories f where f.id = new.assigned_factory_id;
  end if;

  if new.assigned_driver_id is not null and (tg_op = 'INSERT' or old.assigned_driver_id is null) then
    new.needs_allocation_at := null;
    new.needs_allocation_reason := null;
  end if;

  if new.status in ('delivered', 'cancelled', 'refused') then
    new.needs_allocation_at := null;
    new.needs_allocation_reason := null;
  end if;

  return new;
end;
$$;


create or replace function public.pick_fair_driver_for_region_excluding(
  p_region_id uuid,
  p_exclude_driver_id uuid
)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select p.id
  from public.profiles p
  where p.role = 'driver'
    and p.is_active
    and p_region_id is not null
    and (p_exclude_driver_id is null or p.id <> p_exclude_driver_id)
    and exists (
      select 1 from public.driver_regions dr
      where dr.driver_id = p.id and dr.region_id = p_region_id
    )
  order by (
    select count(*) from public.orders o
    where o.assigned_driver_id = p.id
      and o.status not in ('delivered', 'cancelled', 'refused')
  ) asc, p.full_name asc
  limit 1;
$$;

create or replace function public.reassign_orders_from_driver(p_driver_id uuid)
returns table (
  order_id uuid,
  order_number text,
  order_status public.order_status,
  new_driver_id uuid,
  new_driver_name text,
  outcome text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_driver public.profiles;
  v_fallback_regions uuid[];
  v_order record;
  v_successor uuid;
  v_region uuid;
  v_unallocated_ids uuid[] := array[]::uuid[];
  v_unallocated_numbers text[] := array[]::text[];
  v_idx integer;
begin
  if not public.is_owner() then
    raise exception 'حذف المندوب من صلاحية المدير فقط' using errcode = '42501';
  end if;

  select * into v_driver from public.profiles where id = p_driver_id;
  if v_driver is null then raise exception 'المندوب غير موجود'; end if;
  if v_driver.role <> 'driver' then raise exception 'هذا الحساب ليس مندوبًا'; end if;

  v_fallback_regions := array(
    select dr.region_id from public.driver_regions dr where dr.driver_id = p_driver_id
  );

  for v_order in
    select o.id, o.order_number, o.status, o.region_id
    from public.orders o
    where o.assigned_driver_id = p_driver_id
      and o.status not in ('delivered', 'cancelled', 'refused')
    order by o.id
    for update
  loop
    v_successor := public.pick_fair_driver_for_region_excluding(v_order.region_id, p_driver_id);

    if v_successor is null then
      foreach v_region in array coalesce(v_fallback_regions, array[]::uuid[]) loop
        v_successor := public.pick_fair_driver_for_region_excluding(v_region, p_driver_id);
        exit when v_successor is not null;
      end loop;
    end if;

    order_id := v_order.id;
    order_number := v_order.order_number;
    order_status := v_order.status;

    if v_successor is null then
      update public.orders
         set assigned_driver_id = null,
             needs_allocation_at = now(),
             needs_allocation_reason = 'تم حذف المندوب ولا يوجد مندوب بديل يغطي المنطقة'
       where id = v_order.id;

      perform public.log_order_event(v_order.id, 'driver_unassigned', v_order.status, v_order.status,
        'تم حذف المندوب ولا يوجد بديل يغطي المنطقة — الأوردر بحاجة لتعيين مندوب');

      v_unallocated_ids := v_unallocated_ids || v_order.id;
      v_unallocated_numbers := v_unallocated_numbers || v_order.order_number;
      new_driver_id := null;
      new_driver_name := null;
      outcome := 'unallocated';

    elsif v_order.status = 'new' then
      update public.orders
         set assigned_driver_id = v_successor,
             suggested_driver_id = v_successor
       where id = v_order.id;

      perform public.log_order_event(v_order.id, 'distribution_set', v_order.status, v_order.status,
        'تم اقتراح مندوب بديل بعد حذف المندوب السابق (بانتظار اعتماد المدير)');

      new_driver_id := v_successor;
      select full_name into new_driver_name from public.profiles where id = v_successor;
      outcome := 'resuggested';

    else
      update public.orders set assigned_driver_id = v_successor where id = v_order.id;

      select full_name into new_driver_name from public.profiles where id = v_successor;

      perform public.log_order_event(v_order.id, 'driver_reassigned', v_order.status, v_order.status,
        'تم نقل الأوردر إلى ' || coalesce(new_driver_name, 'مندوب آخر') || ' بعد حذف المندوب السابق');

      perform public.notify_user(v_successor, v_order.id, 'order_assigned',
        'تم نقل أوردر إليك ' || v_order.order_number,
        'بعد حذف المندوب السابق');

      new_driver_id := v_successor;
      outcome := 'reassigned';
    end if;

    return next;
  end loop;

  if array_length(v_unallocated_ids, 1) between 1 and 10 then
    for v_idx in 1 .. array_length(v_unallocated_ids, 1) loop
      perform public.notify_staff(v_unallocated_ids[v_idx], 'needs_allocation',
        'الأوردر ' || v_unallocated_numbers[v_idx] || ' يحتاج تعيين مندوب',
        'تم حذف المندوب ولا يوجد بديل يغطي المنطقة', auth.uid());
    end loop;
  elsif coalesce(array_length(v_unallocated_ids, 1), 0) > 10 then
    perform public.notify_staff(null, 'needs_allocation',
      array_length(v_unallocated_ids, 1) || ' أوردر بحاجة لتعيين مندوب',
      'تم حذف مندوب ولا يوجد بديل يغطي مناطقه', auth.uid());
  end if;
end;
$$;

revoke all on function public.pick_fair_driver_for_region_excluding(uuid, uuid) from public, anon;
revoke all on function public.reassign_orders_from_driver(uuid) from public, anon;
grant execute on function public.reassign_orders_from_driver(uuid) to authenticated;


create or replace function public.update_staff_profile(p_user_id uuid, p_full_name text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target public.profiles;
  v_name text := trim(coalesce(p_full_name, ''));
begin
  if not public.is_owner() then
    raise exception 'تعديل بيانات الموظفين من صلاحية المدير فقط' using errcode = '42501';
  end if;
  if length(v_name) < 2 then
    raise exception 'الاسم قصير جدًا' using errcode = '22023';
  end if;
  if length(v_name) > 120 then
    raise exception 'الاسم طويل جدًا' using errcode = '22023';
  end if;

  select * into v_target from public.profiles where id = p_user_id;
  if v_target is null then raise exception 'الحساب غير موجود'; end if;

  update public.profiles set full_name = v_name where id = p_user_id;

  update public.orders
     set assigned_driver_name = v_name
   where assigned_driver_id = p_user_id
     and assigned_driver_name is distinct from v_name;
end;
$$;

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
  if not public.is_owner() then
    raise exception 'تعديل مناطق المندوب من صلاحية المدير فقط' using errcode = '42501';
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

revoke all on function public.update_staff_profile(uuid, text) from public, anon;
grant execute on function public.update_staff_profile(uuid, text) to authenticated;


do $$
declare
  v_remaining integer;
begin
  select count(*) into v_remaining from public.profiles where role = 'factory';
  if v_remaining > 0 then
    raise exception
      'ABORT: % factory account(s) still exist. Delete them first '
      '(delete from public.profiles where role = ''factory'';) and make sure the '
      'app build without /factory is live. Nothing has been changed.', v_remaining;
  end if;
end$$;

drop view if exists public.factory_orders_view;

drop policy if exists orders_select_factory on public.orders;
drop policy if exists order_history_select_factory on public.order_history;

drop policy if exists profiles_select_factory_for_assigned_driver on public.profiles;

drop policy if exists profiles_update_moderator on public.profiles;
create policy profiles_update_moderator on public.profiles
  for update using (public.current_user_role() = 'moderator' and role = 'driver')
  with check (public.current_user_role() = 'moderator' and role = 'driver');

create or replace function public.factory_confirm_receipt(p_order_id uuid)
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

  if not (
    coalesce(public.is_owner_or_moderator(), false)
    or (public.current_user_role() = 'driver' and v_order.assigned_driver_id = auth.uid())
  ) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  if v_order.status <> 'collected' then raise exception 'الأوردر ليس بحالة تسمح بتأكيد الاستلام في المصنع'; end if;

  update public.orders
     set status = 'at_factory',
         factory_received_at = now(),
         handed_to_factory_at = coalesce(handed_to_factory_at, now())
   where id = p_order_id;

  perform public.log_order_event(p_order_id, 'factory_confirmed_receipt', 'collected', 'at_factory',
    'تم تسليم الأوردر للمصنع');

  if v_order.assigned_driver_id is not null and v_order.assigned_driver_id is distinct from auth.uid() then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'factory_received',
      'تم استلام الأوردر ' || v_order.order_number || ' في المصنع', null);
  end if;

  perform public.notify_staff(p_order_id, 'factory_received',
    'تم تسليم الأوردر ' || v_order.order_number || ' للمصنع', null, auth.uid());
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
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;

  if not (
    coalesce(public.is_owner_or_moderator(), false)
    or (public.current_user_role() = 'driver' and v_order.assigned_driver_id = auth.uid())
  ) then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;

  if v_order.status <> 'at_factory' then raise exception 'الأوردر ليس داخل المصنع حاليًا'; end if;

  update public.orders set status = 'ready', factory_ready_at = now() where id = p_order_id;
  perform public.log_order_event(p_order_id, 'factory_marked_ready', 'at_factory', 'ready',
    'المصنع أنهى العمل والأوردر جاهز للاستلام');

  if v_order.assigned_driver_id is not null and v_order.assigned_driver_id is distinct from auth.uid() then
    perform public.notify_user(v_order.assigned_driver_id, p_order_id, 'ready_for_pickup',
      'أوردر ' || v_order.order_number || ' جاهز للتسليم', 'يمكنك استلامه من المصنع الآن');
  end if;

  perform public.notify_staff(p_order_id, 'ready_for_pickup',
    'الأوردر ' || v_order.order_number || ' جاهز للاستلام من المصنع', null, auth.uid());
end;
$$;

create or replace function public.can_read_order_channel(
  p_order_id uuid,
  p_channel text,
  p_user_id uuid,
  p_message_driver_id uuid default null
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.orders o
    where o.id = p_order_id
      and p_channel = 'driver'
      and o.assigned_driver_id = p_user_id
      and p_message_driver_id = p_user_id
  );
$$;

alter table public.profiles drop constraint if exists profiles_role_not_factory;
alter table public.profiles add constraint profiles_role_not_factory check (role <> 'factory');

comment on type public.user_role is
  'factory is retained for historical rows only (order_history.actor_role, '
  'order_messages.sender_role) — factories became a table of their own in '
  'migration 0033 and no profile may use this value; see the '
  'profiles_role_not_factory constraint.';


create index if not exists orders_open_created_at_idx
  on public.orders (created_at)
  where status not in ('delivered', 'cancelled', 'refused');

create index if not exists orders_driver_created_at_idx
  on public.orders (assigned_driver_id, created_at desc);

create index if not exists orders_status_created_at_idx
  on public.orders (status, created_at desc);

drop index if exists public.orders_driver_idx;
drop index if exists public.orders_status_idx;

create or replace function public.monthly_report(p_month date default current_date)
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
  v_sla interval := (public.order_sla_hours() || ' hours')::interval;
begin
  if not public.is_owner_or_moderator() then raise exception 'غير مصرح' using errcode = '42501'; end if;

  return query
    with agg as (
      select
        count(*) filter (where o.created_at >= v_start) as cur_total,
        coalesce(sum(o.pieces_count) filter (where o.created_at >= v_start), 0) as cur_pieces,
        count(*) filter (where o.created_at >= v_start and o.status = 'delivered') as cur_delivered,
        count(*) filter (
          where o.created_at >= v_start and public.is_order_delayed(o.*)
        ) as cur_delayed,
        round(
          avg(extract(epoch from (o.delivered_at - o.created_at)) / 3600.0)
            filter (where o.created_at >= v_start and o.status = 'delivered'),
          1
        ) as cur_avg_hours,
        count(*) filter (
          where o.created_at >= v_start
            and o.status = 'delivered'
            and o.delivered_at <= o.created_at + v_sla
        ) as cur_on_time,
        count(*) filter (where o.created_at < v_start) as prev_total,
        count(*) filter (where o.created_at < v_start and o.status = 'delivered') as prev_delivered
      from public.orders o
      where o.created_at >= v_prev_start
        and o.created_at < v_end
    )
    select
      agg.cur_total,
      agg.cur_pieces,
      agg.cur_delivered,
      agg.cur_delayed,
      agg.cur_avg_hours,
      round(100.0 * agg.cur_on_time / nullif(agg.cur_delivered, 0), 1),
      agg.prev_total,
      agg.prev_delivered,
      case
        when agg.prev_total = 0 then null
        else round(100.0 * (agg.cur_total - agg.prev_total) / agg.prev_total, 1)
      end
    from agg;
end;
$$;

revoke all on function public.monthly_report(date) from public;
grant execute on function public.monthly_report(date) to authenticated;


create table if not exists public.manager_factories (
  manager_id uuid not null references public.profiles (id) on delete cascade,
  factory_id uuid not null references public.factories (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (manager_id, factory_id)
);

create index if not exists manager_factories_factory_idx
  on public.manager_factories (factory_id);

alter table public.manager_factories enable row level security;

drop policy if exists manager_factories_select on public.manager_factories;
create policy manager_factories_select on public.manager_factories
  for select to authenticated using (public.is_owner_or_moderator());

grant select on public.manager_factories to authenticated;

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  last_success_at timestamptz,
  failure_count integer not null default 0
);

create index if not exists push_subscriptions_user_idx
  on public.push_subscriptions (user_id);

alter table public.push_subscriptions enable row level security;

drop policy if exists push_subscriptions_select_own on public.push_subscriptions;
create policy push_subscriptions_select_own on public.push_subscriptions
  for select to authenticated using (user_id = auth.uid());

drop policy if exists push_subscriptions_delete_own on public.push_subscriptions;
create policy push_subscriptions_delete_own on public.push_subscriptions
  for delete to authenticated using (user_id = auth.uid());

grant select, delete on public.push_subscriptions to authenticated;

create or replace function public.save_push_subscription(
  p_endpoint text,
  p_p256dh text,
  p_auth text,
  p_user_agent text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  if coalesce(trim(p_endpoint), '') = ''
     or coalesce(trim(p_p256dh), '') = ''
     or coalesce(trim(p_auth), '') = '' then
    raise exception 'بيانات الاشتراك غير مكتملة' using errcode = '22023';
  end if;
  if length(p_endpoint) > 2000 or length(p_p256dh) > 500 or length(p_auth) > 500 then
    raise exception 'بيانات الاشتراك غير صالحة' using errcode = '22023';
  end if;

  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth, user_agent)
  values (v_uid, p_endpoint, p_p256dh, p_auth, left(p_user_agent, 400))
  on conflict (endpoint) do update
    set user_id = excluded.user_id,
        p256dh = excluded.p256dh,
        auth = excluded.auth,
        user_agent = excluded.user_agent,
        failure_count = 0;
end;
$$;

create or replace function public.delete_push_subscription(p_endpoint text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'غير مصرح' using errcode = '42501';
  end if;
  delete from public.push_subscriptions
   where endpoint = p_endpoint and user_id = v_uid;
end;
$$;

create or replace function public.set_manager_factories(
  p_manager_id uuid,
  p_factory_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target public.profiles;
  v_ids uuid[] := coalesce(p_factory_ids, '{}');
  v_unknown integer;
begin
  if not public.is_owner() then
    raise exception 'تعديل تغطية المديرين من صلاحية المدير فقط' using errcode = '42501';
  end if;

  select * into v_target from public.profiles where id = p_manager_id;
  if v_target is null then
    raise exception 'الحساب غير موجود';
  end if;
  if v_target.role not in ('owner', 'moderator') then
    raise exception 'التغطية بالمصانع للمديرين فقط';
  end if;

  select count(*) into v_unknown
    from unnest(v_ids) as t(fid)
   where not exists (select 1 from public.factories f where f.id = t.fid);
  if v_unknown > 0 then
    raise exception 'مصنع غير معروف ضمن المحدد';
  end if;

  delete from public.manager_factories
   where manager_id = p_manager_id
     and not (factory_id = any (v_ids));

  insert into public.manager_factories (manager_id, factory_id)
  select p_manager_id, t.fid from unnest(v_ids) as t(fid)
  on conflict do nothing;
end;
$$;

create or replace function public.increment_push_failures(p_ids uuid[])
returns void
language sql
security definer
set search_path = public
as $$
  update public.push_subscriptions
     set failure_count = failure_count + 1
   where id = any (coalesce(p_ids, '{}'));
$$;

revoke all on function public.increment_push_failures(uuid[]) from public;

revoke all on function public.save_push_subscription(text, text, text, text) from public;
revoke all on function public.delete_push_subscription(text) from public;
revoke all on function public.set_manager_factories(uuid, uuid[]) from public;

grant execute on function public.save_push_subscription(text, text, text, text) to authenticated;
grant execute on function public.delete_push_subscription(text) to authenticated;
grant execute on function public.set_manager_factories(uuid, uuid[]) to authenticated;


create or replace function public.should_push_notification(n public.notifications)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role public.user_role;
  v_factory uuid;
begin
  select role into v_role from public.profiles
   where id = n.user_id and is_active;
  if v_role is null then return false; end if;

  if n.type = 'order_assigned' then
    return true;
  end if;

  if n.type = 'chat_message' then
    if v_role = 'driver' then
      return true;
    end if;

    if v_role in ('owner', 'moderator') then
      if n.order_id is null then return false; end if;
      select assigned_factory_id into v_factory
        from public.orders where id = n.order_id;
      if v_factory is null then return false; end if;
      return exists (
        select 1 from public.manager_factories mf
         where mf.manager_id = n.user_id
           and mf.factory_id = v_factory
      );
    end if;

    return false;
  end if;

  return false;
end;
$$;

create or replace function public.dispatch_push_notification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text := nullif(current_setting('app.push_endpoint_url', true), '');
  v_secret text := nullif(current_setting('app.push_webhook_secret', true), '');
begin
  if v_url is null or v_secret is null then
    return null;
  end if;

  if not public.should_push_notification(new) then
    return null;
  end if;

  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('notification_id', new.id),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-Push-Secret', v_secret
    ),
    timeout_milliseconds := 5000
  );

  return null;
exception when others then
  raise warning 'push dispatch skipped for notification %: %', new.id, sqlerrm;
  return null;
end;
$$;

drop trigger if exists dispatch_push_on_notification on public.notifications;
create trigger dispatch_push_on_notification
  after insert on public.notifications
  for each row execute function public.dispatch_push_notification();

revoke all on function public.should_push_notification(public.notifications) from public;
revoke all on function public.dispatch_push_notification() from public;



create table if not exists public.app_settings (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);

alter table public.app_settings enable row level security;

revoke all on public.app_settings from anon, authenticated;

comment on table public.app_settings is
  'Server-side configuration read only by security-definer functions. Never exposed to the API: no grants to anon/authenticated. Holds the push endpoint URL and webhook secret — see 0041/0042.';

create or replace function public.dispatch_push_notification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_secret text;
begin
  select value into v_url from public.app_settings where key = 'push_endpoint_url';
  select value into v_secret from public.app_settings where key = 'push_webhook_secret';

  if coalesce(v_url, '') = '' or coalesce(v_secret, '') = '' then
    return null;
  end if;

  if not public.should_push_notification(new) then
    return null;
  end if;

  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('notification_id', new.id),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-Push-Secret', v_secret
    ),
    timeout_milliseconds := 5000
  );

  return null;
exception when others then
  raise warning 'push dispatch skipped for notification %: %', new.id, sqlerrm;
  return null;
end;
$$;

revoke all on function public.dispatch_push_notification() from public;



create or replace function public.moderator_notification_types()
returns text[]
language sql
immutable
as $$ select array['order_delivered']$$;

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
      and (role = 'owner' or p_type = any (public.moderator_notification_types()))
  loop
    perform public.notify_user(v_user.id, p_order_id, p_type, p_title, p_body);
  end loop;
end;
$$;

revoke all on function public.notify_staff(uuid, text, text, text, uuid) from public;
revoke all on function public.moderator_notification_types() from public;

delete from public.notifications n
 using public.profiles p
 where p.id = n.user_id
   and p.role = 'moderator'
   and not (n.type = any (public.moderator_notification_types()));


alter type public.order_source add value if not exists 'driver_field';

alter table public.orders add column if not exists created_by_name text;
alter table public.orders add column if not exists created_by_role public.user_role;

update public.orders o
   set created_by_name = p.full_name,
       created_by_role = p.role
  from public.profiles p
 where p.id = o.created_by
   and o.created_by_name is null;

create or replace function public.stamp_order_creator_name()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.created_by is not null then
    select full_name, role into new.created_by_name, new.created_by_role
      from public.profiles where id = new.created_by;
  end if;
  return new;
end;
$$;

drop trigger if exists stamp_order_creator on public.orders;
create trigger stamp_order_creator
  before insert on public.orders
  for each row execute function public.stamp_order_creator_name();

revoke all on function public.stamp_order_creator_name() from public;
