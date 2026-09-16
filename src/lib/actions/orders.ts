"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { requireRole } from "@/lib/auth";
import { orderFormSchema, trackOrderSchema } from "@/lib/domain/validators";
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
    p_region_id: parsed.data.region_id,
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
 * Driver + factory are mandatory for both roles. This is a UI/product rule
 * rather than something the shared orderFormSchema can express, so it's
 * enforced here, server-side, in addition to OrderForm's own client-side
 * check (defense in depth — this action could otherwise be called directly,
 * bypassing the form).
 */
export async function createModeratorOrderAction(
  input: OrderFormInput,
): Promise<ActionResult<NewOrderResult>> {
  await requireRole("owner", "moderator");
  const parsed = orderFormSchema.safeParse(input);
  if (!parsed.success) {
    return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");
  }

  if (!parsed.data.driver_id || !parsed.data.factory_id) {
    return fail("يجب اختيار المندوب والمصنع عند إنشاء الأوردر");
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("moderator_create_order", {
    p_customer_name: parsed.data.customer_name,
    p_customer_phone: parsed.data.customer_phone,
    p_customer_address: parsed.data.customer_address,
    p_region_id: parsed.data.region_id,
    p_pieces_count: parsed.data.pieces_count,
    p_piece_details: parsed.data.piece_details ?? null,
    p_color: parsed.data.color ?? null,
    p_work_required: parsed.data.work_required ?? null,
    p_customer_notes: parsed.data.customer_notes ?? null,
    p_factory_id: parsed.data.factory_id ?? null,
    p_driver_id: parsed.data.driver_id ?? null,
    p_customer_maps_url: parsed.data.customer_maps_url?.trim() || null,
  });

  if (error) return fail(toErrorMessage(error, "تعذر إنشاء الأوردر"));
  revalidatePath("/owner");
  revalidatePath("/moderator");
  return ok(data as NewOrderResult);
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

export async function setOrderDistributionAction(
  orderId: string,
  driverId: string,
  isSuggestion: boolean,
): Promise<ActionResult> {
  await requireRole("owner", "moderator");
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
  await requireRole("owner", "moderator");
  const supabase = await createClient();
  const { error } = await supabase.rpc("clear_order_distribution", { p_order_id: orderId });
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/owner");
  revalidatePath("/moderator");
  return ok(undefined);
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

/** Change the responsible driver at any point before the order is closed. */
export async function reassignOrderDriverAction(orderId: string, newDriverId: string): Promise<ActionResult> {
  await requireRole("owner", "moderator");
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

/** Change the factory an order is routed to, at any point before it's closed — mirrors reassignOrderDriverAction. */
export async function reassignOrderFactoryAction(orderId: string, newFactoryId: string): Promise<ActionResult> {
  await requireRole("owner", "moderator");
  const supabase = await createClient();
  const { error } = await supabase.rpc("reassign_order_factory", {
    p_order_id: orderId,
    p_new_factory_id: newFactoryId,
  });
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/owner");
  revalidatePath("/moderator");
  revalidatePath("/driver");
  revalidatePath("/factory");
  return ok(undefined);
}

export async function cancelOrderAction(orderId: string, reason: string): Promise<ActionResult> {
  await requireRole("owner", "moderator");
  const supabase = await createClient();
  const { error } = await supabase.rpc("owner_cancel_order", { p_order_id: orderId, p_reason: reason });
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/owner");
  revalidatePath("/moderator");
  return ok(undefined);
}

// ---------- Driver ----------

export async function driverMarkCollectedAction(orderId: string): Promise<ActionResult> {
  await requireRole("owner", "driver");
  const supabase = await createClient();
  const { error } = await supabase.rpc("driver_mark_collected", { p_order_id: orderId });
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/driver");
  revalidatePath("/owner");
  return ok(undefined);
}

export async function driverHandToFactoryAction(orderId: string): Promise<ActionResult> {
  await requireRole("owner", "driver");
  const supabase = await createClient();
  const { error } = await supabase.rpc("driver_hand_to_factory", { p_order_id: orderId });
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/driver");
  revalidatePath("/factory");
  return ok(undefined);
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
  await requireRole("owner", "moderator", "factory");
  const supabase = await createClient();
  const { error } = await supabase.rpc("factory_confirm_receipt", { p_order_id: orderId });
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/factory");
  revalidatePath("/driver");
  revalidatePath("/owner");
  revalidatePath("/moderator");
  return ok(undefined);
}

export async function factoryMarkReadyAction(orderId: string): Promise<ActionResult> {
  await requireRole("owner", "moderator", "factory");
  const supabase = await createClient();
  const { error } = await supabase.rpc("factory_mark_ready", { p_order_id: orderId });
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/factory");
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
