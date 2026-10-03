import type { CustomerOrderHistory, OrderCustomerContext } from "@/types/database";
import { ORDER_STATUS_LABELS_AR } from "@/lib/domain/order-status";

/**
 * Turning a customer's history into the sentences shown in the confirmation
 * before a new order is created.
 *
 * Kept out of the component and free of React so the wording — which is the
 * whole feature, since the numbers only matter if the person reading them
 * understands what they are being asked to confirm — can be unit tested
 * directly rather than through a rendered form.
 */

/** Digits only, last 8 — the same key the database matches on (migration 0049). */
export function phoneMatchKey(phone: string): string {
  return phone.replace(/\D/g, "").slice(-8);
}

/** Below this there is nothing to look up; see the same guard in the RPC. */
export function isPhoneLookupReady(phone: string): boolean {
  return phoneMatchKey(phone).length >= 8;
}

export interface RepeatCustomerNotice {
  /** Nothing to show — a number that has never ordered. */
  isRepeat: boolean;
  /** Which order this one is for this customer: previous + 1. */
  orderIndex: number;
  /** The headline the person is asked to confirm. */
  title: string;
  /** The breakdown, one short clause per non-zero bucket. */
  breakdown: string;
  /** Their last order, when there is one. */
  lastOrderLine: string | null;
  /**
   * The case worth stopping for: this customer already has an order in
   * flight, so this may be the same job being entered twice. Null when they
   * have none open.
   */
  openWarning: string | null;
  /**
   * Set when the number has been saved under a name that is not the one
   * being typed now — either a different customer's number was entered by
   * mistake, or the same customer was saved under a nickname. Null when the
   * typed name matches what is on file, or when no name is on file.
   */
  nameMismatch: string | null;
}

/**
 * `typedName` is compared loosely — trimmed, whitespace collapsed — because
 * "سمير  علي" and "سمير علي" are the same customer and flagging that as a
 * mismatch would train people to dismiss the dialog without reading it.
 */
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

  // The last order's date, when it is a usable one. An unparseable value is
  // dropped rather than rendered as "Invalid Date" — the line is context,
  // so losing it is better than showing something broken.
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
  // Nothing typed yet, or it already matches one of the names on file.
  if (!typed || names.some((n) => n === typed)) return null;

  return names.length === 1
    ? `هذا الرقم مسجَّل سابقًا باسم: ${names[0]} — تأكد من الرقم والاسم.`
    : `هذا الرقم مسجَّل سابقًا بأسماء: ${names.join("، ")} — تأكد من الرقم والاسم.`;
}

function formatArabicDate(value: string | null): string | null {
  if (!value) return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return null;
  // Latin digits on purpose: every other number in this app's UI is
  // tabular-nums Latin (order numbers, codes, counts), and mixing numeral
  // systems in one dialog reads as a bug.
  return new Intl.DateTimeFormat("ar-EG-u-nu-latn", {
    year: "numeric",
    month: "long",
    day: "numeric",
  }).format(date);
}

export interface CustomerSequenceNote {
  /** This order's fixed position in the customer's sequence. */
  index: number;
  /** How many that customer has in all, today. */
  total: number;
  /** "الأوردر رقم 3 من 4 لهذا العميل" */
  headline: string;
  /**
   * Set when the customer has other orders still in flight. On a field order
   * nobody approved, this is the duplicate the manager is looking for.
   */
  openWarning: string | null;
  /** The order immediately before this one, when there is one. */
  previous: { id: string; label: string } | null;
}

/**
 * The repeat-customer line on an order's own page.
 *
 * Returns null for a customer with a single order — which is most of them.
 * A "1 من 1" line on every order would be noise, and noise is what stops
 * the 3-of-4 case from being noticed.
 */
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
