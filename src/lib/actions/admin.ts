"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/db/client";
import { requireRole } from "@/lib/auth";
import {
  createStaffAccountSchema,
  regionNameSchema,
} from "@/lib/domain/validators";
import { extractLatLngFromMapsUrl, isShortMapsUrl } from "@/lib/domain/maps";
import { ok, fail, toErrorMessage, type ActionResult } from "./types";
import type { z } from "zod";

export async function createStaffAccountAction(
  input: z.infer<typeof createStaffAccountSchema>,
): Promise<ActionResult<{ userId: string }>> {
  await requireRole("owner");
  const parsed = createStaffAccountSchema.safeParse(input);
  if (!parsed.success) {
    return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");
  }

  const supabase = await createClient();

  const { data, error } = await supabase.rpc<{ status: string; profile_id: string | null }[]>(
    "create_staff_account",
    {
      p_full_name: parsed.data.full_name,
      p_phone: parsed.data.phone,
      p_role: parsed.data.role,
      p_region_names: parsed.data.role === "driver" ? parsed.data.region_names : [],
    },
  );
  if (error) return fail(toErrorMessage(error, "تعذر إنشاء الحساب"));

  const row = data?.[0];
  switch (row?.status) {
    case "ok":
      break;
    case "phone_taken":
      return fail("رقم الهاتف مستخدم بالفعل لحساب آخر");
    case "invalid_role":
      return fail("الدور غير صالح");
    case "invalid_name":
      return fail("الاسم قصير جدًا");
    case "invalid_phone":
      return fail("رقم الهاتف غير صالح");
    default:
      return fail("تعذر إنشاء الحساب");
  }
  if (!row.profile_id) return fail("تعذر إنشاء الحساب");

  revalidatePath("/owner/team");
  return ok({ userId: row.profile_id });
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
  return ok(undefined);
}

export async function resetStaffPasswordAction(userId: string): Promise<ActionResult> {
  const me = await requireRole("owner", "moderator");
  const supabase = await createClient();

  if (me.role === "moderator") {
    const { data: target } = await supabase.from("profiles").select("role").eq("id", userId).single();
    if (!target || !["driver", "factory"].includes(target.role)) {
      return fail("لا يمكنك إعادة تعيين كلمة مرور هذا الحساب");
    }
  }

  const { error } = await supabase.rpc("auth_reset_password", { p_profile_id: userId });
  if (error) return fail(toErrorMessage(error));

  revalidatePath("/owner/team");
  return ok(undefined);
}

export type DriverReassignmentOutcome = {
  order_id: string;
  order_number: string;
  order_status: string;
  new_driver_id: string | null;
  new_driver_name: string | null;
  outcome: "reassigned" | "resuggested" | "unallocated";
};

export type DeleteStaffResult = {
  reassigned: number;
  resuggested: number;
  unallocated: number;
};

export async function deleteStaffAccountAction(
  userId: string,
): Promise<ActionResult<DeleteStaffResult>> {
  const me = await requireRole("owner");
  if (userId === me.id) return fail("لا يمكنك حذف حسابك الخاص");

  const supabase = await createClient();
  const { data: target } = await supabase.from("profiles").select("role, full_name").eq("id", userId).maybeSingle();
  if (!target) return fail("الحساب غير موجود");
  if (target.role === "owner") return fail("لا يمكن حذف حساب مدير من هنا");

  const summary: DeleteStaffResult = { reassigned: 0, resuggested: 0, unallocated: 0 };

  if (target.role === "driver") {
    const { error: deactivateError } = await supabase
      .from("profiles")
      .update({ is_active: false })
      .eq("id", userId);
    if (deactivateError) return fail(toErrorMessage(deactivateError, "تعذر إيقاف حساب المندوب قبل الحذف"));

    const { data: moved, error: reassignError } = await supabase.rpc("reassign_orders_from_driver", {
      p_driver_id: userId,
    });
    if (reassignError) {
      return fail(
        toErrorMessage(reassignError, "تعذر نقل أوردرات المندوب — لم يتم حذف الحساب، وهو موقوف الآن"),
      );
    }

    for (const row of (moved as DriverReassignmentOutcome[]) ?? []) {
      if (row.outcome === "reassigned") summary.reassigned += 1;
      else if (row.outcome === "resuggested") summary.resuggested += 1;
      else summary.unallocated += 1;
    }
  }

  const { error } = await supabase.rpc("delete_staff_profile", { p_profile_id: userId });
  if (error) {
    return fail(
      toErrorMessage(error, "تم نقل أوردرات المندوب لكن تعذر حذف الحساب — الحساب موقوف الآن، أعد المحاولة"),
    );
  }

  revalidatePath("/owner/team");
  revalidatePath("/owner/distribution");
  revalidatePath("/owner");
  return ok(summary);
}

export async function updateStaffProfileAction(
  userId: string,
  fullName: string,
): Promise<ActionResult> {
  await requireRole("owner");
  const name = fullName.trim();
  if (name.length < 2) return fail("الاسم قصير جدًا");

  const supabase = await createClient();
  const { error } = await supabase.rpc("update_staff_profile", {
    p_user_id: userId,
    p_full_name: name,
  });
  if (error) return fail(toErrorMessage(error, "تعذر تحديث البيانات"));

  revalidatePath("/owner/team");
  revalidatePath("/owner/orders");
  revalidatePath("/moderator/orders");
  return ok(undefined);
}

export async function setDriverRegionsAction(driverId: string, regionNames: string[]): Promise<ActionResult> {
  await requireRole("owner");
  const supabase = await createClient();

  const { error } = await supabase.rpc("set_driver_regions_by_name", {
    p_driver_id: driverId,
    p_region_names: regionNames,
  });
  if (error) return fail(toErrorMessage(error));

  revalidatePath("/owner/team");
  return ok(undefined);
}

async function resolveRedirectUrl(url: string, maxHops = 6): Promise<string> {
  let current = url;
  for (let i = 0; i < maxHops; i++) {
    let res: Response;
    try {
      res = await fetch(current, {
        method: "GET",
        redirect: "manual",
        signal: AbortSignal.timeout(5000),
      });
    } catch {
      return current;
    }
    res.body?.cancel().catch(() => {});
    if (res.status < 300 || res.status >= 400) return current;
    const location = res.headers.get("location");
    if (!location) return current;
    current = new URL(location, current).toString();
  }
  return current;
}

export async function resolveMapsUrlCoordsAction(
  url: string,
): Promise<ActionResult<{ lat: number; lng: number } | null>> {
  await requireRole("owner", "moderator");

  const trimmed = url.trim();
  if (!trimmed) return ok(null);

  const direct = extractLatLngFromMapsUrl(trimmed);
  if (direct) return ok(direct);

  if (!isShortMapsUrl(trimmed)) return ok(null);

  const resolved = await resolveRedirectUrl(trimmed);
  return ok(extractLatLngFromMapsUrl(resolved));
}

export async function createRegionAction(
  input: z.infer<typeof regionNameSchema>,
): Promise<ActionResult<{ id: string }>> {
  await requireRole("owner");
  const parsed = regionNameSchema.safeParse(input);
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "اسم غير صالح");

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("regions")
    .insert({ name: parsed.data.name })
    .select("id")
    .single<{ id: string }>();
  if (error || !data) return fail(toErrorMessage(error, "تعذر إضافة المنطقة (ربما موجودة بالفعل)"));

  revalidatePath("/owner/team");
  revalidatePath("/order/new");
  return ok({ id: data.id });
}
