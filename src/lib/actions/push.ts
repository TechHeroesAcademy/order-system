"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentProfile, requireRole } from "@/lib/auth";
import { ok, fail, toErrorMessage, type ActionResult } from "./types";

/**
 * Register this browser-on-this-device to receive push notifications.
 *
 * The caller's identity is NOT taken from anything the client sends — the
 * RPC reads auth.uid() itself (migration 0040). That matters: if the user id
 * were a parameter, anyone who could call this action could point their own
 * device at a colleague's account and start receiving that person's order
 * assignments and chat messages.
 */
export async function savePushSubscriptionAction(subscription: {
  endpoint: string;
  p256dh: string;
  auth: string;
  userAgent?: string;
}): Promise<ActionResult> {
  const profile = await getCurrentProfile();
  if (!profile) return fail("يجب تسجيل الدخول");

  const supabase = await createClient();
  const { error } = await supabase.rpc("save_push_subscription", {
    p_endpoint: subscription.endpoint,
    p_p256dh: subscription.p256dh,
    p_auth: subscription.auth,
    p_user_agent: subscription.userAgent ?? null,
  });
  if (error) return fail(toErrorMessage(error, "تعذر تفعيل الإشعارات"));
  return ok(undefined);
}

/** Turn notifications off for this device. */
export async function deletePushSubscriptionAction(endpoint: string): Promise<ActionResult> {
  const profile = await getCurrentProfile();
  if (!profile) return fail("يجب تسجيل الدخول");

  const supabase = await createClient();
  const { error } = await supabase.rpc("delete_push_subscription", { p_endpoint: endpoint });
  if (error) return fail(toErrorMessage(error, "تعذر إيقاف الإشعارات"));
  return ok(undefined);
}

/**
 * Which factories a manager is responsible for. Owner-only — enforced by
 * set_manager_factories() itself, with requireRole here as the same
 * defense-in-depth every other privileged action in this app uses.
 *
 * This decides whose phone rings for a chat message on an order, and
 * nothing else. It does not change what any manager can see: they all still
 * see every order and every notification in the bell.
 */
export async function setManagerFactoriesAction(
  managerId: string,
  factoryIds: string[],
): Promise<ActionResult> {
  await requireRole("owner");

  const supabase = await createClient();
  const { error } = await supabase.rpc("set_manager_factories", {
    p_manager_id: managerId,
    p_factory_ids: factoryIds,
  });
  if (error) return fail(toErrorMessage(error, "تعذر حفظ تغطية المصانع"));
  revalidatePath("/owner/team");
  return ok(undefined);
}
