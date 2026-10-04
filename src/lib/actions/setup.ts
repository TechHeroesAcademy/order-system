"use server";

import { createAdminClient } from "@/lib/db/client";
import { issueSession } from "@/lib/auth/sign-in";
import { bootstrapOwnerSchema } from "@/lib/domain/validators";
import { ok, fail, type ActionResult } from "./types";
import type { z } from "zod";
import type { UserRole } from "@/types/database";

/**
 * Whether the system already has an owner. Decides what /setup renders.
 *
 * Runs with no identity, which is the only way it can: there is nobody
 * signed in when this is asked. It reaches profiles through the same
 * SECURITY DEFINER path everything else does — owner_exists() below is a
 * plain count, and the only thing it reveals is a boolean that the /setup
 * page displays anyway.
 */
export async function ownerExists(): Promise<boolean> {
  const db = createAdminClient();

  // owner_exists() rather than a count of profiles. This runs before anyone
  // is signed in, so there is no identity — and profiles_select_staff needs
  // a role, which means a count here always came back 0 and /setup offered
  // the "create the first owner" form to every visitor forever, on a system
  // that had been running for months. Not exploitable (bootstrap_owner takes
  // a row lock on the same check and refuses), but not something to leave
  // standing either.
  //
  // The function returns one bit and nothing else, because it is reachable
  // without a session.
  const { data, error } = await db.rpc<boolean>("owner_exists");

  // Fail closed: if it cannot be read, assume an owner DOES exist, so a
  // database hiccup cannot briefly re-open the one-time bootstrap.
  //
  // Logged rather than silent, because this exact silence cost real time
  // once: the pool was refusing to connect (it forced TLS at a database that
  // does not speak it) and /setup calmly reported the system was already set
  // up. "Already configured" and "the database is unreachable" must not look
  // the same from the outside.
  if (error) {
    console.error("[setup] owner_exists() failed:", error.message);
    return true;
  }
  return data === true;
}

/**
 * One-time owner bootstrap. The first account in a fresh system.
 *
 * The guard that makes this safe is in the database, not here:
 * bootstrap_owner() takes a row lock on the owner check before inserting, so
 * two people hitting /setup at the same moment cannot both become owner —
 * the second waits, sees the first, and is refused. The check in this file
 * is just a faster "no" for the common case.
 */
export async function bootstrapOwnerAction(
  input: z.infer<typeof bootstrapOwnerSchema>,
): Promise<ActionResult> {
  const parsed = bootstrapOwnerSchema.safeParse(input);
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");

  const db = createAdminClient();
  const { data, error } = await db.rpc<{ status: string; profile_id: string | null }[]>(
    "bootstrap_owner",
    {
      p_full_name: parsed.data.full_name,
      p_phone: parsed.data.phone,
      p_password: parsed.data.password,
    },
  );
  if (error) return fail("تعذر إنشاء الحساب");

  const row = data?.[0];
  switch (row?.status) {
    case "ok":
      break;
    case "already_set_up":
      return fail("تم إعداد حساب المدير بالفعل — سجّل الدخول من صفحة الدخول");
    case "phone_taken":
      return fail("رقم الهاتف مستخدم بالفعل لحساب آخر");
    case "weak_password":
      return fail("كلمة المرور 6 أحرف على الأقل");
    case "invalid_name":
      return fail("الاسم قصير جدًا");
    case "invalid_phone":
      return fail("رقم الهاتف غير صالح");
    default:
      return fail("تعذر إنشاء الحساب");
  }

  if (!row.profile_id) return fail("تعذر إنشاء الحساب");

  await issueSession({
    id: row.profile_id,
    role: "owner" satisfies UserRole,
    full_name: parsed.data.full_name,
  });

  return ok(undefined);
}
