"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentProfile } from "@/lib/auth";
import { ok, fail, toErrorMessage, type ActionResult } from "./types";

export async function markNotificationReadAction(notificationId: string): Promise<ActionResult> {
  const profile = await getCurrentProfile();
  if (!profile) return fail("يجب تسجيل الدخول");

  const supabase = await createClient();
  const { error } = await supabase
    .from("notifications")
    .update({ is_read: true })
    .eq("id", notificationId)
    .eq("user_id", profile.id);
  if (error) return fail(toErrorMessage(error));
  revalidatePath(`/${profile.role}`);
  return ok(undefined);
}

export async function markAllNotificationsReadAction(): Promise<ActionResult> {
  const profile = await getCurrentProfile();
  if (!profile) return fail("يجب تسجيل الدخول");

  const supabase = await createClient();
  const { error } = await supabase
    .from("notifications")
    .update({ is_read: true })
    .eq("user_id", profile.id)
    .eq("is_read", false);
  if (error) return fail(toErrorMessage(error));
  revalidatePath(`/${profile.role}`);
  return ok(undefined);
}
