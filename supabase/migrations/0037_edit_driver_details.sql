-- 0037_edit_driver_details.sql
--
-- A driver's name could not be corrected anywhere in the app — it was set
-- once at account creation and that was that, so a typo stayed on every order
-- they ever handled. This adds an edit path for it, and narrows who may edit
-- a driver's details to managers only.
--
-- Phone is deliberately NOT editable here. It is the login identity, so
-- changing it changes how someone signs in and needs the auth side kept in
-- step — out of scope for this change rather than half-done.

-- ── edit a worker's name ────────────────────────────────────────────────
-- The name is stamped onto orders at assignment time (migration 0032) so it
-- survives the account being deleted. That snapshot is what every order list
-- and report reads, so correcting the name without touching those rows would
-- fix it in one place and leave it wrong everywhere it's actually read.
-- Backfilling is therefore unconditional: a corrected name is corrected
-- everywhere, which is what "fix the name" means to the person asking.
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

  -- Keep the order snapshots in step. Scoped to this person's own rows, and
  -- only where the name actually differs, so it writes nothing when a manager
  -- opens the dialog and saves without changing anything.
  update public.orders
     set assigned_driver_name = v_name
   where assigned_driver_id = p_user_id
     and assigned_driver_name is distinct from v_name;
end;
$$;

-- ── coverage editing becomes manager-only ───────────────────────────────
-- 0025 deliberately left this at Manager-or-Moderator while assignment and
-- account creation were narrowed to Manager in 0024. That split is being
-- closed on purpose: coverage decides which driver gets auto-suggested for an
-- area, so it is an assignment decision in everything but name, and it now
-- sits with the same role that approves assignments. Body is otherwise
-- unchanged from 0025.
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
