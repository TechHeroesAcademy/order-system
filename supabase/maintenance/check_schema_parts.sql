with marker(part, label, kind, name) as (values
  (1, 'part 1 — core tables & workflow',      'table',    'orders'),
  (1, 'part 1 — core tables & workflow',      'function', 'create_order_internal'),
  (2, 'part 2 — chat, codes, reports',        'table',    'order_messages'),
  (2, 'part 2 — chat, codes, reports',        'function', 'track_order'),
  (3, 'part 3 — factories, bulk, push',       'table',    'factories'),
  (3, 'part 3 — factories, bulk, push',       'table',    'push_subscriptions'),
  (3, 'part 3 — factories, bulk, push',       'function', 'approve_distribution_bulk'),
  (4, 'part 4 — the enum migration',          'function', 'stamp_order_creator_name'),
  (5, 'part 5 — field orders, repeat check',  'function', 'driver_create_field_order'),
  (5, 'part 5 — field orders, repeat check',  'function', 'customer_order_history'),
  (5, 'part 5 — field orders, repeat check',  'function', 'order_customer_context'),
  (6, 'part 6 — auth without Supabase',       'table',    'user_credentials'),
  (6, 'part 6 — auth without Supabase',       'function', 'bootstrap_owner'),
  (6, 'part 6 — auth without Supabase',       'function', 'auth_verify_login'),
  (6, 'part 6 — auth without Supabase',       'function', 'create_staff_account'),
  (6, 'part 6 — auth without Supabase',       'function', 'owner_exists'),
  (6, 'part 6 — auth without Supabase',       'function', 'push_dispatch_payload')
)
select m.part,
       m.label,
       m.kind || ' ' || m.name as object,
       case when m.kind = 'table'
                 then to_regclass('public.' || m.name) is not null
            else exists (select 1 from pg_proc p
                           join pg_namespace n on n.oid = p.pronamespace
                          where n.nspname = 'public' and p.proname = m.name)
       end as present
  from marker m
 order by m.part, m.name;
