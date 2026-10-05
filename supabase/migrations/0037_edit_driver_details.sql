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
