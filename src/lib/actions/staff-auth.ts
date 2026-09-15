"use server";

import { createAdminClient } from "@/lib/supabase/admin";
import { createClient } from "@/lib/supabase/server";
import { normalizePhone } from "@/lib/domain/phone";
import {
  phoneLookupSchema,
  setInitialPasswordSchema,
  phoneLoginSchema,
} from "@/lib/domain/validators";
import { ok, fail, type ActionResult } from "./types";
import type { z } from "zod";
import type { UserRole } from "@/types/database";

const GENERIC_NOT_FOUND = "رقم الهاتف غير مسجل أو الحساب موقوف";

/**
 * Step 1 of phone login. Looks the phone number up server-side and reports
 * only whether the account needs to create a password or already has one —
 * the account's real (internal) email never reaches the browser at any
 * point in this flow.
 */
export async function checkPhoneAction(
  input: z.infer<typeof phoneLookupSchema>,
): Promise<ActionResult<{ needsPasswordSetup: boolean }>> {
  const parsed = phoneLookupSchema.safeParse(input);
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");

  const admin = createAdminClient();
  const { data: profile } = await admin
    .from("profiles")
    .select("is_active, password_set")
    .eq("phone", normalizePhone(parsed.data.phone))
    .maybeSingle();

  if (!profile || !profile.is_active) return fail(GENERIC_NOT_FOUND);
  return ok({ needsPasswordSetup: !profile.password_set });
}

/** Step 2a: first-ever login — set a password, then actually sign in. */
export async function setInitialPasswordAction(
  input: z.infer<typeof setInitialPasswordSchema>,
): Promise<ActionResult<{ role: UserRole }>> {
  const parsed = setInitialPasswordSchema.safeParse(input);
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");

  const admin = createAdminClient();
  const normalized = normalizePhone(parsed.data.phone);
  const { data: profile } = await admin
    .from("profiles")
    .select("id, role, is_active, password_set")
    .eq("phone", normalized)
    .maybeSingle();

  if (!profile || !profile.is_active) return fail(GENERIC_NOT_FOUND);
  if (profile.password_set) return fail("تم تعيين كلمة المرور مسبقًا — سجّل الدخول بها");

  const { data: authUser, error: getErr } = await admin.auth.admin.getUserById(profile.id);
  if (getErr || !authUser?.user?.email) return fail("تعذر إكمال العملية، حاول مرة أخرى");

  const { error: updateErr } = await admin.auth.admin.updateUserById(profile.id, {
    password: parsed.data.password,
  });
  if (updateErr) return fail("تعذر تعيين كلمة المرور");

  await admin.from("profiles").update({ password_set: true }).eq("id", profile.id);

  const supabase = await createClient();
  const { error: signInErr } = await supabase.auth.signInWithPassword({
    email: authUser.user.email,
    password: parsed.data.password,
  });
  if (signInErr) return fail("تم تعيين كلمة المرور، لكن فشل تسجيل الدخول التلقائي — حاول تسجيل الدخول من جديد");

  return ok({ role: profile.role as UserRole });
}

/** Step 2b: returning login with an already-set password. */
export async function phoneLoginAction(
  input: z.infer<typeof phoneLoginSchema>,
): Promise<ActionResult<{ role: UserRole }>> {
  const parsed = phoneLoginSchema.safeParse(input);
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");

  const admin = createAdminClient();
  const normalized = normalizePhone(parsed.data.phone);
  const { data: profile } = await admin
    .from("profiles")
    .select("id, role, is_active, password_set")
    .eq("phone", normalized)
    .maybeSingle();

  if (!profile || !profile.is_active) return fail(GENERIC_NOT_FOUND);
  if (!profile.password_set) return fail("لم يتم تعيين كلمة مرور لهذا الحساب بعد");

  const { data: authUser, error: getErr } = await admin.auth.admin.getUserById(profile.id);
  if (getErr || !authUser?.user?.email) return fail("تعذر تسجيل الدخول");

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword({
    email: authUser.user.email,
    password: parsed.data.password,
  });
  if (error) return fail("رقم الهاتف أو كلمة المرور غير صحيحة");

  return ok({ role: profile.role as UserRole });
}
