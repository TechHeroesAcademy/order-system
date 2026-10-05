/**
 * Every RPC in this schema that can create a notification.
 *
 * Derived from the database rather than guessed: the transitive closure of
 * functions whose body calls notify_user / notify_role / notify_staff. A
 * test re-derives it from pg_proc and fails if the schema grows a notifying
 * function this list does not name, because the failure mode otherwise is a
 * push that arrives late or not at all — silently, again.
 *
 * Read-only RPCs are deliberately absent. Scheduling a drain after
 * dashboard_stats would add a query to every page view, which is the cost
 * the rest of this work went to some trouble to remove.
 */
export const NOTIFYING_RPCS: ReadonlySet<string> = new Set([
  "approve_distribution",
  "approve_distribution_bulk",
  "approve_distribution_one",
  "create_order_internal",
  "driver_confirm_factory_pickup",
  "driver_create_field_order",
  "driver_deliver_to_customer",
  "driver_hand_to_factory",
  "driver_log_refusal",
  "driver_mark_collected",
  "factory_confirm_receipt",
  "factory_mark_ready",
  "moderator_create_order",
  "notify_role",
  "notify_staff",
  "notify_user",
  "owner_cancel_order",
  "public_create_order",
  "reassign_order_driver",
  "reassign_order_factory",
  "reassign_orders_from_driver",
  "send_order_message",
]);
