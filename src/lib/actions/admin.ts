"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { requireRole } from "@/lib/auth";
import { createStaffAccountSchema, regionNameSchema } from "@/lib/domain/validators";
import { ok, fail, toErrorMessage, type ActionResult } from "./types";
import type { z } from "zod";

/** Owner creates a new staff account (moderator/driver/factory/owner). */
export async function createStaffAccountAction(
  input: z.infer<typeof createStaffAccountSchema>,
): Promise<ActionResult<{ userId: string }>> {
  await requireRole("owner");
  const parsed = createStaffAccountSchema.safeParse(input);
  if (!parsed.success) {
    return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");
  }

  const admin = createAdminClient();
  const tempPassword = crypto.randomUUID().slice(0, 12);

  const { data, error } = await admin.auth.admin.createUser({
    email: parsed.data.email,
    password: tempPassword,
    email_confirm: true,
    user_metadata: {
      full_name: parsed.data.full_name,
      phone: parsed.data.phone ?? null,
      role: parsed.data.role,
    },
  });

  if (error || !data.user) {
    return fail(toErrorMessage(error, "تعذر إنشاء الحساب"));
  }

  if (parsed.data.role === "driver" && parsed.data.region_ids.length > 0) {
    const rows = parsed.data.region_ids.map((region_id) => ({ driver_id: data.user!.id, region_id }));
    const { error: regionError } = await admin.from("driver_regions").insert(rows);
    if (regionError) {
      return fail(toErrorMessage(regionError, "تم إنشاء الحساب لكن فشل ربط المناطق"));
    }
  }

  // Trigger a password-recovery email so the new team member can set their own
  // password on first login instead of an Owner sharing a temp one manually.
  await admin.auth.resetPasswordForEmail(parsed.data.email);

  revalidatePath("/owner/team");
  return ok({ userId: data.user.id });
}

export async function setStaffActiveAction(userId: string, isActive: boolean): Promise<ActionResult> {
  await requireRole("owner");
  const supabase = await createClient();
  const { error } = await supabase.from("profiles").update({ is_active: isActive }).eq("id", userId);
  if (error) return fail(toErrorMessage(error));
  revalidatePath("/owner/team");
  return ok(undefined);
}

export async function setDriverRegionsAction(driverId: string, regionIds: string[]): Promise<ActionResult> {
  await requireRole("owner");
  const supabase = await createClient();

  const { error: deleteError } = await supabase.from("driver_regions").delete().eq("driver_id", driverId);
  if (deleteError) return fail(toErrorMessage(deleteError));

  if (regionIds.length > 0) {
    const rows = regionIds.map((region_id) => ({ driver_id: driverId, region_id }));
    const { error: insertError } = await supabase.from("driver_regions").insert(rows);
    if (insertError) return fail(toErrorMessage(insertError));
  }

  revalidatePath("/owner/team");
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
