"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { requireRole } from "@/lib/auth";
import { orderFormSchema, editOrderSchema, trackOrderSchema } from "@/lib/domain/validators";
import { listAllOrdersForExport } from "@/lib/data/orders";
import { buildCsv } from "@/lib/domain/csv";
import { ORDER_STATUS_LABELS_AR } from "@/lib/domain/order-status";
import { ok, fail, toErrorMessage, type ActionResult } from "./types";
import type {
  NewOrderResult,
  OrderChatChannel,
  OrderMessage,
  SuggestedDriverRow,
  TrackedOrder,
} from "@/types/database";
import type { z } from "zod";

type OrderFormInput = z.infer<typeof orderFormSchema>;

/** Customer-facing website order creation. No auth required. */
export async function createPublicOrderAction(
  input: OrderFormInput,
): Promise<ActionResult<NewOrderResult>> {
  const parsed = orderFormSchema.safeParse(input);
  if (!parsed.success) {
    return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("public_create_order", {
    p_customer_name: parsed.data.customer_name,
    p_customer_phone: parsed.data.customer_phone,
    p_customer_address: parsed.data.customer_address,
    p_region_name: parsed.data.region_name,
    p_pieces_count: parsed.data.pieces_count,
    p_piece_details: parsed.data.piece_details ?? null,
    p_color: parsed.data.color ?? null,
    p_work_required: parsed.data.work_required ?? null,
    p_customer_notes: parsed.data.customer_notes ?? null,
    p_factory_id: parsed.data.factory_id ?? null,
    p_customer_maps_url: parsed.data.customer_maps_url?.trim() || null,
  });

  if (error) return fail(toErrorMessage(error, "تعذر إنشاء الأوردر"));
  revalidatePath("/owner");
  return ok(data as NewOrderResult);
}

/**
 * Moderator/Owner creating an order sourced from a Messenger conversation.
 *
 * As of migration 0027, both roles pick the factory here (previously
 * Owner-only, migration 0024), but neither picks a driver directly, Owner
 * included — OrderForm has no driver field at all anymore. This is the
 * server-side half of that rule (defense in depth — this action could
 * otherwise be called directly, bypassing the form), and the RPC itself
 * re-checks it a third time as the real authorization boundary. Every
 * order's driver is now always the fair, region-based auto-suggestion
 * (create_order_internal), left pending until the Owner approves it from
 * <DistributionPanel> — even for an order the Owner themself created.
 */
export async function createModeratorOrderAction(
  input: OrderFormInput,
): Promise<ActionResult<NewOrderResult>> {
  await requireRole("owner", "moderator");
  const parsed = orderFormSchema.safeParse(input);
  if (!parsed.success) {
    return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");
  }

  if (!parsed.data.factory_id) {
    return fail("يجب اختيار المصنع عند إنشاء الأوردر");
  }
  if (parsed.data.driver_id) {
    return fail("يتم تعيين المندوب تلقائيًا، لا يمكن اختياره عند إنشاء الأوردر");
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("moderator_create_order", {
    p_customer_name: parsed.data.customer_name,
    p_customer_phone: parsed.data.customer_phone,
    p_customer_address: parsed.data.customer_address,
    p_region_name: parsed.data.region_name,
    p_pieces_count: parsed.data.pieces_count,
    p_piece_details: parsed.data.piece_details ?? null,
    p_color: parsed.data.color ?? null,
    p_work_required: parsed.data.work_required ?? null,
    p_customer_notes: parsed.data.customer_notes ?? null,
    p_factory_id: parsed.data.factory_id,
    p_driver_id: null,
    p_customer_maps_url: parsed.data.customer_maps_url?.trim() || null,
  });

  if (error) return fail(toErrorMessage(error, "تعذر إنشاء الأوردر"));
  revalidatePath("/owner");
  revalidatePath("/moderator");
  return ok(data as NewOrderResult);
}

/**
 * Owner/Moderator correcting/updating any customer/order-detail field on an
 * *existing* order (customer name/phone/address, Google Maps link, region,
 * pieces count, piece details, color, work required, notes). Distribution
 * fields (factory_id/driver_id) are excluded — those go through their own
 * dedicated reassignment flow. See update_order_details() in migration 0021.
 */
export async function updateOrderDetailsAction(
  orderId: string,
  input: z.infer<typeof editOrderSchema>,
): Promise<ActionResult> {
  await requireRole("owner", "moderator");
  const parsed = editOrderSchema.safeParse(input);
  if (!parsed.success) {
    return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc("update_order_details", {
    p_order_id: orderId,
    p_customer_name: parsed.data.customer_name,
    p_customer_phone: parsed.data.customer_phone,
    p_customer_address: parsed.data.customer_address,
    p_customer_maps_url: parsed.data.customer_maps_url?.trim() || null,
    p_region_name: parsed.data.region_name,
    p_pieces_count: parsed.data.pieces_count,
    p_piece_details: parsed.data.piece_details ?? null,
    p_color: parsed.data.color ?? null,
    p_work_required: parsed.data.work_required ?? null,
    p_customer_notes: parsed.data.customer_notes ?? null,
  });

  if (error) return fail(toErrorMessage(error, "تعذر تعديل بيانات الأوردر"));
  revalidatePath(`/owner/orders/${orderId}`);
  revalidatePath(`/moderator/orders/${orderId}`);
  return ok(undefined);
}

/**
 * Owner/Moderator looking up an order's plaintext delivery code after the
 * fact (e.g. the customer lost their paper receipt). The code is normally
 * only ever shown once, right at creation — see get_order_delivery_code()
 * in migration 0016 for why it's kept out of reach of everyone else
 * (drivers in particular, for whom seeing it in advance would defeat its
 * whole purpose as delivery proof).
 */
export async function getOrderDeliveryCodeAction(orderId: string): Promise<ActionResult<{ code: string | null }>> {
  await requireRole("owner", "moderator");
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_order_delivery_code", { p_order_id: orderId });
  if (error) return fail(toErrorMessage(error, "تعذر جلب كود التسليم"));
  return ok({ code: (data as string | null) ?? null });
}

/**
 * Owner/Moderator looking up an order's plaintext pickup code (the one the
 * driver needs from the customer to confirm collection) — mirrors
 * getOrderDeliveryCodeAction exactly, see get_order_pickup_code() in
 * migration 0024.
 */
export async function getOrderPickupCodeAction(orderId: string): Promise<ActionResult<{ code: string | null }>> {
  await requireRole("owner", "moderator");
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_order_pickup_code", { p_order_id: orderId });
  if (error) return fail(toErrorMessage(error, "تعذر جلب كود الاستلام"));
  return ok({ code: (data as string | null) ?? null });
}

export async function trackOrderAction(
  input: z.infer<typeof trackOrderSchema>,
): Promise<ActionResult<TrackedOrder | null>> {
  const parsed = trackOrderSchema.safeParse(input);
  if (!parsed.success) {
    return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");
  }

  const supabase = await createClient();
  // track_order returns setof (see migration 0017) — always a plain array,
  // empty for "no order matches both the number and the phone", one row
  // for a match. Never a shape that could be mistaken for a found order.
  const { data, error } = await supabase.rpc("track_order", {
    p_order_number: parsed.data.order_number,
    p_phone: parsed.data.phone,
  });

  if (error) return fail(toErrorMessage(error, "تعذر البحث عن الأوردر"));
  const rows = (data as TrackedOrder[]) ?? [];
  return ok(rows[0] ?? null);
}

// ---------- Owner: distribution ----------

export async function suggestDriversAction(orderId: string): Promise<ActionResult<SuggestedDriverRow[]>> {
  await requireRole("owner", "moderator");
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("suggest_drivers", { p_order_id: orderId });
  if (error) return fail(toErrorMessage(error));
  return ok((data as SuggestedDriverRow[]) ?? []);
}

/** Owner only — see migration 0024 ("moderator cannot assign or edit or change drivers or factories"). */
export async function setOrderDistributionAction(
  orderId: string,
  driverId: string,
  isSuggestion: boolean,
): Promise<ActionResult> {
  await requireRole("owner");
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_order_distribution", {
    p_order_id: orderId,
    p_driver_id: driverId,
    p_is_suggestion: isSuggestion,
  });
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/owner");
  revalidatePath("/moderator");
  return ok(undefined);
}

/** Owner only — see migration 0024. */
export async function clearOrderDistributionAction(orderId: string): Promise<ActionResult> {
  await requireRole("owner");
  const supabase = await createClient();
  const { error } = await supabase.rpc("clear_order_distribution", { p_order_id: orderId });
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/owner");
  revalidatePath("/moderator");
  return ok(undefined);
}

/**
 * Bulk versions for the distribution board. Partial success rides in the
 * data, not in `ok`: every existing caller in this codebase reads `ok:false`
 * as "the call didn't happen", so using it for "3 of 12 failed" would make
 * all of them report that nothing was approved. `ok:false` here still means
 * exactly that — not a manager, or the call itself failed.
 */
export type BulkOutcome = {
  order_id: string;
  order_number: string | null;
  succeeded: boolean;
  error: string | null;
};

export type BulkResult = { approved: number; failures: BulkOutcome[] };

function summarizeBulk(rows: BulkOutcome[]): BulkResult {
  return {
    approved: rows.filter((r) => r.succeeded).length,
    failures: rows.filter((r) => !r.succeeded),
  };
}

export async function approveDistributionBulkAction(
  orderIds: string[],
): Promise<ActionResult<BulkResult>> {
  await requireRole("owner");
  if (orderIds.length === 0) return fail("لم يتم تحديد أي أوردر");

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("approve_distribution_bulk", { p_order_ids: orderIds });
  if (error) return fail(toErrorMessage(error, "تعذر اعتماد التوزيع"));

  revalidatePath("/moderator/distribution");
  revalidatePath("/owner");
  revalidatePath("/moderator");
  revalidatePath("/driver");
  return ok(summarizeBulk((data as BulkOutcome[]) ?? []));
}

export async function setOrderDistributionBulkAction(
  orderIds: string[],
  driverId: string,
): Promise<ActionResult<BulkResult>> {
  await requireRole("owner");
  if (orderIds.length === 0) return fail("لم يتم تحديد أي أوردر");

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("set_order_distribution_bulk", {
    p_order_ids: orderIds,
    p_driver_id: driverId,
  });
  if (error) return fail(toErrorMessage(error, "تعذر تغيير المندوب"));

  revalidatePath("/moderator/distribution");
  revalidatePath("/owner");
  revalidatePath("/moderator");
  return ok(summarizeBulk((data as BulkOutcome[]) ?? []));
}

export async function approveDistributionAction(orderId: string): Promise<ActionResult> {
  await requireRole("owner");
  const supabase = await createClient();
  const { error } = await supabase.rpc("approve_distribution", { p_order_id: orderId });
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/owner");
  revalidatePath("/driver");
  return ok(undefined);
}

/** Change the responsible driver at any point before the order is closed. Owner only — see migration 0024. */
export async function reassignOrderDriverAction(orderId: string, newDriverId: string): Promise<ActionResult> {
  await requireRole("owner");
  const supabase = await createClient();
  const { error } = await supabase.rpc("reassign_order_driver", {
    p_order_id: orderId,
    p_new_driver_id: newDriverId,
  });
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/owner");
  revalidatePath("/moderator");
  revalidatePath("/driver");
  return ok(undefined);
}

/**
 * Change the factory an order is routed to, at any point before it's closed —
 * mirrors reassignOrderDriverAction. Owner only — see migration 0024.
 */
export async function reassignOrderFactoryAction(orderId: string, newFactoryId: string): Promise<ActionResult> {
  await requireRole("owner");
  const supabase = await createClient();
  const { error } = await supabase.rpc("reassign_order_factory", {
    p_order_id: orderId,
    p_new_factory_id: newFactoryId,
  });
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/owner");
  revalidatePath("/moderator");
  revalidatePath("/driver");
  return ok(undefined);
}

/** Owner only (migration 0030) — a Moderator can no longer cancel an order. */
export async function cancelOrderAction(orderId: string, reason: string): Promise<ActionResult> {
  await requireRole("owner");
  const supabase = await createClient();
  const { error } = await supabase.rpc("owner_cancel_order", { p_order_id: orderId, p_reason: reason });
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/owner");
  revalidatePath("/moderator");
  return ok(undefined);
}

// ---------- Driver ----------

/**
 * The driver confirming they physically collected the order from the
 * customer — as of migration 0024, gated by a pickup code exactly like
 * driverDeliverToCustomerAction is gated by the delivery code, so a driver
 * can't tap this without actually getting the code from the customer.
 */
export async function driverMarkCollectedAction(
  orderId: string,
  code: string,
): Promise<ActionResult<{ success: boolean }>> {
  await requireRole("owner", "driver");
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("driver_mark_collected", {
    p_order_id: orderId,
    p_code: code,
  });
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/driver");
  revalidatePath("/owner");
  return ok({ success: Boolean(data) });
}

export async function driverConfirmFactoryPickupAction(orderId: string): Promise<ActionResult> {
  await requireRole("owner", "driver");
  const supabase = await createClient();
  const { error } = await supabase.rpc("driver_confirm_factory_pickup", { p_order_id: orderId });
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/driver");
  revalidatePath("/owner");
  return ok(undefined);
}

export async function driverDeliverToCustomerAction(
  orderId: string,
  code: string,
): Promise<ActionResult<{ success: boolean }>> {
  await requireRole("owner", "driver");
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("driver_deliver_to_customer", {
    p_order_id: orderId,
    p_code: code,
  });
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/driver");
  revalidatePath("/owner");
  return ok({ success: Boolean(data) });
}

export async function driverLogRefusalAction(orderId: string, reason: string): Promise<ActionResult> {
  await requireRole("owner", "driver");
  const supabase = await createClient();
  const { error } = await supabase.rpc("driver_log_refusal", { p_order_id: orderId, p_reason: reason });
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/driver");
  revalidatePath("/owner");
  return ok(undefined);
}

// ---------- Factory ----------

// The RPCs themselves already allow owner/moderator/factory (see
// factory_confirm_receipt / factory_mark_ready in
// supabase/migrations/0009_workflow_rpcs.sql) — an Owner or Moderator can
// step in and manually confirm/ready an order at the factory. This
// requireRole() used to only say "owner"/"factory", silently blocking
// Moderator here even though the database allowed it and the order-detail
// page has no other way to do it — see order-detail-view.tsx's "factory
// actions" panel.
export async function factoryConfirmReceiptAction(orderId: string): Promise<ActionResult> {
  await requireRole("owner", "moderator", "driver");
  const supabase = await createClient();
  const { error } = await supabase.rpc("factory_confirm_receipt", { p_order_id: orderId });
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/driver");
  revalidatePath("/owner");
  revalidatePath("/moderator");
  return ok(undefined);
}

export async function factoryMarkReadyAction(orderId: string): Promise<ActionResult> {
  await requireRole("owner", "moderator", "driver");
  const supabase = await createClient();
  const { error } = await supabase.rpc("factory_mark_ready", { p_order_id: orderId });
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/driver");
  revalidatePath("/owner");
  revalidatePath("/moderator");
  return ok(undefined);
}

// ---------- Per-order chat — two independent channels ----------
// 'driver' (driver <-> Owner/Moderator) and 'factory' (factory <->
// Owner/Moderator), migrations 0018/0019. No requireRole() gate here on
// purpose — send_order_message() and the order_messages RLS policy are the
// real authorization boundary (assigned driver on the driver channel,
// assigned factory on the factory channel, or Owner/Moderator on either;
// anyone else gets a clean "غير مصرح" from the RPC and an empty result from
// a direct select), exactly like every other RPC-backed action in this file.

export async function listOrderMessagesAction(
  orderId: string,
  channel: OrderChatChannel,
): Promise<ActionResult<OrderMessage[]>> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("order_messages")
    .select("*, sender:profiles!order_messages_sender_id_fkey(full_name)")
    .eq("order_id", orderId)
    .eq("channel", channel)
    .order("created_at", { ascending: true });
  if (error) return fail(toErrorMessage(error, "تعذر تحميل الرسائل"));
  return ok((data as unknown as OrderMessage[]) ?? []);
}

