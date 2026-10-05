"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/db/client";
import { getCurrentProfile, requireRole } from "@/lib/auth";
import { ok, fail, toErrorMessage, type ActionResult } from "./types";

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

export async function deletePushSubscriptionAction(endpoint: string): Promise<ActionResult> {
  const profile = await getCurrentProfile();
  if (!profile) return fail("يجب تسجيل الدخول");

  const supabase = await createClient();
  const { error } = await supabase.rpc("delete_push_subscription", { p_endpoint: endpoint });
  if (error) return fail(toErrorMessage(error, "تعذر إيقاف الإشعارات"));
  return ok(undefined);
}

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
