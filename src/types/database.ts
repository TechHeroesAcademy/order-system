/**
 * Hand-written types mirroring the Supabase schema in `supabase/migrations`.
 * If the schema changes, update this file (or regenerate with
 * `supabase gen types typescript` once you have a live project — see README).
 */

export type UserRole = "owner" | "moderator" | "driver" | "factory";

export type OrderStatus =
  | "new"
  | "assigned"
  | "collected"
  | "at_factory"
  | "ready"
  | "with_driver"
  | "delivered"
  | "refused"
  | "cancelled";

export type OrderSource = "website" | "messenger";

export interface Profile {
  id: string;
  full_name: string;
  phone: string | null;
  role: UserRole;
  region_id: string | null;
  is_active: boolean;
  created_at: string;
  updated_at: string;
}

export interface Region {
  id: string;
  name: string;
  created_at: string;
}

export interface DriverRegion {
  driver_id: string;
  region_id: string;
}

export interface Order {
  id: string;
  order_number: string;
  source: OrderSource;
  status: OrderStatus;

  customer_name: string;
  customer_phone: string;
  customer_address: string;
  region_id: string | null;
  pieces_count: number;
  piece_details: string | null;
  color: string | null;
  work_required: string | null;
  customer_notes: string | null;

  assigned_driver_id: string | null;
  suggested_driver_id: string | null;
  distribution_approved_at: string | null;
  distribution_approved_by: string | null;

  collected_at: string | null;
  factory_received_at: string | null;
  factory_ready_at: string | null;
  driver_pickup_at: string | null;
  delivered_at: string | null;
  refused_at: string | null;
  refusal_reason: string | null;
  cancelled_at: string | null;
  cancel_reason: string | null;

  failed_code_attempts: number;
  delivery_code_last_attempt_at: string | null;

  created_by: string | null;
  created_at: string;
  updated_at: string;
}

export interface OrderWithRelations extends Order {
  region?: Region | null;
  assigned_driver?: Pick<Profile, "id" | "full_name" | "phone"> | null;
}

export interface OrderHistoryEntry {
  id: string;
  order_id: string;
  event_type: string;
  from_status: OrderStatus | null;
  to_status: OrderStatus | null;
  actor_id: string | null;
  actor_role: UserRole | null;
  note: string | null;
  created_at: string;
}

export interface AppNotification {
  id: string;
  user_id: string;
  order_id: string | null;
  type: string;
  title: string;
  body: string | null;
  is_read: boolean;
  created_at: string;
}

export interface FactoryOrderRow {
  id: string;
  order_number: string;
  status: OrderStatus;
  pieces_count: number;
  piece_details: string | null;
  color: string | null;
  work_required: string | null;
  assigned_driver_id: string | null;
  assigned_driver_name: string | null;
  collected_at: string | null;
  factory_received_at: string | null;
  factory_ready_at: string | null;
  created_at: string;
}

export interface DashboardStats {
  total_orders: number;
  new_orders: number;
  assigned_orders: number;
  collected_orders: number;
  at_factory_orders: number;
  ready_orders: number;
  with_driver_orders: number;
  delivered_orders: number;
  refused_orders: number;
  cancelled_orders: number;
  delayed_orders: number;
}

export interface DailyReport {
  new_orders: number;
  collected_orders: number;
  entered_factory: number;
  in_factory_now: number;
  ready_now: number;
  exited_factory: number;
  delivered_orders: number;
  delayed_orders: number;
}

export interface MonthlyReport {
  total_orders: number;
  total_pieces: number;
  completed_orders: number;
  delayed_orders: number;
  avg_completion_hours: number | null;
  on_time_rate: number | null;
  prev_total_orders: number;
  prev_completed_orders: number;
  orders_change_percent: number | null;
}

export interface DriverPerformanceRow {
  driver_id: string;
  full_name: string;
  total_orders: number;
  completed_orders: number;
  delayed_orders: number;
  active_orders: number;
  avg_completion_hours: number | null;
  refusal_count: number;
}

export interface DelayedOrderRow {
  id: string;
  order_number: string;
  customer_name: string;
  region_name: string | null;
  driver_name: string | null;
  status: OrderStatus;
  created_at: string;
  hours_open: number;
}

export interface TopRegionRow {
  region_name: string;
  order_count: number;
}

export interface SuggestedDriverRow {
  driver_id: string;
  full_name: string;
  covers_region: boolean;
  active_orders_count: number;
}

export interface TrackedOrder {
  order_number: string;
  status: OrderStatus;
  pieces_count: number;
  created_at: string;
  collected_at: string | null;
  factory_received_at: string | null;
  factory_ready_at: string | null;
  driver_pickup_at: string | null;
  delivered_at: string | null;
  refused_at: string | null;
  is_delayed: boolean;
}

export interface NewOrderResult {
  order_id: string;
  order_number: string;
  delivery_code: string;
}
