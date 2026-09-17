"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { requireRole } from "@/lib/auth";
import { createStaffAccountSchema, regionNameSchema, updateStaffLocationSchema } from "@/lib/domain/validators";
import { normalizePhone } from "@/lib/domain/phone";
import { ok, fail, toErrorMessage, type ActionResult } from "./types";
import type { z } from "zod";

/**
 * Owner-only: creates a new staff or factory account. Previously a
 * Moderator could create driver/factory accounts too — "adding new worker
 * or factory only manager who can do that" (migration 0024) removed that
 * entirely, not just narrowed it, so this is now a plain requireRole("owner").
 * The frontend already never shows the "عضو جديد"/"إضافة مصنع" controls to
 * a Moderator (see TeamManager); this is the server-side half of that rule.
 */
export async function createStaffAccountAction(
  input: z.infer<typeof createStaffAccountSchema>,
): Promise<ActionResult<{ userId: string }>> {
  await requireRole("owner");
  const parsed = createStaffAccountSchema.safeParse(input);
  if (!parsed.success) {
    return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");
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
      address: parsed.data.role === "factory" ? (parsed.data.address?.trim() || null) : null,
      lat: parsed.data.role === "factory" ? (parsed.data.lat ?? null) : null,
      lng: parsed.data.role === "factory" ? (parsed.data.lng ?? null) : null,
      maps_url: parsed.data.role === "factory" ? (parsed.data.maps_url?.trim() || null) : null,
    },
  });

  if (error || !data.user) {
    return fail(toErrorMessage(error, "تعذر إنشاء الحساب"));
  }

  // handle_new_user() defaults password_set to true (it doesn't know this
  // account's password is a random one nobody will ever use) — mark it
  // false so the phone-login flow makes the new hire set their own.
  await admin.from("profiles").update({ password_set: false }).eq("id", data.user.id);

  if (parsed.data.role === "driver" && parsed.data.region_names.length > 0) {
    // Typed area names (migration 0025), not pre-picked ids — resolved
    // (and auto-created if new) through the same find_or_create_region()
    // every other region entry point uses, so a name typed here and the
    // same name typed on an order always resolve to one canonical row.
    const regionIds: string[] = [];
    for (const name of parsed.data.region_names) {
      const { data: regionId, error: regionError } = await admin.rpc("find_or_create_region", {
        p_name: name,
      });
      if (regionError || !regionId) {
        return fail(toErrorMessage(regionError, "تم إنشاء الحساب لكن فشل ربط المناطق"));
      }
      if (!regionIds.includes(regionId as string)) regionIds.push(regionId as string);
    }

    const rows = regionIds.map((region_id) => ({ driver_id: data.user!.id, region_id }));
    const { error: regionLinkError } = await admin.from("driver_regions").insert(rows);
    if (regionLinkError) {
      return fail(toErrorMessage(regionLinkError, "تم إنشاء الحساب لكن فشل ربط المناطق"));
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

/**
 * Owner/Moderator editing a driver's covered areas — typed names now
 * (migration 0025), resolved/auto-created and swapped in atomically by
 * set_driver_regions_by_name(), which keeps the same Owner+Moderator
 * authorization this used to enforce here via two separate client calls.
 */
export async function setDriverRegionsAction(driverId: string, regionNames: string[]): Promise<ActionResult> {
  await requireRole("owner", "moderator");
  const supabase = await createClient();

  const { error } = await supabase.rpc("set_driver_regions_by_name", {
    p_driver_id: driverId,
    p_region_names: regionNames,
  });
  if (error) return fail(toErrorMessage(error));

  revalidatePath("/owner/team");
  revalidatePath("/moderator/team");
  return ok(undefined);
}

/** Owner/Moderator fixing or filling in a factory account's location later — address text and/or the map-picked coordinates. */
export async function updateStaffLocationAction(
  userId: string,
  input: z.infer<typeof updateStaffLocationSchema>,
): Promise<ActionResult> {
  const me = await requireRole("owner", "moderator");
  const parsed = updateStaffLocationSchema.safeParse(input);
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");

  const supabase = await createClient();
  const { data: target } = await supabase.from("profiles").select("role").eq("id", userId).single();
  if (!target || target.role !== "factory") {
    return fail("الموقع متاح فقط لحسابات المصنع");
  }
  if (me.role === "moderator" && target.role !== "factory") {
    return fail("لا يمكنك تعديل هذا الحساب");
  }

  const { error } = await supabase
    .from("profiles")
    .update({
      address: parsed.data.address?.trim() || null,
      maps_url: parsed.data.maps_url?.trim() || null,
      lat: parsed.data.lat,
      lng: parsed.data.lng,
    })
    .eq("id", userId);
  if (error) return fail(toErrorMessage(error));

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
