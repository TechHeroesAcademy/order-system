/**
 * Hand-written types mirroring the Supabase schema in `supabase/migrations`.
 * If the schema changes, update this file (or regenerate with
 * `supabase gen types typescript` once you have a live project — see README).
 */

/**
 * "factory" is retained here for historical rows only — `order_history.actor_role`
 * and `order_messages.sender_role` still hold it for work done back when factories
 * were login accounts, and those records must keep rendering. No new account can
 * have this role; use `CreatableUserRole` anywhere an account is being created.
 * (Postgres has no way to drop an enum value either — see migration 0033.)
 */
export type UserRole = "owner" | "moderator" | "driver" | "factory";

/** The roles a new staff account may actually be given. */
export type CreatableUserRole = Exclude<UserRole, "factory">;

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
  /** Free-text location/address. Only meaningful (and only shown) for role="factory" today. */
  address: string | null;
  /** Precise coordinates alongside `address` — only meaningful for role="factory". Null until set by clicking the factory's pin on the one general map (see FactoriesMapPanel / FactoriesMap). Powers the exact-location Maps link and the Leaflet map/pin, instead of a text-address search. */
  lat: number | null;
  lng: number | null;
  /** Optional pasted Google Maps link (a Maps "share" link) — only meaningful for role="factory". Takes priority over lat/lng and address in mapsUrlFor() whenever present. */
  maps_url: string | null;
  is_active: boolean;
  password_set: boolean;
  created_at: string;
  updated_at: string;
}

/**
 * A workshop an order is routed to. Factories used to be `profiles` rows with
 * role="factory" — i.e. staff accounts with a login — which is why the address
 * and map fields still exist on Profile above. Since migration 0033 they are
 * their own table with no login at all.
 */
export interface Factory {
  id: string;
  name: string;
  phone: string | null;
  address: string | null;
  /** Precise coordinates, set by clicking the factory's pin on the factories map. Takes priority over `address` when building a Maps link. */
  lat: number | null;
  lng: number | null;
  /** Optional pasted Google Maps "share" link. Wins over lat/lng and address in mapsUrlFor(). */
  maps_url: string | null;
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
  /** Optional pasted Google Maps link (a Maps "share" link, e.g. .../maps/place/...) — takes priority over customer_address in mapsUrlFor() whenever present. */
  customer_maps_url: string | null;
  region_id: string | null;
  pieces_count: number;
  piece_details: string | null;
  color: string | null;
  work_required: string | null;
  customer_notes: string | null;

  assigned_driver_id: string | null;
  /** Snapshot of the driver's name at assignment time (migration 0032) — stays put even after the driver account is deleted, so a deleted worker's name never disappears from an order they were assigned to. Prefer this over looking the id up in a live staff list. */
  assigned_driver_name: string | null;
  suggested_driver_id: string | null;
  distribution_approved_at: string | null;
  distribution_approved_by: string | null;
  assigned_factory_id: string | null;
  /** Snapshot of the factory's name at assignment time (migration 0032) — same rationale as assigned_driver_name. */
  assigned_factory_name: string | null;
  handed_to_factory_at: string | null;

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
  failed_pickup_code_attempts: number;
  pickup_code_last_attempt_at: string | null;

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
  assigned_factory_id: string | null;
  assigned_factory_name: string | null;
  assigned_factory_address: string | null;
  collected_at: string | null;
  handed_to_factory_at: string | null;
  factory_received_at: string | null;
  factory_ready_at: string | null;
  /** Added in 0022 alongside permanent factory history access — when the driver picked the order back up from the factory. */
  driver_pickup_at: string | null;
  /** Added in 0022 — when the order was delivered to the customer, for history rows past the factory's own steps. */
  delivered_at: string | null;
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
  on_time_rate: number | null;
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
  pickup_code: string;
}

/** Which per-order conversation a message belongs to — see migration 0019. */
/**
 * "factory" remains only for messages sent before factories stopped being
 * accounts — send_order_message rejects it now (migration 0034). New
 * messages are always "driver".
 */
export type OrderChatChannel = "driver" | "factory";

/**
 * One message in a per-order chat thread. Two independent channels per
 * order: 'driver' (driver <-> Owner/Moderator, migration 0018) and
 * 'factory' (factory <-> Owner/Moderator, migration 0019) — genuinely
 * separate conversations, never shared.
 */
export interface OrderMessage {
  id: string;
  order_id: string;
  channel: OrderChatChannel;
  sender_id: string;
  sender_role: UserRole;
  body: string;
  created_at: string;
  /**
   * Which driver's "stint" this message belongs to (migration 0029) — set
   * to the order's assigned_driver_id at the moment it was sent, null for
   * the factory channel. RLS uses this to keep a newly-assigned driver from
   * reading a prior driver's conversation on the same order; Owner/Moderator
   * always see everything regardless.
   */
  driver_id: string | null;
  /** Joined from profiles — present on every read, absent only on the just-inserted row returned by send_order_message(). */
  sender?: { full_name: string } | null;
}
