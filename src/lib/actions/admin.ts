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

  const supabase = await createClient();

  // One call instead of the five this used to take (uniqueness check,
  // createUser, a profiles update, a region lookup per area, a
  // driver_regions insert). It is also atomic, which the old sequence was
  // not: a failure partway through used to leave an account that existed but
  // covered no areas, and the error message said as much — "تم إنشاء الحساب
  // لكن فشل ربط المناطق". There is no such state now.
  //
  // No email and no temporary password are involved at all. The account is
  // created with no password; the worker chooses one at first login, so
  // there is never a credential for a manager to relay or forget to change.
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

  // Clears the hash rather than setting a random one, which is what the old
  // code did with a UUID nobody could ever type. Same outcome for the
  // worker — they choose a password at next login — but the account spends
  // no time holding a credential that exists and is unusable. Also clears
  // the lockout counter, so this doubles as "unlock this account".
  const { error } = await supabase.rpc("auth_reset_password", { p_profile_id: userId });
  if (error) return fail(toErrorMessage(error));

  revalidatePath("/owner/team");
  return ok(undefined);
}

/**
 * Owner-only: permanently erases a worker account — deletes the
 * auth.users row via the Auth Admin API, which cascades to delete
 * `profiles` (see 0002's `on delete cascade`). Unlike setStaffActiveAction
 * ("إيقاف"), which just flips is_active and keeps the account around,
 * there's no undo: the worker can never sign in again and disappears from
 * every list/dropdown.
 *
 * Every order this worker ever touched stays exactly where it is —
 * migration 0032 changed `orders.assigned_driver_id` /
 * `assigned_factory_id` (and the other, non-displayed profiles(id)
 * columns) to `on delete set null` specifically so this delete can't be
 * blocked by order history, and added `assigned_driver_name` /
 * `assigned_factory_name` snapshot columns so the name that was on those
 * orders keeps showing even once the id goes null.
 *
 * Owner only (a Moderator can suspend/reset-password for driver/factory
 * accounts, per 0024/0030, but never delete anyone — this isn't scoped
 * down for Moderator at all, same as createStaffAccountAction). An owner
 * can't delete themselves or another owner account from here.
 */
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

/**
 * Removing a worker, in an order that is load-bearing and not safe to shuffle.
 *
 * 1. Deactivate first. Between reassigning and deleting there is a window
 *    where an incoming order could be auto-suggested to the very driver being
 *    removed — the picker skips inactive drivers, so this closes that race
 *    outright rather than hoping it doesn't happen.
 * 2. Move their work. If this fails we stop and delete nothing: the driver is
 *    deactivated but completely intact, which is recoverable. Doing it the
 *    other way round is not — deleting first cascades their area coverage
 *    away, nulls the driver on every order with no flag, and takes their
 *    notifications with it.
 * 3. Delete the account last. If this fails the orders are already safely
 *    moved, and retrying is harmless: the driver now has no active orders, so
 *    a second reassignment pass finds nothing to do.
 */
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

  // Was GoTrue's deleteUser, which cascaded to profiles. Now the reverse:
  // profiles is the account, and credentials cascade from it. The RPC also
  // refuses to remove the last active owner or the caller's own account,
  // which nothing enforced before.
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

/**
 * Owner/Moderator editing a driver's covered areas — typed names now
 * (migration 0025), resolved/auto-created and swapped in atomically by
 * set_driver_regions_by_name(), which keeps the same Owner+Moderator
 * authorization this used to enforce here via two separate client calls.
 */
/** Correct a worker's name. Also updates the name shown on their past orders. */
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

/**
 * Editing a driver's details is Manager-only. Coverage areas moved here from
 * Manager-or-Moderator deliberately (migration 0037): coverage decides which
 * driver gets auto-suggested for an area, so it is an assignment decision in
 * all but name, and belongs with the role that approves assignments.
 */
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

/**
 * Follows a shortened Google Maps share link's HTTP redirect(s) to reach
 * the real maps.google.com URL, without downloading the (large, JS-heavy)
 * page itself — only the Location header of each hop is read. Best-effort:
 * any network failure just means "couldn't resolve it," never an error the
 * caller needs to surface, since pasting a maps_url always succeeds on its
 * own regardless of whether a pin can be auto-extracted from it.
 */
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
    // Body is never read (we only want the redirect target) — drop it so
    // the connection doesn't hang open waiting to be consumed.
    res.body?.cancel().catch(() => {});
    if (res.status < 300 || res.status >= 400) return current;
    const location = res.headers.get("location");
    if (!location) return current;
    current = new URL(location, current).toString();
  }
  return current;
}

/**
 * "extract the lat/lng from the [Google Maps] link and pin on the map" —
 * powers the factory location forms (AddFactoryPanel, FactoriesMapPanel):
 * paste a Maps link, this returns the coordinates it points to (or null if
 * it doesn't carry any), and the caller sets the map pin from that instead
 * of requiring a manual click. A "long" link (already has @lat,lng or
 * !3d!4d in it) resolves with no network call at all; a shortened
 * maps.app.goo.gl/goo.gl share link needs its redirect followed first — see
 * resolveRedirectUrl above.
 */
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