export async function sendOrderMessageAction(
  orderId: string,
  channel: OrderChatChannel,
  body: string,
): Promise<ActionResult<OrderMessage>> {
  const trimmed = body.trim();
  if (!trimmed) return fail("اكتب رسالة قبل الإرسال");
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("send_order_message", {
    p_order_id: orderId,
    p_channel: channel,
    p_body: trimmed,
  });
  if (error) return fail(toErrorMessage(error, "تعذر إرسال الرسالة"));
  return ok(data as OrderMessage);
}

/**
 * Owner-only "تحميل كل البيانات" button — every order, unpaginated, as a
 * CSV. Built server-side (rather than shipping listAllOrdersForExport's
 * result to the client and building the file there) so the export can't be
 * trivially recreated for any other role, and so it's one round trip
 * regardless of row count. Returns the CSV text directly in the action
 * result; the button turns it into a Blob download client-side (a Server
 * Action can't set a Content-Disposition response header — this file never
 * touches the network as an actual download until the browser does).
 */
export async function exportOrdersCsvAction(): Promise<ActionResult<{ csv: string; filename: string }>> {
  await requireRole("owner");

  const orders = await listAllOrdersForExport();

  const headers = [
    "رقم الأوردر",
    "الحالة",
    "المصدر",
    "اسم العميل",
    "هاتف العميل",
    "العنوان",
    "المنطقة",
    "عدد الأواني",
    "تفاصيل الإناء",
    "اللون",
    "الخدمة المطلوبة",
    "ملاحظات العميل",
    "المندوب",
    "المصنع",
    "تاريخ الإنشاء",
    "تاريخ التسليم",
    "تاريخ الإلغاء",
    "سبب الإلغاء",
    "سبب الرفض",
  ];

  const rows = orders.map((o) => [
    o.order_number,
    ORDER_STATUS_LABELS_AR[o.status] ?? o.status,
    o.source,
    o.customer_name,
    o.customer_phone,
    o.customer_address,
    o.region?.name ?? "",
    o.pieces_count,
    o.piece_details ?? "",
    o.color ?? "",
    o.work_required ?? "",
    o.customer_notes ?? "",
    o.assigned_driver_name ?? "",
    o.assigned_factory_name ?? "",
    o.created_at,
    o.delivered_at ?? "",
    o.cancelled_at ?? "",
    o.cancel_reason ?? "",
    o.refusal_reason ?? "",
  ]);

  const csv = buildCsv(headers, rows);
  const filename = `orders-export-${new Date().toISOString().slice(0, 10)}.csv`;
  return ok({ csv, filename });
}
