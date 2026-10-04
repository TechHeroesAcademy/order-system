"use server";

import { createAdminClient } from "@/lib/db/client";
import { issueSession } from "@/lib/auth/sign-in";
import {
  phoneLookupSchema,
  setInitialPasswordSchema,
  phoneLoginSchema,
} from "@/lib/domain/validators";
import { ok, fail, type ActionResult } from "./types";
import type { z } from "zod";
import type { UserRole } from "@/types/database";

/**
 * Phone + password sign-in, against the database's own auth functions
 * (neon/migrations/0002_local_auth.sql) rather than GoTrue.
 *
 * What changed, and what deliberately did not:
 *
 *   - No password ever reaches this file's logic. It is passed through to
 *     Postgres, where pgcrypto compares it against a hash that never leaves
 *     the database. There is nothing here to leak in a stack trace, a log
 *     line, or a heap dump.
 *   - No service-role key. createAdminClient() here means "no identity at
 *     all", which is strictly less access than a signed-in user has — the
 *     opposite of what the name meant under Supabase. These three functions
 *     work because each RPC sees past RLS for one narrow purpose and returns
 *     one narrow shape.
 *   - The flow the worker sees is identical: type your number, then either
 *     choose a password (first time) or enter it.
 *
 * Every failure message is deliberately coarse. The database already
 * returns the same status for an unknown number and a wrong password; this
 * keeps it that way rather than helpfully distinguishing them.
 */

const GENERIC_NOT_FOUND = "رقم الهاتف غير مسجل أو الحساب موقوف";
const GENERIC_BAD_LOGIN = "رقم الهاتف أو كلمة المرور غير صحيحة";

type LoginRow = {
  status: string;
  profile_id: string | null;
  role: UserRole | null;
  full_name: string | null;
  retry_after_seconds?: number | null;
};

/** "locked for 7 minutes" rather than "locked", so the person knows to wait. */
function lockedMessage(seconds: number | null | undefined): string {
  const mins = Math.max(1, Math.ceil((seconds ?? 300) / 60));
  return `تم إيقاف المحاولات مؤقتًا بعد محاولات خاطئة متكررة. حاول بعد ${mins} دقيقة.`;
}

/**
 * Step 1: does this number already have a password, or does it need to
 * choose one? Returns nothing else — not the name, not the role.
 */
export async function checkPhoneAction(
  input: z.infer<typeof phoneLookupSchema>,
): Promise<ActionResult<{ needsPasswordSetup: boolean }>> {
  const parsed = phoneLookupSchema.safeParse(input);
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");

  const db = createAdminClient();
  const { data, error } = await db.rpc<{ needs_password_setup: boolean }[]>(
    "auth_begin_login",
    { p_phone: parsed.data.phone },
  );
  if (error) return fail("تعذر إكمال العملية، حاول مرة أخرى");

  const row = data?.[0];
  if (!row) return fail(GENERIC_NOT_FOUND);
  return ok({ needsPasswordSetup: row.needs_password_setup });
}

/** Step 2a: first ever login — the worker chooses their own password. */
export async function setInitialPasswordAction(
  input: z.infer<typeof setInitialPasswordSchema>,
): Promise<ActionResult<{ role: UserRole }>> {
  const parsed = setInitialPasswordSchema.safeParse(input);
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");

  const db = createAdminClient();
  const { data, error } = await db.rpc<LoginRow[]>("auth_set_initial_password", {
    p_phone: parsed.data.phone,
    p_password: parsed.data.password,
  });
  if (error) return fail("تعذر تعيين كلمة المرور");

  const row = data?.[0];
  switch (row?.status) {
    case "ok":
      break;
    case "already_set":
      return fail("تم تعيين كلمة المرور مسبقًا — سجّل الدخول بها");
    case "weak_password":
      return fail("كلمة المرور 6 أحرف على الأقل");
    default:
      return fail(GENERIC_NOT_FOUND);
  }

  if (!row.profile_id || !row.role) return fail("تعذر تعيين كلمة المرور");

  // Signed in straight away, exactly as before — the worker set a password
  // one second ago, so asking them to type it again is friction with no
  // security value.
  await issueSession({
    id: row.profile_id,
    role: row.role,
    full_name: row.full_name ?? "",
  });

  return ok({ role: row.role });
}

/** Step 2b: returning login. */
export async function phoneLoginAction(
  input: z.infer<typeof phoneLoginSchema>,
): Promise<ActionResult<{ role: UserRole }>> {
  const parsed = phoneLoginSchema.safeParse(input);
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");

  const db = createAdminClient();
  const { data, error } = await db.rpc<LoginRow[]>("auth_verify_login", {
    p_phone: parsed.data.phone,
    p_password: parsed.data.password,
  });
  if (error) return fail("تعذر تسجيل الدخول، حاول مرة أخرى");

  const row = data?.[0];
  switch (row?.status) {
    case "ok":
      break;
    case "locked":
      // The one case worth being specific about. A person locked out by
      // their own typing needs to know to wait rather than keep trying,
      // and telling them costs nothing: an attacker already knows they
      // are being throttled, because they are.
      return fail(lockedMessage(row.retry_after_seconds));
    case "needs_setup":
      return fail("لم يتم تعيين كلمة مرور لهذا الحساب بعد");
    case "inactive":
      return fail(GENERIC_NOT_FOUND);
    default:
      // bad_credentials, and anything unexpected. An unknown number and a
      // wrong password are the same answer by design.
      return fail(GENERIC_BAD_LOGIN);
  }

  if (!row.profile_id || !row.role) return fail(GENERIC_BAD_LOGIN);

  await issueSession({
    id: row.profile_id,
    role: row.role,
    full_name: row.full_name ?? "",
  });

  return ok({ role: row.role });
}

/** Sign out. Clears the cookie; there is no server-side session to revoke. */
export async function signOutAction(): Promise<ActionResult> {
  const { clearSession } = await import("@/lib/auth/sign-in");
  await clearSession();
  return ok(undefined);
}
