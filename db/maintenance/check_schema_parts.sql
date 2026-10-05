with marker(part, label, kind, name) as (values
  (1, 'part 1 of 4', 'table', 'order_delivery_codes'),
  (1, 'part 1 of 4', 'table', 'order_messages'),
  (1, 'part 1 of 4', 'function', 'notify_staff'),
  (1, 'part 1 of 4', 'function', 'can_read_order_channel'),
  (1, 'part 1 of 4', 'function', 'update_order_details'),
  (2, 'part 2 of 4', 'table', 'push_subscriptions'),
  (2, 'part 2 of 4', 'table', 'app_settings'),
  (2, 'part 2 of 4', 'function', 'dispatch_push_notification'),
  (2, 'part 2 of 4', 'function', 'moderator_notification_types'),
  (2, 'part 2 of 4', 'function', 'stamp_order_creator_name'),
  (3, 'part 3 of 4', 'function', 'order_source_label'),
  (3, 'part 3 of 4', 'function', 'customer_order_history'),
  (3, 'part 3 of 4', 'function', 'order_customer_context'),
  (4, 'part 4 of 4', 'table', 'user_credentials'),
  (4, 'part 4 of 4', 'function', 'push_outbox_mark_sent'),
  (4, 'part 4 of 4', 'function', 'push_outbox_mark_failed'),
  (4, 'part 4 of 4', 'function', 'push_outbox_prune')
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
