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

const GENERIC_NOT_FOUND = "رقم الهاتف غير مسجل أو الحساب موقوف";
const GENERIC_BAD_LOGIN = "رقم الهاتف أو كلمة المرور غير صحيحة";

type LoginRow = {
  status: string;
  profile_id: string | null;
  role: UserRole | null;
  full_name: string | null;
  retry_after_seconds?: number | null;
};

function lockedMessage(seconds: number | null | undefined): string {
  const mins = Math.max(1, Math.ceil((seconds ?? 300) / 60));
  return `تم إيقاف المحاولات مؤقتًا بعد محاولات خاطئة متكررة. حاول بعد ${mins} دقيقة.`;
}

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

  await issueSession({
    id: row.profile_id,
    role: row.role,
    full_name: row.full_name ?? "",
  });

  return ok({ role: row.role });
}

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
      return fail(lockedMessage(row.retry_after_seconds));
    case "needs_setup":
      return fail("لم يتم تعيين كلمة مرور لهذا الحساب بعد");
    case "inactive":
      return fail(GENERIC_NOT_FOUND);
    default:
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

export async function signOutAction(): Promise<ActionResult> {
  const { clearSession } = await import("@/lib/auth/sign-in");
  await clearSession();
  return ok(undefined);
}
