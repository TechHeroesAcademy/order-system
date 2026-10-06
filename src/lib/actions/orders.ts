"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/db/client";
import { requireRole } from "@/lib/auth";
import { orderFormSchema, editOrderSchema, trackOrderSchema } from "@/lib/domain/validators";
import { listAllOrdersForExport } from "@/lib/data/orders";
import { buildCsv } from "@/lib/domain/csv";
import { ORDER_STATUS_LABELS_AR } from "@/lib/domain/order-status";
import { ok, fail, toErrorMessage, type ActionResult } from "./types";
import type {
  CustomerOrderHistory,
  NewOrderResult,
  OrderChatChannel,
  OrderMessage,
  SuggestedDriverRow,
  TrackedOrder,
} from "@/types/database";
import type { z } from "zod";

type OrderFormInput = z.infer<typeof orderFormSchema>;

export async function createFieldOrderAction(
  input: OrderFormInput,
): Promise<ActionResult<NewOrderResult>> {
  await requireRole("driver");
  const parsed = orderFormSchema.safeParse(input);
  if (!parsed.success) {
    return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");
  }
  if (!parsed.data.factory_id) {
    return fail("يجب اختيار المصنع");
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("driver_create_field_order", {
    p_customer_name: parsed.data.customer_name,
    p_customer_phone: parsed.data.customer_phone,
    p_customer_address: parsed.data.customer_address,
    p_region_name: parsed.data.region_name,
    p_pieces_count: parsed.data.pieces_count,
    p_factory_id: parsed.data.factory_id,
    p_piece_details: parsed.data.piece_details ?? null,
    p_color: parsed.data.color ?? null,
    p_work_required: parsed.data.work_required ?? null,
    p_customer_notes: parsed.data.customer_notes ?? null,
    p_customer_maps_url: parsed.data.customer_maps_url?.trim() || null,
  });

  if (error) return fail(toErrorMessage(error, "تعذر إنشاء الأوردر"));
  revalidatePath("/driver");
  revalidatePath("/owner");
  revalidatePath("/moderator");
  return ok(data as NewOrderResult);
}

export async function lookupCustomerHistoryAction(
  phone: string,
): Promise<ActionResult<CustomerOrderHistory>> {
  await requireRole("owner", "moderator", "driver");

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("customer_order_history", { p_phone: phone });
  if (error) return fail(toErrorMessage(error, "تعذر التحقق من أوردرات العميل السابقة"));

  const row = (data as CustomerOrderHistory[] | null)?.[0];
  if (!row) return fail("تعذر التحقق من أوردرات العميل السابقة");
  return ok(row);
}

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

export async function getOrderDeliveryCodeAction(orderId: string): Promise<ActionResult<{ code: string | null }>> {
  await requireRole("owner", "moderator");
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_order_delivery_code", { p_order_id: orderId });
  if (error) return fail(toErrorMessage(error, "تعذر جلب كود التسليم"));
  return ok({ code: (data as string | null) ?? null });
}

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
  const { data, error } = await supabase.rpc("track_order", {
    p_order_number: parsed.data.order_number,
    p_phone: parsed.data.phone,
  });

  if (error) return fail(toErrorMessage(error, "تعذر البحث عن الأوردر"));
  const rows = (data as TrackedOrder[]) ?? [];
  return ok(rows[0] ?? null);
}

export async function suggestDriversAction(orderId: string): Promise<ActionResult<SuggestedDriverRow[]>> {
  await requireRole("owner", "moderator");
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("suggest_drivers", { p_order_id: orderId });
  if (error) return fail(toErrorMessage(error));
  return ok((data as SuggestedDriverRow[]) ?? []);
}

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

export async function clearOrderDistributionAction(orderId: string): Promise<ActionResult> {
  await requireRole("owner");
  const supabase = await createClient();
  const { error } = await supabase.rpc("clear_order_distribution", { p_order_id: orderId });
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/owner");
  revalidatePath("/moderator");
  return ok(undefined);
}

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

  revalidatePath("/owner/distribution");
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

  revalidatePath("/owner/distribution");
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

export async function cancelOrderAction(orderId: string, reason: string): Promise<ActionResult> {
  await requireRole("owner");
  const supabase = await createClient();
  const { error } = await supabase.rpc("owner_cancel_order", { p_order_id: orderId, p_reason: reason });
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/owner");
  revalidatePath("/moderator");
  return ok(undefined);
}

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

export async function retryDeliveryAction(orderId: string): Promise<ActionResult> {
  await requireRole("owner", "moderator", "driver");
  const supabase = await createClient();
  const { error } = await supabase.rpc("driver_retry_delivery", { p_order_id: orderId });
  if (error) return fail(toErrorMessage(error, "تعذر إعادة فتح الأوردر للتسليم"));
  revalidatePath("/driver");
  revalidatePath("/owner");
  revalidatePath("/moderator");
  return ok(undefined);
}

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

export async function listOrderMessagesAction(
  orderId: string,
  channel: OrderChatChannel,
): Promise<ActionResult<OrderMessage[]>> {
  const supabase = await createClient();
  // Newest 200, then reversed — NOT ascending with a limit, which would keep
  // the OLDEST 200 and hide everything current. This panel is re-read on a
  // timer for as long as the order page is open, so an unbounded select is
  // paid again on every poll rather than once.
  const { data, error } = await supabase
    .from("order_messages")
    .select("*, sender:profiles!order_messages_sender_id_fkey(full_name)")
    .eq("order_id", orderId)
    .eq("channel", channel)
    .order("created_at", { ascending: false })
    .limit(200);
  if (error) return fail(toErrorMessage(error, "تعذر تحميل الرسائل"));
  return ok(((data as unknown as OrderMessage[]) ?? []).reverse());
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
