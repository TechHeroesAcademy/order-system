"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { requireRole } from "@/lib/auth";
import { createStaffAccountSchema, regionNameSchema } from "@/lib/domain/validators";
import { normalizePhone } from "@/lib/domain/phone";
import { ok, fail, toErrorMessage, type ActionResult } from "./types";
import type { z } from "zod";

/**
 * Owner or Moderator creates a new staff account. A Moderator may only create
 * drivers/factory accounts (never another owner or moderator — that stays an
 * Owner-only action, same boundary the self-escalation trigger enforces on
 * the profiles table).
 */
export async function createStaffAccountAction(
  input: z.infer<typeof createStaffAccountSchema>,
): Promise<ActionResult<{ userId: string }>> {
  const me = await requireRole("owner", "moderator");
  const parsed = createStaffAccountSchema.safeParse(input);
  if (!parsed.success) {
    return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");
  }
  if (me.role === "moderator" && !["driver", "factory"].includes(parsed.data.role)) {
    return fail("المشرف يمكنه فقط إضافة حساب مندوب أو مصنع");
  }

  const admin = createAdminClient();
  const normalizedPhone = normalizePhone(parsed.data.phone);

  const { data: existingPhone } = await admin
    .from("profiles")
    .select("id")
    .eq("phone", normalizedPhone)
    .maybeSingle();
  if (existingPhone) return fail("رقم الهاتف مستخدم بالفعل لحساب آخر");

  // Staff sign in with their phone number and a password they set themselves
  // on first login (see staff-auth.ts) — email is optional and, when left
  // blank, this internal address is never shown to them or used for login.
  const email = parsed.data.email?.trim() || `staff-${crypto.randomUUID()}@workers.internal`;
  const temporaryPassword = crypto.randomUUID();

  const { data, error } = await admin.auth.admin.createUser({
    email,
    password: temporaryPassword,
    email_confirm: true,
    user_metadata: {
      full_name: parsed.data.full_name,
      phone: normalizedPhone,
      role: parsed.data.role,
    },
  });

  if (error || !data.user) {
    return fail(toErrorMessage(error, "تعذر إنشاء الحساب"));
  }

  // handle_new_user() defaults password_set to true (it doesn't know this
  // account's password is a random one nobody will ever use) — mark it
  // false so the phone-login flow makes the new hire set their own.
  await admin.from("profiles").update({ password_set: false }).eq("id", data.user.id);

  if (parsed.data.role === "driver" && parsed.data.region_ids.length > 0) {
    const rows = parsed.data.region_ids.map((region_id) => ({ driver_id: data.user!.id, region_id }));
    const { error: regionError } = await admin.from("driver_regions").insert(rows);
    if (regionError) {
      return fail(toErrorMessage(regionError, "تم إنشاء الحساب لكن فشل ربط المناطق"));
    }
  }

  revalidatePath("/owner/team");
  revalidatePath("/moderator/team");
  return ok({ userId: data.user.id });
}

export async function setStaffActiveAction(userId: string, isActive: boolean): Promise<ActionResult> {
  const me = await requireRole("owner", "moderator");
  const supabase = await createClient();

  if (me.role === "moderator") {
    const { data: target } = await supabase.from("profiles").select("role").eq("id", userId).single();
    if (!target || !["driver", "factory"].includes(target.role)) {
      return fail("لا يمكنك تعديل حالة هذا الحساب");
    }
  }

  const { error } = await supabase.from("profiles").update({ is_active: isActive }).eq("id", userId);
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/owner/team");
  revalidatePath("/moderator/team");
  return ok(undefined);
}

/**
 * Owner/Moderator forces a password reset: the old password stops working
 * immediately, and password_set flips back to false so the worker goes
 * through the "create your password" step again next time they sign in
 * with their phone number (see staff-auth.ts) — no temp password to relay.
 */
export async function resetStaffPasswordAction(userId: string): Promise<ActionResult> {
  const me = await requireRole("owner", "moderator");
  const supabase = await createClient();

  if (me.role === "moderator") {
    const { data: target } = await supabase.from("profiles").select("role").eq("id", userId).single();
    if (!target || !["driver", "factory"].includes(target.role)) {
      return fail("لا يمكنك إعادة تعيين كلمة مرور هذا الحساب");
    }
  }

  const admin = createAdminClient();
  const { error } = await admin.auth.admin.updateUserById(userId, {
    password: crypto.randomUUID(),
  });
  if (error) return fail(toErrorMessage(error));

  await admin.from("profiles").update({ password_set: false }).eq("id", userId);

  revalidatePath("/owner/team");
  revalidatePath("/moderator/team");
  return ok(undefined);
}

export async function setDriverRegionsAction(driverId: string, regionIds: string[]): Promise<ActionResult> {
  await requireRole("owner", "moderator");
  const supabase = await createClient();

  const { error: deleteError } = await supabase.from("driver_regions").delete().eq("driver_id", driverId);
  if (deleteError) return fail(toErrorMessage(deleteError));

  if (regionIds.length > 0) {
    const rows = regionIds.map((region_id) => ({ driver_id: driverId, region_id }));
    const { error: insertError } = await supabase.from("driver_regions").insert(rows);
    if (insertError) return fail(toErrorMessage(insertError));
  }

  revalidatePath("/owner/team");
  revalidatePath("/moderator/team");
  return ok(undefined);
}

export async function createRegionAction(
  input: z.infer<typeof regionNameSchema>,
): Promise<ActionResult<{ id: string }>> {
  await requireRole("owner");
  const parsed = regionNameSchema.safeParse(input);
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "اسم غير صالح");

  const supabase = await createClient();
  const { data, error } = await supabase.from("regions").insert({ name: parsed.data.name }).select("id").single();
  if (error) return fail(toErrorMessage(error, "تعذر إضافة المنطقة (ربما موجودة بالفعل)"));

  revalidatePath("/owner/team");
  revalidatePath("/order/new");
  return ok({ id: data.id as string });
}
