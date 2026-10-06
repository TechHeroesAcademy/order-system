import type { OrderStatus } from "@/types/database";

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

export const ORDER_SLA_HOURS = 48;

export function isOrderDelayed(status: OrderStatus, createdAt: string, now: Date = new Date()): boolean {
  if (isTerminalStatus(status)) return false;
  const created = new Date(createdAt);
  const hoursOpen = (now.getTime() - created.getTime()) / (1000 * 60 * 60);
  return hoursOpen > ORDER_SLA_HOURS;
}


export const EVENT_TYPE_LABELS_AR: Record<string, string> = {
  created: "تم إنشاء الأوردر",
  distribution_set: "تم تحديد مندوب (بانتظار الاعتماد)",
  distribution_cleared: "تم إلغاء التوزيع المقترح",
  distribution_approved: "تم اعتماد التوزيع",
  driver_reassigned: "تم تعيين/تغيير المندوب",
  factory_reassigned: "تم تعيين/تغيير المصنع",
  collected_from_customer: "تم الاستلام من العميل",
  pickup_code_mismatch: "محاولة استلام من العميل بكود غير صحيح",
  handed_to_factory: "توجه المندوب بالأوردر للمصنع",
  factory_confirmed_receipt: "المصنع أكد الاستلام",
  factory_marked_ready: "المصنع جهّز الأوردر للتسليم",
  driver_picked_up_from_factory: "استلم المندوب الأوردر من المصنع",
  delivery_code_mismatch: "محاولة تسليم بكود غير صحيح",
  delivered: "تم التسليم للعميل",
  refused: "رفض العميل الاستلام",
  delivery_retry: "إعادة محاولة التسليم",
  cancelled: "تم إلغاء الأوردر",
  details_edited: "تم تعديل بيانات الأوردر",
};

export function eventTypeLabel(eventType: string): string {
  return EVENT_TYPE_LABELS_AR[eventType] ?? eventType;
}
