import type { OrderStatus, UserRole } from "@/types/database";

/**
 * Single source of truth (client-side) for how order statuses are labeled,
 * colored, and sequenced. The *authoritative* state machine lives in the
 * database RPCs (supabase/migrations/0009_workflow_rpcs.sql) — this module
 * mirrors it for UI purposes (labels, badges, "what can happen next" hints)
 * and is unit tested to make sure it never drifts from that source of truth.
 */

export const ORDER_STATUS_SEQUENCE: OrderStatus[] = [
  "new",
  "assigned",
  "collected",
  "at_factory",
  "ready",
  "with_driver",
  "delivered",
];

export const TERMINAL_STATUSES: OrderStatus[] = ["delivered", "refused", "cancelled"];

export const ORDER_STATUS_LABELS_AR: Record<OrderStatus, string> = {
  new: "جديد",
  assigned: "مسند لمندوب",
  collected: "تم الاستلام من العميل",
  at_factory: "داخل المصنع",
  ready: "جاهز للتسليم",
  with_driver: "مع المندوب",
  delivered: "تم التسليم",
  refused: "رفض الاستلام",
  cancelled: "ملغى",
};

export const ORDER_STATUS_BADGE_VARIANT: Record<
  OrderStatus,
  "default" | "secondary" | "success" | "warning" | "destructive" | "outline"
> = {
  new: "outline",
  assigned: "secondary",
  collected: "secondary",
  at_factory: "default",
  ready: "warning",
  with_driver: "warning",
  delivered: "success",
  refused: "destructive",
  cancelled: "destructive",
};

export function isTerminalStatus(status: OrderStatus): boolean {
  return TERMINAL_STATUSES.includes(status);
}

export function statusProgressPercent(status: OrderStatus): number {
  if (status === "refused" || status === "cancelled") return 100;
  const idx = ORDER_STATUS_SEQUENCE.indexOf(status);
  if (idx === -1) return 0;
  return Math.round((idx / (ORDER_STATUS_SEQUENCE.length - 1)) * 100);
}

/** SLA threshold — kept in sync with `order_sla_hours()` in the database. */
export const ORDER_SLA_HOURS = 48;

export function isOrderDelayed(status: OrderStatus, createdAt: string, now: Date = new Date()): boolean {
  if (isTerminalStatus(status)) return false;
  const created = new Date(createdAt);
  const hoursOpen = (now.getTime() - created.getTime()) / (1000 * 60 * 60);
  return hoursOpen > ORDER_SLA_HOURS;
}

/**
 * Which role is expected to act next while an order sits in a given status.
 * Used to route notifications/empty-states, not to authorize anything (the
 * database is the authority on that).
 */
export const NEXT_ACTOR_BY_STATUS: Record<OrderStatus, UserRole | null> = {
  new: "owner",
  assigned: "driver",
  collected: "driver",
  at_factory: "factory",
  ready: "driver",
  with_driver: "driver",
  delivered: null,
  refused: "owner",
  cancelled: null,
};

/** Human label for a raw order_history.event_type value. */
export const EVENT_TYPE_LABELS_AR: Record<string, string> = {
  created: "تم إنشاء الأوردر",
  distribution_set: "تم تحديد مندوب (بانتظار الاعتماد)",
  distribution_cleared: "تم إلغاء التوزيع المقترح",
  distribution_approved: "تم اعتماد التوزيع",
  driver_reassigned: "تم تعيين/تغيير المندوب",
  factory_reassigned: "تم تعيين/تغيير المصنع",
  collected_from_customer: "تم الاستلام من العميل",
  handed_to_factory: "توجه المندوب بالأوردر للمصنع",
  factory_confirmed_receipt: "المصنع أكد الاستلام",
  factory_marked_ready: "المصنع جهّز الأوردر للتسليم",
  driver_picked_up_from_factory: "استلم المندوب الأوردر من المصنع",
  delivery_code_mismatch: "محاولة تسليم بكود غير صحيح",
  delivered: "تم التسليم للعميل",
  refused: "رفض العميل الاستلام",
  cancelled: "تم إلغاء الأوردر",
  details_edited: "تم تعديل بيانات الأوردر",
};

export function eventTypeLabel(eventType: string): string {
  return EVENT_TYPE_LABELS_AR[eventType] ?? eventType;
}
