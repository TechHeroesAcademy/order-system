-- seed.sql
-- Demo data for local development (`supabase start` + `supabase db reset`).
-- Creates auth users directly (local/dev only pattern) so the trigger in
-- 0002_profiles.sql fires and creates matching profiles automatically.
-- On a hosted Supabase project, create real users via the Dashboard or the
-- Admin API instead — see DEPLOYMENT.md.

-- ---------- demo auth users ----------
create or replace procedure public._seed_user(p_id uuid, p_email text, p_full_name text, p_phone text, p_role text)
language plpgsql
as $$
declare
  v_instance_id uuid := '00000000-0000-0000-0000-000000000000';
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token
  ) values (
    v_instance_id, p_id, 'authenticated', 'authenticated', p_email,
    crypt('Passw0rd!', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}',
    jsonb_build_object('full_name', p_full_name, 'phone', p_phone, 'role', p_role),
    now(), now(), '', ''
  )
  on conflict (id) do nothing;

  insert into auth.identities (
    id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at
  ) values (
    gen_random_uuid(), p_id::text, p_id,
    jsonb_build_object('sub', p_id::text, 'email', p_email),
    'email', now(), now(), now()
  )
  on conflict do nothing;
end;
$$;

call public._seed_user('00000000-0000-0000-0000-000000000001', 'owner@demo.local', 'مالك النظام', '01000000001', 'owner');
call public._seed_user('00000000-0000-0000-0000-000000000002', 'moderator@demo.local', 'موديريتور الصفحة', '01000000002', 'moderator');
call public._seed_user('00000000-0000-0000-0000-000000000003', 'driver1@demo.local', 'محمد المندوب', '01000000003', 'driver');
call public._seed_user('00000000-0000-0000-0000-000000000004', 'driver2@demo.local', 'أحمد المندوب', '01000000004', 'driver');
call public._seed_user('00000000-0000-0000-0000-000000000005', 'factory@demo.local', 'مسؤول المصنع', '01000000005', 'factory');

drop procedure public._seed_user(uuid, text, text, text, text);

-- ---------- regions ----------
insert into public.regions (name) values
  ('مدينة نصر'), ('مصر الجديدة'), ('شبرا'), ('المعادي'), ('الدقي')
on conflict (name) do nothing;

-- ---------- driver coverage ----------
insert into public.driver_regions (driver_id, region_id)
select '00000000-0000-0000-0000-000000000003', id from public.regions where name in ('مدينة نصر', 'مصر الجديدة')
on conflict do nothing;

insert into public.driver_regions (driver_id, region_id)
select '00000000-0000-0000-0000-000000000004', id from public.regions where name in ('شبرا', 'المعادي')
on conflict do nothing;

-- ---------- sample orders across every stage ----------
do $$
declare
  v_nasr uuid; v_masr_gdida uuid; v_shobra uuid;
  v_driver1 uuid := '00000000-0000-0000-0000-000000000003';
  v_driver2 uuid := '00000000-0000-0000-0000-000000000004';
  v_owner uuid := '00000000-0000-0000-0000-000000000001';
  r public.new_order_result;
