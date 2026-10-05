import type { CustomerOrderHistory, OrderCustomerContext } from "@/types/database";
import { ORDER_STATUS_LABELS_AR } from "@/lib/domain/order-status";

export function phoneMatchKey(phone: string): string {
  return phone.replace(/\D/g, "").slice(-8);
}

export function isPhoneLookupReady(phone: string): boolean {
  return phoneMatchKey(phone).length >= 8;
}

export interface RepeatCustomerNotice {
  isRepeat: boolean;
  orderIndex: number;
  title: string;
  breakdown: string;
  lastOrderLine: string | null;
  openWarning: string | null;
  nameMismatch: string | null;
}

export function buildRepeatCustomerNotice(
  history: CustomerOrderHistory,
  typedName = "",
): RepeatCustomerNotice {
  const previous = history.previous_orders ?? 0;
  const orderIndex = previous + 1;

  if (previous <= 0) {
    return {
      isRepeat: false,
      orderIndex: 1,
      title: "",
      breakdown: "",
      lastOrderLine: null,
      openWarning: null,
      nameMismatch: null,
    };
  }

  const parts: string[] = [];
  if (history.delivered_orders > 0) parts.push(`${history.delivered_orders} تم تسليمها`);
  if (history.open_orders > 0) parts.push(`${history.open_orders} ما زالت جارية`);
  if (history.refused_orders > 0) parts.push(`${history.refused_orders} رفض الاستلام`);
  if (history.cancelled_orders > 0) parts.push(`${history.cancelled_orders} ملغاة`);

  let lastOrderLine: string | null = null;
  if (history.last_order_number) {
    const status = history.last_order_status
      ? ORDER_STATUS_LABELS_AR[history.last_order_status]
      : null;
    const when = formatArabicDate(history.last_order_at);
    lastOrderLine =
      `آخر أوردر له: ${history.last_order_number}` +
      (when ? ` بتاريخ ${when}` : "") +
      (status ? ` — ${status}` : "");
  }

  const openWarning =
    history.open_orders > 0
      ? `تنبيه: لدى هذا العميل ${history.open_orders === 1 ? "أوردر" : history.open_orders + " أوردرات"} لم يُسلَّم بعد. ` +
        `تأكد أن هذا أوردر جديد فعلًا وليس نفس الأوردر يُسجَّل مرة ثانية.`
      : null;

  const nameMismatch = buildNameMismatch(history.names_seen, typedName);

  return {
    isRepeat: true,
    orderIndex,
    title: `هذا العميل لديه ${previous === 1 ? "أوردر واحد سابق" : `${previous} أوردرات سابقة`} — هذا سيكون الأوردر رقم ${orderIndex} له`,
    breakdown: parts.join(" · "),
    lastOrderLine,
    openWarning,
    nameMismatch,
  };
}

function normalizeName(name: string): string {
  return name.trim().replace(/\s+/g, " ");
}

function buildNameMismatch(namesSeen: string[] | null, typedName: string): string | null {
  const names = (namesSeen ?? []).map(normalizeName).filter(Boolean);
  if (names.length === 0) return null;

  const typed = normalizeName(typedName);
  if (!typed || names.some((n) => n === typed)) return null;

  return names.length === 1
    ? `هذا الرقم مسجَّل سابقًا باسم: ${names[0]} — تأكد من الرقم والاسم.`
    : `هذا الرقم مسجَّل سابقًا بأسماء: ${names.join("، ")} — تأكد من الرقم والاسم.`;
}

function formatArabicDate(value: string | null): string | null {
  if (!value) return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return null;
  return new Intl.DateTimeFormat("ar-EG-u-nu-latn", {
    year: "numeric",
    month: "long",
    day: "numeric",
  }).format(date);
}

export interface CustomerSequenceNote {
  index: number;
  total: number;
  headline: string;
  openWarning: string | null;
  previous: { id: string; label: string } | null;
}

export function buildCustomerSequenceNote(
  context: OrderCustomerContext | null,
): CustomerSequenceNote | null {
  if (!context || context.total_orders <= 1) return null;

  const previous =
    context.previous_order_id && context.previous_order_number
      ? {
          id: context.previous_order_id,
          label:
            `الأوردر السابق: ${context.previous_order_number}` +
            (formatArabicDate(context.previous_order_at) ? ` (${formatArabicDate(context.previous_order_at)})` : "") +
            (context.previous_order_status
              ? ` — ${ORDER_STATUS_LABELS_AR[context.previous_order_status]}`
              : ""),
        }
      : null;

  return {
    index: context.customer_order_index,
    total: context.total_orders,
    headline: `عميل مكرر — هذا الأوردر رقم ${context.customer_order_index} من ${context.total_orders} لهذا العميل`,
    openWarning:
      context.other_open_orders > 0
        ? `لهذا العميل ${context.other_open_orders === 1 ? "أوردر آخر" : `${context.other_open_orders} أوردرات أخرى`} لم يُسلَّم بعد — راجعه قبل إرسال مندوب مرة ثانية.`
        : null,
    previous,
  };
}
