do $$
declare
  v_armed boolean := false;

  v_users bigint; v_profiles bigint; v_orders bigint; v_hist bigint;
  v_msgs bigint; v_notif bigint; v_regions bigint; v_factories bigint;
  v_subs bigint; v_dr bigint; v_mf bigint; v_left bigint;
begin
  if not v_armed then
    raise exception
      'Not armed — nothing has been deleted. This script removes every '
      'account and every order in this database, with no undo. Read the '
      'header, set v_armed := true on the marked line, and run it again.';
  end if;

  select count(*) into v_users     from auth.users;
  select count(*) into v_profiles  from public.profiles;
  select count(*) into v_orders    from public.orders;
  select count(*) into v_hist      from public.order_history;
  select count(*) into v_msgs      from public.order_messages;
  select count(*) into v_notif     from public.notifications;
  select count(*) into v_regions   from public.regions;
  select count(*) into v_factories from public.factories;
  select count(*) into v_subs      from public.push_subscriptions;
  select count(*) into v_dr        from public.driver_regions;
  select count(*) into v_mf        from public.manager_factories;

  raise notice '';
  raise notice '=== about to delete ===';
  raise notice 'logins (auth.users)      %', v_users;
  raise notice 'profiles                 %', v_profiles;
  raise notice 'orders                   %', v_orders;
  raise notice 'order history entries    %', v_hist;
  raise notice 'chat messages            %', v_msgs;
  raise notice 'notifications            %', v_notif;
  raise notice 'regions                  %', v_regions;
  raise notice 'factories                %', v_factories;
  raise notice 'registered push devices  %', v_subs;
  raise notice 'driver area assignments  %', v_dr;
  raise notice 'manager factory links    %', v_mf;
  raise notice '';

  delete from public.order_messages;
  delete from public.order_history;
  delete from public.order_delivery_codes;
  delete from public.order_pickup_codes;
  delete from public.notifications;
  delete from public.push_subscriptions;
  delete from public.manager_factories;
  delete from public.driver_regions;
  delete from public.orders;
  delete from public.factories;
  delete from public.regions;

  delete from auth.users;

  perform setval('public.order_number_seq', 1, false);

  select (select count(*) from auth.users) + (select count(*) from public.profiles)
       + (select count(*) from public.orders) + (select count(*) from public.order_history)
       + (select count(*) from public.order_messages) + (select count(*) from public.notifications)
       + (select count(*) from public.regions) + (select count(*) from public.factories)
       + (select count(*) from public.push_subscriptions) + (select count(*) from public.driver_regions)
       + (select count(*) from public.manager_factories)
       + (select count(*) from public.order_delivery_codes)
       + (select count(*) from public.order_pickup_codes)
    into v_left;

  if v_left <> 0 then
    raise exception
      'Expected every account and order table to be empty and found % '
      'row(s) still there. Nothing has been deleted — this whole block has '
      'rolled back. This usually means a new table or foreign key was added '
      'after this script was written.', v_left;
  end if;

  raise notice '=== empty. rows left across every account and order table: 0 ===';
  raise notice 'next order number will be ORD-00001';
  raise notice 'push config kept: % row(s) in app_settings',
    (select count(*) from public.app_settings);
  raise notice '';
  raise notice 'Now: sign out (or clear this site''s cookies), then open /setup';
  raise notice 'to create the first owner. /setup only works while no owner';
  raise notice 'exists, so it is available again from this moment.';
  raise notice '';
end$$;