begin
  select id into v_nasr from public.regions where name = 'مدينة نصر';
  select id into v_masr_gdida from public.regions where name = 'مصر الجديدة';
  select id into v_shobra from public.regions where name = 'شبرا';

  -- 1) brand new, unassigned
  perform public.create_order_internal('سارة أحمد', '01111111111', 'مدينة نصر، شارع مصطفى النحاس',
    v_nasr, 3, '3 كراسي', 'بني', 'تنجيد كامل', null, 'website', null);

  -- 2) assigned to driver1, not yet collected
  r := public.create_order_internal('كريم حسن', '01111111112', 'مصر الجديدة، شارع الحجاز',
    v_masr_gdida, 2, 'كنبة صالون', 'رمادي', 'تنظيف وتنجيد', 'يفضل الاتصال قبل الوصول', 'messenger', v_owner);
  update public.orders set assigned_driver_id = v_driver1, suggested_driver_id = v_driver1,
    status = 'assigned', distribution_approved_at = now(), distribution_approved_by = v_owner
    where id = r.order_id;
  perform public.log_order_event(r.order_id, 'distribution_approved', 'new', 'assigned', 'تم اعتماد التوزيع (بيانات تجريبية)');

  -- 3) collected from customer, on the way to factory
  r := public.create_order_internal('منى سيد', '01111111113', 'شبرا، شارع الترعة',
    v_shobra, 1, 'مرتبة', 'أبيض', 'غسيل وتعقيم', null, 'website', null);
  update public.orders set assigned_driver_id = v_driver2, suggested_driver_id = v_driver2,
    status = 'collected', distribution_approved_at = now() - interval '1 day', distribution_approved_by = v_owner,
    collected_at = now() - interval '20 hours'
    where id = r.order_id;
  perform public.log_order_event(r.order_id, 'distribution_approved', 'new', 'assigned', 'تجريبي');
  perform public.log_order_event(r.order_id, 'collected_from_customer', 'assigned', 'collected', 'تجريبي');

  -- 4) at the factory
  r := public.create_order_internal('عمر طارق', '01111111114', 'مدينة نصر، عباس العقاد',
    v_nasr, 4, '4 كراسي سفرة', 'أزرق', 'تنجيد', null, 'website', null);
  update public.orders set assigned_driver_id = v_driver1, suggested_driver_id = v_driver1,
    status = 'at_factory', distribution_approved_at = now() - interval '2 days', distribution_approved_by = v_owner,
    collected_at = now() - interval '2 days', factory_received_at = now() - interval '1 day'
    where id = r.order_id;
  perform public.log_order_event(r.order_id, 'factory_confirmed_receipt', 'collected', 'at_factory', 'تجريبي');

  -- 5) ready for pickup
  r := public.create_order_internal('هدى محمود', '01111111115', 'مصر الجديدة، الميرغني',
    v_masr_gdida, 2, 'وسائد وستائر', 'كريمي', 'غسيل', null, 'messenger', v_owner);
  update public.orders set assigned_driver_id = v_driver1, suggested_driver_id = v_driver1,
    status = 'ready', distribution_approved_at = now() - interval '3 days', distribution_approved_by = v_owner,
    collected_at = now() - interval '3 days', factory_received_at = now() - interval '2 days',
    factory_ready_at = now() - interval '2 hours'
    where id = r.order_id;
  perform public.log_order_event(r.order_id, 'factory_marked_ready', 'at_factory', 'ready', 'تجريبي');

  -- 6) with driver, heading back to customer
  r := public.create_order_internal('ياسمين علي', '01111111116', 'شبرا، شارع الخلفاوي',
    v_shobra, 1, 'سجادة', 'متعدد الألوان', 'غسيل وتنشيف', null, 'website', null);
  update public.orders set assigned_driver_id = v_driver2, suggested_driver_id = v_driver2,
    status = 'with_driver', distribution_approved_at = now() - interval '2 days', distribution_approved_by = v_owner,
    collected_at = now() - interval '2 days', factory_received_at = now() - interval '1 day 12 hours',
    factory_ready_at = now() - interval '5 hours', driver_pickup_at = now() - interval '1 hour'
    where id = r.order_id;
  perform public.log_order_event(r.order_id, 'driver_picked_up_from_factory', 'ready', 'with_driver', 'تجريبي');

  -- 7) delivered & closed
  r := public.create_order_internal('محمود فتحي', '01111111117', 'مدينة نصر، مكرم عبيد',
    v_nasr, 2, 'كرسي مكتب', 'أسود', 'تنجيد جلد', null, 'website', null);
  update public.orders set assigned_driver_id = v_driver1, suggested_driver_id = v_driver1,
    status = 'delivered', distribution_approved_at = now() - interval '5 days', distribution_approved_by = v_owner,
    collected_at = now() - interval '5 days', factory_received_at = now() - interval '4 days',
    factory_ready_at = now() - interval '2 days', driver_pickup_at = now() - interval '1 day 12 hours',
    delivered_at = now() - interval '1 day'
    where id = r.order_id;
  perform public.log_order_event(r.order_id, 'delivered', 'with_driver', 'delivered', 'تجريبي');

  -- 8) refused by customer
  r := public.create_order_internal('إيمان صلاح', '01111111118', 'شبرا، شارع أبو العلا',
    v_shobra, 1, 'ستارة', 'وردي', 'كي وتغليف', null, 'website', null);
  update public.orders set assigned_driver_id = v_driver2, suggested_driver_id = v_driver2,
    status = 'refused', distribution_approved_at = now() - interval '4 days', distribution_approved_by = v_owner,
    collected_at = now() - interval '4 days', factory_received_at = now() - interval '3 days',
    factory_ready_at = now() - interval '2 days', driver_pickup_at = now() - interval '1 day',
    refused_at = now() - interval '20 hours', refusal_reason = 'العميل غير موجود في العنوان ورفض الاستلام لاحقًا'
    where id = r.order_id;
  perform public.log_order_event(r.order_id, 'refused', 'with_driver', 'refused', 'تجريبي');

  -- 9) delayed: created 4 days ago, still stuck at "new" with no distribution
  r := public.create_order_internal('طه رمضان', '01111111119', 'مدينة نصر، طيبة',
    v_nasr, 5, '5 قطع أثاث', 'بني فاتح', 'تنجيد كامل', 'الأوردر متأخر لأغراض العرض التجريبي', 'website', null);
  update public.orders set created_at = now() - interval '4 days' where id = r.order_id;

end $$;
